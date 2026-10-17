import AppKit
import Combine
import UniformTypeIdentifiers

/// Export and sharing are explicit user actions. This controller never uploads
/// a report or sends an email: the system email service opens a draft to review.
@MainActor
final class DiagnosticReportController: NSObject, ObservableObject, NSSharingServiceDelegate {
    static let supportAddress = "nachopower@atomfilmlab.com"

    @Published private(set) var reportURL: URL?
    @Published private(set) var message: String?
    @Published private(set) var isExporting = false

    private let diagnostics: SupportDiagnostics
    private var sharingService: NSSharingService?
    private var sharingReportURL: URL?
    private let emailSubject = "Nacho Power support report"
    private let emailBody = """
    Please describe what happened and what you expected:


    EcoFlow model and firmware version (if known):


    Additional notes:
    """

    init(diagnostics: SupportDiagnostics = .shared) {
        self.diagnostics = diagnostics
        super.init()
    }

    func exportReport(context: [String: Any]) {
        guard !isExporting else { return }
        isExporting = true
        message = nil
        diagnostics.record(category: "diagnostics", event: "export_requested")
        let safeContext = SupportDiagnostics.sanitize(context)
        let panel = NSSavePanel()
        panel.title = "Export Nacho Power report"
        panel.prompt = "Export"
        panel.message = "Save a local report you can review before sharing with support."
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "Nacho-Power-report-\(date.string(from: Date())).txt"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard response == .OK, let destination = panel.url else {
                    self.isExporting = false
                    self.message = "Export cancelled. Nothing was shared."
                    return
                }
                self.writeReport(to: destination, context: safeContext)
            }
        }
        if let window = NSApp.keyWindow, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func writeReport(to destination: URL, context: [String: Any]) {
        let diagnostics = self.diagnostics
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try diagnostics.exportReport(to: destination, context: context)
                }.value
                guard let self else { return }
                reportURL = destination
                message = "Report saved. Review it before opening an email draft."
                isExporting = false
                diagnostics.record(category: "diagnostics", event: "export_finished")
            } catch {
                guard let self else { return }
                message = "Couldn’t save the report. Choose another location and try again."
                isExporting = false
                diagnostics.record(category: "diagnostics", event: "error",
                                   details: SupportDiagnostics.errorDetails(error))
            }
        }
    }

    func reviewReport() {
        guard let report = existingReport() else { return }
        if !NSWorkspace.shared.open(report) {
            NSWorkspace.shared.activateFileViewerSelecting([report])
            message = "The report is selected in Finder. Open it with a text editor to review."
        }
    }

    func emailReport() {
        guard !isExporting, let report = existingReport() else { return }
        guard sharingService == nil else {
            message = "An email draft is already open or being prepared. Review it in your email app."
            return
        }
        let items: [Any] = [emailBody, report]
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) {
            service.recipients = [Self.supportAddress]
            service.subject = emailSubject
            service.delegate = self
            sharingService = service
            sharingReportURL = report
            message = "Opening an email draft with the report attached. Review it and describe the problem before sending."
            service.perform(withItems: items)
        } else {
            openEmailFallback(report)
        }
    }

    private func existingReport() -> URL? {
        guard let reportURL, Self.isReadableReport(reportURL) else {
            reportURL = nil
            message = "Export a report first, then review or attach the saved file."
            return nil
        }
        return reportURL
    }

    private static func isReadableReport(_ url: URL) -> Bool {
        guard url.isFileURL,
              let properties = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              properties.isRegularFile == true, properties.isSymbolicLink != true else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private func openEmailFallback(_ report: URL) {
        var mail = URLComponents()
        mail.scheme = "mailto"
        mail.path = Self.supportAddress
        mail.queryItems = [
            URLQueryItem(name: "subject", value: emailSubject),
            URLQueryItem(name: "body", value: "Attach the exported Nacho Power report selected in Finder, then describe the problem.\n\n\(emailBody)")
        ]
        let opened = mail.url.map { NSWorkspace.shared.open($0) } ?? false
        NSWorkspace.shared.activateFileViewerSelecting([report])
        message = opened
            ? "Attach the report selected in Finder to the email draft. Review it before sending."
            : "The report is selected in Finder. Attach it to an email to \(Self.supportAddress)."
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        guard self.sharingService === sharingService else { return }
        let report = sharingReportURL
        self.sharingService = nil
        sharingReportURL = nil
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError {
            message = "Email draft cancelled. Your saved report is still available."
            return
        }
        if let report, Self.isReadableReport(report) {
            openEmailFallback(report)
        } else {
            message = "The report is no longer available. Export it again before opening an email draft."
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        guard self.sharingService === sharingService else { return }
        self.sharingService = nil
        sharingReportURL = nil
    }
}
