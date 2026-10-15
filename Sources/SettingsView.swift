import AppKit
import SwiftUI

private let accent = Color(red: 0.40, green: 0.31, blue: 0.65)

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: AppUpdateChecker
    @State private var accountEmail = ""
    @State private var accountPassword = ""

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

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Circle().fill(model.isConnected ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(model.telemetry?.deviceName ?? "Connect your EcoFlow").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { model.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh power status")
                }
                HStack(spacing: 30) {
                    metric(model.batteryText, label: "BATTERY", symbol: "battery.75percent")
                    metric(model.inputText, label: "INPUT POWER", symbol: "bolt.fill")
                }
                Text(model.powerText).font(.system(size: 12)).foregroundStyle(.secondary)
                if let source = model.telemetry?.sourceDescription {
                    Text(source).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let error = model.connectionError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(18).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))

            connectionSettings

            VStack(alignment: .leading, spacing: 14) {
                Toggle("Enable reminders", isOn: $model.enabled)
                    .font(.system(size: 14, weight: .semibold)).toggleStyle(.switch)
                Picker("Start the reminder", selection: $model.immediate) {
                    Text("Immediately").tag(true)
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
                Text(model.conditionText).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("The intro plays once, the loop repeats, and reconnecting AC hides the cat with a pop.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("On your desktop").font(.system(size: 14, weight: .semibold))
                Toggle("Fit animation across the entire screen", isOn: $model.fullScreen)
                    .toggleStyle(.switch)
                if NSScreen.screens.count > 1 {
                    HStack {
                        Text("Display").foregroundStyle(.secondary)
                        Spacer()
                        Picker("Display", selection: $model.screenIndex) {
                            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                                Text("\(index + 1) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))").tag(index)
                            }
                        }.labelsHidden().frame(width: 190)
                    }
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
                Text("The cat stays above your apps. Clicks and typing pass through to your desktop.")
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
                } else {
                    Button("Preview cat") { model.previewCat() }
                        .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.white).controlSize(.large)
                }
            }

            Divider()
            AppUpdateSettingsView(updates: updates)
            Divider()
            SupportView()
        }
        .padding(26)
        .frame(width: 500)
        }
        .frame(width: 500, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
    }

    private var connectionSettings: some View {
        DisclosureGroup("Connection settings") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Connect using", selection: $model.transport) {
                    Text("Automatic").tag(EcoFlowTransport.automatic)
                    Text("USB").tag(EcoFlowTransport.usb)
                    Text("Bluetooth").tag(EcoFlowTransport.bluetooth)
                    Text("Wi-Fi (cloud)").tag(EcoFlowTransport.wifi)
                }
                Text("Quit the EcoFlow app and PowerManager before connecting. Automatic tries USB, then Bluetooth, then configured Wi-Fi.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.transport == .bluetooth || model.transport == .automatic {
                    Label(model.bluetoothSetupMessage, systemImage: model.bluetoothAccountReady ? "checkmark.circle.fill" : "person.crop.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.bluetoothAccountReady {
                        Button(model.isFindingAccount ? "Finding your account…" : "Find existing EcoFlow sign-in") { model.findEcoFlowAccount() }
                            .disabled(model.isFindingAccount)
                    }
                    DisclosureGroup(model.bluetoothAccountReady ? "Use another EcoFlow account" : "Sign in to enable Bluetooth") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("EcoFlow email", text: $accountEmail)
                            SecureField("EcoFlow password", text: $accountPassword)
                            Picker("Account region", selection: $model.cloudRegion) {
                                Text("Global").tag(EcoFlowCloudRegion.global)
                                Text("Europe").tag(EcoFlowCloudRegion.europe)
                                Text("America").tag(EcoFlowCloudRegion.america)
                            }
                            Text("Sign in once with the account paired with your DELTA. After setup, Bluetooth connects automatically without Internet. Your password is never saved.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(model.isSigningIn ? "Signing in…" : "Sign in for Bluetooth") {
                                let password = accountPassword
                                accountPassword = ""
                                Task { await model.signInForBluetooth(email: accountEmail, password: password) }
                            }.disabled(model.isSigningIn || accountEmail.isEmpty || accountPassword.isEmpty)
                        }.padding(.top, 8)
                    }
                }
                if model.transport == .bluetooth || model.transport == .automatic {
                    DisclosureGroup("Choose a specific station (optional)") {
                        TextField("Station serial number", text: $model.serialNumber)
                            .help("Leave empty to discover your nearby DELTA automatically.")
                    }
                }
                if model.transport == .wifi || model.transport == .automatic {
                    DisclosureGroup("Wi-Fi cloud credentials") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Account region", selection: $model.cloudRegion) {
                                Text("Global").tag(EcoFlowCloudRegion.global)
                                Text("Europe").tag(EcoFlowCloudRegion.europe)
                                Text("America").tag(EcoFlowCloudRegion.america)
                            }
                            TextField("Station serial number", text: $model.serialNumber)
                            SecureField("EcoFlow developer access key", text: $model.cloudAccessKey)
                            SecureField("EcoFlow developer secret key", text: $model.cloudSecretKey)
                            Text("Requires your DELTA online through Wi-Fi, its serial number, and EcoFlow developer API credentials. Credentials are stored in this Mac’s Keychain.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.top, 8)
                    }
                }
                HStack {
                    if let message = model.connectionSettingsMessage {
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Save & connect") { model.saveConnectionSettings() }
                }
            }.textFieldStyle(.roundedBorder).padding(.top, 10)
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
