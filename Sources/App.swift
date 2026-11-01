import SwiftUI
import AppKit

@main
struct AppStorePlusPlusApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("AppStore++") {
            ContentView().environmentObject(model).frame(minWidth: 860, minHeight: 640)
        }
        .defaultSize(width: 980, height: 740)
        .commands {
            CommandGroup(replacing: .help) {
                Button("AppStore++ Help") { model.section = .guide }.keyboardShortcut("?", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Choose IPA…") { model.section = .decrypt; model.pickIPA() }.keyboardShortcut("o", modifiers: .command).disabled(model.busy)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(m.signedIn ? m.accountName : "Not signed in").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if m.signedIn {
                    Button("Sign Out") { m.signOut() }.disabled(m.busy)
                } else {
                    Button("Use Saved Sign-In") { m.checkSession() }.disabled(m.busy)
                    Button("Sign In…") { m.showLogin = true }.disabled(m.busy)
                }
                DonationButton()
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            TabView(selection: $m.section) {
                download.tabItem { Text("Download") }.tag(Section.discover)
                decrypt.tabItem { Text("Decrypt") }.tag(Section.decrypt)
                setup.tabItem { Text("Setup") }.tag(Section.setup)
                help.tabItem { Text("Help") }.tag(Section.guide)
            }.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if m.busy { ProgressView().controlSize(.small) }
                    Text(m.status).font(.callout).lineLimit(2).accessibilityIdentifier("operation-status")
                    Spacer(minLength: 8)
                    if m.busy && m.cancellable { Button("Cancel") { m.runner.cancel() } }
                    if m.lastOutput != nil { Button("Show in Finder") { m.revealOutput() } }
                    Button(m.showActivity ? "Hide Activity" : "Activity") { m.showActivity.toggle() }
                }
                if m.showActivity {
                    ScrollView {
                        Text(m.events.suffix(20).joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 100)
                }
            }.padding(12)
        }
        .sheet(isPresented: $m.showLogin, onDismiss: { m.password = ""; m.code = ""; m.needsCode = false }) { LoginView().environmentObject(m) }
        .alert("Couldn’t Finish", isPresented: Binding(get: { m.errorText != nil }, set: { if !$0 { m.errorText = nil } })) {
            if let url = m.licenseURL { Button("Open App Store Page") { NSWorkspace.shared.open(url); m.errorText = nil } }
            Button("OK") { m.errorText = nil }
        } message: { Text(m.errorText ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in m.runner.cancel() }
    }
    var download: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Platform:", selection: $m.downloadPlatform) {
                    ForEach(DownloadPlatform.allCases) { platform in Text(platform.title).tag(platform) }
                }.pickerStyle(.menu).frame(width: 230).disabled(m.busy)
                TextField("App name", text: $m.query).textFieldStyle(.roundedBorder).onSubmit { m.search() }.disabled(m.busy)
                Button("Search") { m.search() }.disabled(m.busy || m.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Table(m.apps) {
                TableColumn("App") { app in Text(app.name).lineLimit(2) }.width(min: 140, ideal: 210)
                TableColumn("Bundle Identifier") { app in Text(app.bundleID).foregroundStyle(.secondary).lineLimit(1).help(app.bundleID) }
                TableColumn("Version") { app in Text(app.version) }.width(85)
                TableColumn("") { app in
                    Button("Download IPA") { m.download(app) }.disabled(m.busy).accessibilityLabel("Download IPA for " + app.name)
                }.width(120)
            }
            .overlay {
                if m.apps.isEmpty {
                    Text(m.searched ? "No apps found. Try another search." : "Select a platform and search for an app.")
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            folderRow("Download folder:", url: m.downloadDirectory) { m.chooseDownloadDirectory() }
            HStack {
                Toggle("Decrypt after downloading", isOn: $m.autoDecrypt).disabled(m.busy)
                Spacer()
                if m.autoDecrypt { Text("Uses the output folder on the Decrypt tab.").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Use the same Apple Account as the Mac App Store. You must already own the app’s license. Results depend on platform availability.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(12)
    }
    func folderRow(_ label: String, url: URL, action: @escaping () -> Void) -> some View {
        HStack {
            Text(label).frame(width: 115, alignment: .trailing)
            Text(url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(url.path)
            Spacer(minLength: 8)
            Button("Choose Folder…", action: action).disabled(m.busy)
        }.font(.callout)
    }
    var decrypt: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Decrypt an IPA") {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("IPA file:").frame(width: 115, alignment: .trailing)
                        Text(m.ipa?.path ?? "No IPA selected").lineLimit(1).truncationMode(.middle).textSelection(.enabled).foregroundStyle(m.ipa == nil ? .secondary : .primary).help(m.ipa?.path ?? "")
                        Spacer(minLength: 8)
                        Button("Choose IPA…") { m.pickIPA() }.disabled(m.busy)
                    }
                    folderRow("Output folder:", url: m.outputDirectory) { m.chooseOutputDirectory() }
                    HStack {
                        Spacer().frame(width: 115)
                        Button("Decrypt") { m.decrypt() }.buttonStyle(.borderedProminent).disabled(m.busy || m.ipa == nil)
                        Button("Verify IPA") { m.verify() }.disabled(m.busy || m.ipa == nil || m.modelURL == nil)
                        Spacer()
                    }
                }.padding(12)
            }
            HStack {
                Label(m.modelURL == nil ? "First-time setup required" : "Saved decryption model available", systemImage: m.modelURL == nil ? "info.circle" : "checkmark.circle")
                Spacer()
                Button("Setup…") { m.section = .setup }
            }.font(.callout).foregroundStyle(.secondary)
            Text("Choose an IPA and output folder, then click Decrypt. The original file is kept. A new file and validation report are saved without replacing earlier results.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let output = m.lastOutput {
                GroupBox("Last Saved File") {
                    HStack {
                        Text(output.lastPathComponent).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button("Show in Finder") { m.revealOutput() }
                    }.padding(8)
                }
            }
            Spacer()
        }.padding(12)
    }
    var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let request = m.pendingDecryption {
                    GroupBox("Decryption Waiting for Setup") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(request.input.lastPathComponent).fontWeight(.medium)
                            Text(m.setupMessage).font(.callout)
                            Button("Cancel Pending Decryption") { m.cancelPendingDecryption() }.disabled(m.busy)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                Text("First-Time Setup").font(.headline)
                Text("Install an iPhone or iPad app from the native Mac App Store and open it once. Use the same Apple Account here. Choose that installed app below. AppStore++ downloads its matching setup IPA and creates a private model.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                GroupBox("Installed Setup App") {
                    VStack(spacing: 14) {
                        HStack {
                            Text(m.installedApp?.lastPathComponent ?? "No installed app selected").lineLimit(1)
                            Spacer()
                            Button("Choose App…") { m.pickApp() }.disabled(m.busy)
                        }
                        HStack {
                            Text("Optional setup IPA: " + (m.setupIPA?.lastPathComponent ?? "Download automatically")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("Choose IPA…") { m.pickSetupIPA() }.disabled(m.busy)
                        }
                        HStack {
                            Button(m.pendingDecryption == nil ? "Set Up Decryption" : "Set Up & Finish Decryption") { m.recover() }.disabled(m.busy || m.installedApp == nil)
                            Spacer()
                        }
                    }.padding(10)
                }
                Text("Leave Optional setup IPA empty unless you already have the IPA matching this installed app. macOS will ask for administrator approval during collection. Once recovery succeeds, a waiting decryption resumes automatically.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Label(m.modelURL == nil ? "No model saved" : "A model is saved on this Mac", systemImage: "key")
                    Spacer()
                    Button("Import Existing Model…") { m.importModel() }.disabled(m.busy)
                }
                Text("Keep captures and models private. Downloading for iOS, iPadOS, or tvOS does not guarantee decryption: the IPA must be compatible with the saved enrollment and UnfairPlay engine.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(12)
        }
    }
    var help: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Download an IPA").font(.headline)
                Text("1. Sign in using the same Apple Account as the Mac App Store.\n2. Choose iOS, iPadOS, or tvOS from the Platform menu.\n3. Search for an app and click Download IPA.\n4. Downloads go to the chosen download folder. Enable Decrypt after downloading only if you want both steps together.")
                Text("Decrypt an IPA").font(.headline)
                Text("1. Open the Decrypt tab and click Choose IPA.\n2. Choose the output folder.\n3. Click Decrypt. The saved model is checked automatically.\n4. If setup opens, complete the one-time instructions there. The pending IPA resumes after successful recovery.")
                Text("Sign-In and Verification").font(.headline)
                Text("Enter the six-digit verification code Apple provides on a trusted device or by SMS. ipatool cannot choose or send SMS or email codes. Credentials are passed privately to ipatool, which uses macOS Keychain. Do not paste passwords or codes into chat.")
                Text("Free to Use").font(.headline)
                Text("AppStore++ is free. Donations are optional and do not unlock features or affect downloads. Use Buy Me a Coffee at the top right if you would like to support development.")
                Link("Support AppStore++ on Buy Me a Coffee", destination: Donation.url)
                Text("Common Errors").font(.headline)
                Text("License required: get the app through Apple’s App Store using the same account, then retry.\nModel or account mismatch: recover using an installed app and matching IPA from the same enrollment.\nUnknown recovery block: update the app’s recovery engine.\nAn IPA renamed to .bin is not a decryption model.")
                Text("Decrypted IPAs are analysis files; installation still requires appropriate signing. Your original IPA is kept. Keep the app open during recovery.")
                Divider()
                HStack {
                    Link("ipatool", destination: URL(string: "https://github.com/majd/ipatool")!)
                    Link("UnfairPlay", destination: URL(string: "https://github.com/DrWhax/unfairplay")!)
                }
                Text("AppStore++ is independent and is not affiliated with Apple. Third-party license notices are included in the application bundle.").font(.caption).foregroundStyle(.secondary)
            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(m.needsCode ? "Verification Code" : "Apple Account Sign-In").font(.headline)
            Text(m.needsCode ? "Enter the six-digit code from Apple. Use a trusted device or Apple’s SMS options to obtain it." : "Use the same Apple Account as the native Mac App Store.").font(.callout).foregroundStyle(.secondary)
            if m.needsCode {
                TextField("Six-digit code", text: $m.code).textFieldStyle(.roundedBorder).disabled(m.busy).onSubmit { m.login() }
                Button("Start Again") { m.needsCode = false; m.password = ""; m.code = ""; m.loginError = nil }.disabled(m.busy)
            } else {
                TextField("Email or phone number", text: $m.email).textFieldStyle(.roundedBorder).disabled(m.busy)
                SecureField("Password", text: $m.password).textFieldStyle(.roundedBorder).disabled(m.busy).onSubmit { m.login() }
            }
            if let error = m.loginError { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if m.busy { HStack { ProgressView().controlSize(.small); Text(m.status).font(.caption) } }
            HStack {
                Button(m.busy ? "Stop" : "Cancel") { if m.busy { m.runner.cancel() } else { m.dismissLogin() } }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(m.needsCode ? "Verify & Sign In" : "Sign In") { m.login() }.keyboardShortcut(.defaultAction).disabled(m.busy || m.email.isEmpty || m.password.isEmpty || (m.needsCode && m.code.isEmpty))
            }
            Text("First sign-in can take a few minutes. Credentials are handled by ipatool and macOS Keychain.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 430).interactiveDismissDisabled(m.busy)
    }
}
