import AppKit
import SwiftUI

private let accent = Color(red: 0.40, green: 0.31, blue: 0.65)

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: AutomaticAppUpdater
    @ObservedObject var diagnostics: DiagnosticReportController
    @State private var accountEmail = ""
    @State private var accountPassword = ""
    @StateObject private var stationDiscovery = EcoFlowStationDiscovery()
    @State private var connectionExpanded = true
    @State private var accountExpanded = false
    @State private var manualStationExpanded = false
    @State private var cloudExpanded = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(named: "NachoPowerLogo") ?? NSImage())
                    .resizable().scaledToFit()
                    .frame(width: 76, height: 76)
                    .accessibilityLabel("Nacho Power logo")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nacho Power").font(.system(size: 24, weight: .semibold))
                    Text("A little reminder to plug back in.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            stationStatusCard(secondary: false)
            if model.monitorsSecondStation {
                stationStatusCard(secondary: true)
            }

            connectionSettings

            VStack(alignment: .leading, spacing: 14) {
                Toggle("Enable reminders", isOn: $model.enabled)
                    .font(.system(size: 14, weight: .semibold)).toggleStyle(.switch)
                Picker("Start the reminder", selection: $model.immediate) {
                    Text("When unplugged").tag(true)
                    Text("Below a battery level").tag(false)
                }.pickerStyle(.segmented).labelsHidden()
                if !model.immediate {
                    HStack {
                        Text("Battery below").foregroundStyle(.secondary)
                        Slider(value: $model.threshold, in: 1...100, step: 1)
                        Text("\(Int(model.threshold.rounded()))%")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced)).frame(width: 45, alignment: .trailing)
                    }
                }
                HStack {
                    Text("Show cat").foregroundStyle(.secondary)
                    Slider(value: $model.reminderDelayMinutes, in: 0...60, step: 1)
                        .accessibilityLabel("Delay before showing the cat")
                        .accessibilityValue(model.reminderDelayText)
                        .help("Move fully left for Immediately, or choose a delay from 1 to 60 minutes.")
                    Text(model.reminderDelayText).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 118, alignment: .trailing)
                }
                if model.timedReminders {
                    Text("Click the cat to hide it and wait another \(model.reminderIntervalText). It keeps looping until clicked or AC reconnects.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Immediately keeps the cat visible until AC reconnects. Clicks pass through to your desktop.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(model.conditionText).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The intro plays once, the loop repeats, and reconnecting AC hides the cat with a pop.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("On your desktop").font(.system(size: 14, weight: .semibold))
                Toggle("Fit animation across the entire screen", isOn: $model.fullScreen)
                    .toggleStyle(.switch)
                if model.fullScreen {
                    HStack {
                        Text("Direction").foregroundStyle(.secondary)
                        Spacer()
                        Picker("Animation direction", selection: $model.fullScreenSide) {
                            Text(OverlayVideoSide.right.title).tag(OverlayVideoSide.right)
                            Text(OverlayVideoSide.left.title).tag(OverlayVideoSide.left)
                        }.labelsHidden().frame(width: 190)
                    }
                }
                HStack {
                    Text("Display").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Display", selection: $model.displaySelection) {
                        Text("Main display").tag(OverlayDisplaySelection.main)
                        ForEach(model.availableDisplays) { display in
                            Text(display.name).tag(display.id)
                        }
                        Text("All displays").tag(OverlayDisplaySelection.all)
                        if model.selectedDisplayIsUnavailable {
                            Text("\(model.unavailableDisplayName) (disconnected)").tag(model.displaySelection)
                        }
                    }.labelsHidden().frame(width: 240)
                }
                if model.selectedDisplayIsUnavailable {
                    Text("The selected display is disconnected. The cat appears on the main display until it reconnects.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !model.fullScreen {
                    HStack {
                        Text("Position").foregroundStyle(.secondary)
                        Spacer()
                        Picker("Position", selection: $model.corner) {
                            ForEach(OverlayCorner.allCases, id: \.self) { corner in
                                Text(cornerLabel(corner)).tag(corner)
                            }
                        }.labelsHidden().frame(width: 190)
                    }
                    HStack {
                        Text("Size").foregroundStyle(.secondary).frame(width: 45, alignment: .leading)
                        Slider(value: $model.catWidth, in: 240...1000, step: 20)
                        Text("\(Int(model.catWidth))")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
                Text(model.timedReminders
                    ? "Click the cat to snooze it. Only the small area around it captures clicks; typing stays in your active app."
                    : "The cat stays above your apps. Clicks and typing pass through to your desktop.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.playbackError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let warning = model.assetWarning {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Videos need transparent backgrounds", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12, weight: .semibold))
                    Text("The current exports show a black rectangle. Re-export the keyed cat with Export Alpha enabled.")
                        .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color(nsColor: .systemOrange))
                .help(warning)
            }

            HStack {
                Text(model.phaseDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if model.isPreviewing {
                    Button("End preview") { model.endPreview() }.controlSize(.large)
                } else if model.canSnooze {
                    Button("Snooze cat") { model.snoozeCat() }.controlSize(.large)
                } else {
                    Button("Preview cat") { model.previewCat() }
                        .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.white).controlSize(.large)
                }
            }

            Divider()
            AppUpdateSettingsView(updates: updates)
            Divider()
            diagnosticsSettings
            Divider()
            SupportView()
        }
        .padding(26)
        .frame(width: 500)
        }
        .frame(width: 500, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .onDisappear { stationDiscovery.stop() }
    }

    private var diagnosticsSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics & support").font(.system(size: 14, weight: .semibold))
            Text("Save recent app events, power readings, settings, and display sizes for troubleshooting. Account details, credentials, serial numbers, and network addresses are excluded.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(diagnostics.isExporting ? "Exporting…" : "Export report…") {
                    diagnostics.exportReport(context: model.diagnosticContext)
                }
                .disabled(diagnostics.isExporting)
                Button("Review report") { diagnostics.reviewReport() }
                    .disabled(diagnostics.reportURL == nil || diagnostics.isExporting)
                Button("Email report…") { diagnostics.emailReport() }
                    .disabled(diagnostics.reportURL == nil || diagnostics.isExporting)
            }
            Text("Nothing is uploaded automatically. Email opens a draft to \(DiagnosticReportController.supportAddress); you review and send it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = diagnostics.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stationStatusCard(secondary: Bool) -> some View {
        let reading = secondary ? model.secondTelemetry : model.telemetry
        let connected = secondary ? model.secondIsConnected : model.isConnected
        let status = DockPowerStatus(telemetry: reading, isConnected: connected)
        let error = secondary ? model.secondConnectionError : model.connectionError
        return VStack(alignment: .leading, spacing: 13) {
            HStack {
                Circle().fill(Color(nsColor: DockStatusIcon.color(for: status.acState))).frame(width: 7, height: 7)
                Text("\(secondary ? "Station 2" : "Station 1") · \(reading?.deviceName ?? "EcoFlow")")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { model.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh power status")
            }
            HStack(spacing: 30) {
                metric(secondary ? model.secondBatteryText : model.batteryText, label: "BATTERY", symbol: "battery.75percent")
                metric(secondary ? model.secondInputText : model.inputText, label: "INPUT POWER", symbol: "bolt.fill")
            }
            Text(secondary ? model.secondPowerText : model.powerText)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let source = reading?.sourceDescription {
                Text(source).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Explicit full-row buttons keep expansion independent of rapidly changing
    /// telemetry and make the whole label clickable, including in a ScrollView.
    private func sectionButton(_ title: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    private var connectionSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionButton("Connection settings", expanded: $connectionExpanded)
            if connectionExpanded {
                Picker("Connect station 1 using", selection: $model.transport) {
                    ForEach(EcoFlowTransport.allCases, id: \.self) { transport in
                        Text(transport.title).tag(transport)
                    }
                }
                Text("Close other EcoFlow apps connected to these stations. Automatic tries USB, then Bluetooth, then configured Wi-Fi.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.transport == .bluetooth || model.transport == .automatic || model.secondStationEnabled {
                    bluetoothAccountSettings
                }
                stationSelection
                if model.transport == .wifi || model.transport == .automatic || model.secondStationEnabled {
                    cloudSettings
                }
                HStack {
                    if let message = model.connectionSettingsMessage {
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Save & connect") { model.saveConnectionSettings() }
                        .buttonStyle(.borderedProminent).tint(accent)
                }
            }
        }.textFieldStyle(.roundedBorder)
    }

    private var bluetoothAccountSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.bluetoothSetupMessage, systemImage: model.bluetoothAccountReady ? "checkmark.circle.fill" : "person.crop.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.bluetoothAccountReady {
                Button(model.isFindingAccount ? "Finding your account…" : "Find existing EcoFlow sign-in") { model.findEcoFlowAccount() }
                    .disabled(model.isFindingAccount)
            }
            sectionButton(model.bluetoothAccountReady ? "Use another EcoFlow account" : "Sign in to enable Bluetooth", expanded: $accountExpanded)
            if accountExpanded {
                TextField("EcoFlow email", text: $accountEmail)
                SecureField("EcoFlow password", text: $accountPassword)
                regionPicker
                Text("Sign in once with the account paired with your stations. Bluetooth then reconnects automatically. Your password is never saved.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(model.isSigningIn ? "Signing in…" : "Sign in for Bluetooth") {
                    let password = accountPassword
                    accountPassword = ""
                    Task { await model.signInForBluetooth(email: accountEmail, password: password) }
                }.disabled(model.isSigningIn || accountEmail.isEmpty || accountPassword.isEmpty)
            }
        }
    }

    private var stationSelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose your stations").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(stationDiscovery.isScanning ? "Finding stations…" : "Find nearby stations") { stationDiscovery.scan() }
                    .disabled(stationDiscovery.isScanning)
            }
            stationPicker("Station 1", selection: $model.serialNumber, allowAutomatic: !model.secondStationEnabled)
            Toggle("Monitor a second EcoFlow", isOn: $model.secondStationEnabled).toggleStyle(.switch)
            if model.secondStationEnabled {
                stationPicker("Station 2", selection: $model.secondSerialNumber, allowAutomatic: false)
                Picker("Connect station 2 using", selection: $model.secondTransport) {
                    ForEach(EcoFlowTransport.allCases, id: \.self) { transport in
                        Text(transport.title).tag(transport)
                    }
                }
                Text("Choose two different stations, then Save & connect. Each has its own readings and reconnects independently. Bluetooth uses the EcoFlow account above.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The menu bar and Dock show station 1, then station 2. Either station can trigger the cat. In timed mode, clicking it snoozes both.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !stationDiscovery.message.isEmpty {
                Text(stationDiscovery.message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            sectionButton("Enter a serial number manually", expanded: $manualStationExpanded)
            if manualStationExpanded {
                TextField("Station 1 serial number", text: $model.serialNumber)
                if model.secondStationEnabled {
                    TextField("Station 2 serial number", text: $model.secondSerialNumber)
                }
                Text("You can find the serial on the station or in EcoFlow device information. Leave station 1 empty for automatic selection when monitoring one station.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stationPicker(_ title: String, selection: Binding<String>, allowAutomatic: Bool) -> some View {
        Picker(title, selection: selection) {
            Text(allowAutomatic ? "Automatic / remembered station" : "Choose a station").tag("")
            ForEach(stationDiscovery.stations) { station in
                Text(station.userDisplayName).tag(station.serialNumber)
            }
            if !selection.wrappedValue.isEmpty && !stationDiscovery.stations.contains(where: { $0.serialNumber == selection.wrappedValue }) {
                Text("\(title == "Station 2" ? (model.secondTelemetry?.deviceName ?? "Saved station") : (model.telemetry?.deviceName ?? "Saved station")) · …\(selection.wrappedValue.suffix(6))").tag(selection.wrappedValue)
            }
        }.accessibilityLabel(title)
    }

    private var regionPicker: some View {
        Picker("Account region", selection: $model.cloudRegion) {
            Text("Global").tag(EcoFlowCloudRegion.global)
            Text("Europe").tag(EcoFlowCloudRegion.europe)
            Text("America").tag(EcoFlowCloudRegion.america)
        }
    }

    private var cloudSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionButton("Wi-Fi cloud credentials", expanded: $cloudExpanded)
            if cloudExpanded {
                regionPicker
                SecureField("EcoFlow developer access key", text: $model.cloudAccessKey)
                SecureField("EcoFlow developer secret key", text: $model.cloudSecretKey)
                Text("Select or enter each station's serial number above. Both stations must be online through Wi-Fi and accessible with these EcoFlow developer API credentials. Credentials stay in this Mac's Keychain.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metric(_ value: String, label: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(accent)
                Text(value).font(.system(size: 27, weight: .medium, design: .rounded)).monospacedDigit()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cornerLabel(_ corner: OverlayCorner) -> String {
        switch corner {
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }
}
