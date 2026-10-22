import AppKit
import SwiftUI

@MainActor
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var login: LaunchAtLogin
    let onFinish: () -> Void

    @State private var launchAtLogin = true
    private let tint = Color(red: 1, green: 0.584, blue: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(nsImage: OrangeArtwork.appIcon(size: 88))
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Meet Orange")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("File conversion, a drag away.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 21) {
                step(1, symbol: "cursorarrow.motionlines", title: "Start dragging a file",
                     detail: "Pick up a file in Finder and keep dragging it.")
                step(2, symbol: "circle.grid.3x3.circle", title: "Tap \(model.conversionShortcut.label)",
                     detail: "Release the key and mouse over the wheel, then click a format. Use \(model.toolsShortcut.label) for tools or \(model.actionsShortcut.label) for file actions.")
                step(3, symbol: "menubar.rectangle", title: "Keep Orange in your menu bar",
                     detail: "Close the window and the drag wheels stay ready. Open settings from the menu bar whenever you need them.")
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Launch Orange when I log in", isOn: $launchAtLogin)
                    .fontWeight(.medium)
                Text("Optional. You can set this up later in Orange Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 21)
            }

            if login.requiresApproval && launchAtLogin {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Approve launch at login in System Settings", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.callout.weight(.semibold))
                    Text("Orange works for this session. To start it automatically next time, allow Orange in Login Items.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items Settings") { login.openLoginItemsSettings() }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .contain)
            }

            if let error = login.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Orange still works. Finish setup now and retry launch at login in Settings whenever you want.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Retry launch at login") { login.retry() }
                        Button("Open Login Items Settings") { login.openLoginItemsSettings() }
                    }
                }
                .font(.callout)
                .accessibilityElement(children: .contain)
            }

            HStack {
                Text("Files stay on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Enable Orange", action: finish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(tint)
        .onAppear {
            login.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }

    private func step(_ number: Int, symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Text("\(number)")
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Label(title, systemImage: symbol)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func finish() {
        OrangeSetup.finish(login: login, launchAtLogin: launchAtLogin) {
            model.wheelEnabled = true
            onFinish()
        }
    }
}

@MainActor enum OrangeSetup {
    static func finish(login: LaunchAtLogin, launchAtLogin: Bool, enable: () -> Void) {
        // Optional OS registration must never gate the application's own setup.
        login.setEnabled(launchAtLogin)
        enable()
    }
}
