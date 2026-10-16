import SwiftUI

struct SupportView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Support Nacho Power")
                .font(.system(size: 14, weight: .semibold))
            Text("Optional one-time support. Nacho Power stays free.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(AppSupportLinks.options) { option in
                    Link(destination: option.checkoutURL) {
                        Label(option.label, systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Support Nacho Power with \(option.amount) US dollars, one time, through QuickBooks")
                    .help("Opens QuickBooks checkout in your browser. Review and confirm payment there.")
                }
            }
            Text("Opens QuickBooks in your browser. You review and confirm payment there.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
