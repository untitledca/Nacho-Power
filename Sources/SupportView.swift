import SwiftUI

struct SupportView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If you like Nacho Power…")
                .font(.system(size: 14, weight: .semibold))
            Link(destination: AppSupportLinks.venmoURL) {
                HStack(spacing: 6) {
                    Text("🍺")
                    Text("Buy me a beer")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .accessibilityLabel("Buy me a beer on Venmo")
            .help("Open Chase’s Venmo profile: @chaseabrams99")
            Text("An optional thank-you. Opens Venmo · @chaseabrams99")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
