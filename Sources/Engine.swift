import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ToolResult {
    let status: Int32
    let output: String
    let data: Data
    init(status: Int32, output: String) { self.status = status; self.output = output; data = Data(output.utf8) }
    init(status: Int32, data: Data) { self.status = status; self.data = data; output = String(decoding: data, as: UTF8.self) }
    var document: [String: Any]? {
        let json = output.components(separatedBy: "\nerror:").first ?? output
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }
    var records: [[String: Any]] {
        output.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }
    var failure: String {
        if let record = records.last(where: { $0["error"] != nil }), let error = record["error"] as? String { return error }
        return String(output.suffix(5000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Read continuously on a background queue so large helper output cannot deadlock a pipe.
final class ToolRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
    func run(_ executable: URL, _ arguments: [String], input: Data? = nil) async throws -> ToolResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), output = Pipe(), stdin = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = output
                process.standardInput = stdin
                var environment = ProcessInfo.processInfo.environment
                environment["NO_COLOR"] = "1"
                // State and account secrets use the helper's dedicated AppStore++ storage.
                environment.removeValue(forKey: "XDG_STATE_HOME")
                environment.removeValue(forKey: "XDG_DATA_HOME")
                process.environment = environment
                self.lock.lock()
                if self.cancelled { self.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.process = process
                do { try process.run() } catch {
                    self.process = nil; self.lock.unlock(); continuation.resume(throwing: error); return
                }
                self.lock.unlock()
                if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
                try? stdin.fileHandleForWriting.close()
                var data = Data()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    if data.count > 2_000_000 { data = Data(data.suffix(2_000_000)) }
                }
                process.waitUntilExit()
                self.lock.lock(); self.process = nil; let cancelled = self.cancelled; self.lock.unlock()
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else { continuation.resume(returning: ToolResult(status: process.terminationStatus, data: data)) }
            }
        }
    }
}

enum DownloadPlatform: String, CaseIterable, Identifiable {
    case iOS = "iphone", iPadOS = "ipad", tvOS = "appletv"
    var id: String { rawValue }
    var title: String {
        switch self { case .iOS: return "iOS (iPhone)"; case .iPadOS: return "iPadOS (iPad)"; case .tvOS: return "tvOS (Apple TV)" }
    }
}

struct StoreApp: Identifiable {
    let id: Int64
    let name: String
    let bundleID: String
    let version: String
    let price: Double
    let platform: DownloadPlatform
    init?(_ record: [String: Any], platform: DownloadPlatform = .iOS) {
        guard let id = record["id"] as? NSNumber, let name = record["name"] as? String else { return nil }
        self.id = id.int64Value; self.name = name
        bundleID = record["bundleID"] as? String ?? ""
        version = record["version"] as? String ?? ""
        price = (record["price"] as? NSNumber)?.doubleValue ?? 0
        self.platform = platform
    }
}

enum Section: String, CaseIterable, Identifiable {
    case discover = "Download", decrypt = "Decrypt", setup = "Setup", guide = "Help"
    var id: String { rawValue }
    var icon: String {
        switch self { case .discover: return "square.grid.2x2"; case .decrypt: return "lock.open"; case .setup: return "slider.horizontal.3"; case .guide: return "book.closed" }
    }
}

struct DecryptionRequest {
    let input: URL
    let output: URL
}

enum EnrollmentModelFile {
    // Only inspect the fixed-size header. Never load an accidentally selected IPA into memory.
    static func validate(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 16) ?? Data()
        if header.starts(with: [0x50, 0x4b]) {
            throw AppError.message("That file is an IPA/ZIP, not a decryption model. Choose an IPA under Encrypted IPA. Click Decrypt to create the model through setup automatically.")
        }
        guard header.count == 16 else { throw AppError.message("This is not a valid FairPlay enrollment model. Click Decrypt to start setup.") }
        func word(_ offset: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[offset + $1]) << ($1 * 8) } }
        let magic = String(decoding: header.prefix(8), as: UTF8.self)
        let formats: [String: (UInt32, UInt64)] = ["FPS26A4\0": (1, 4176), "FPSENR1\0": (1, 4176), "FPSENR2\0": (2, 4184), "FPSENR3\0": (3, 8708)]
        guard let format = formats[magic], word(8) == format.0, size == format.1, UInt64(word(12)) == size else {
            throw AppError.message("This file is damaged or is not a supported FairPlay enrollment model. Click Decrypt to start setup; changing a file’s name to .bin does not create a model.")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section: Section = .discover
    @Published var email = ""
    @Published var password = ""
    @Published var code = ""
    @Published var needsCode = false
    @Published var showLogin = false
    @Published var signedIn = false
    @Published var accountName = "Not signed in"
    @Published var query = ""
    @Published var downloadPlatform: DownloadPlatform = .iOS {
        didSet { if downloadPlatform != oldValue { apps = []; searched = false }; defaults.set(downloadPlatform.rawValue, forKey: "downloadPlatform") }
    }
    @Published var apps: [StoreApp] = []
    @Published var searched = false
    @Published var busy = false
    @Published var cancellable = true
    @Published var status = "Ready when you are."
    @Published var errorText: String?
    @Published var licenseURL: URL?
    @Published var loginError: String?
    @Published var events: [String] = []
    @Published var ipa: URL?
    @Published var installedApp: URL?
    @Published var setupIPA: URL?
    @Published var setupMessage = "Choose an installed iPhone/iPad app. AppStore++ can download its matching setup IPA and create your model."
    @Published var pendingDecryption: DecryptionRequest?
    @Published var modelURL: URL?
    @Published var lastOutput: URL?
    @Published var autoDecrypt = false { didSet { defaults.set(autoDecrypt, forKey: "autoDecrypt") } }
    @Published var outputDirectory: URL
    @Published var downloadDirectory: URL
    @Published var showActivity = false
    let runner = ToolRunner()
    let support: URL
    let defaults: UserDefaults
    let applicationDirectories: [URL]
    let collectOverride: ((URL, URL, URL) async throws -> Void)?
    init(defaults: UserDefaults = .standard, support: URL? = nil, applicationDirectories: [URL]? = nil, collectOverride: ((URL, URL, URL) async throws -> Void)? = nil) {
        self.defaults = defaults
        self.collectOverride = collectOverride
        self.support = support ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AppStorePlusPlus", isDirectory: true)
        self.applicationDirectories = applicationDirectories ?? [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let initialOutput = defaults.string(forKey: "outputDirectory").map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/AppStore++", isDirectory: true)
        outputDirectory = initialOutput
        downloadDirectory = defaults.string(forKey: "downloadDirectory").map { URL(fileURLWithPath: $0) } ?? initialOutput
        downloadPlatform = DownloadPlatform(rawValue: defaults.string(forKey: "downloadPlatform") ?? "") ?? .iOS
        autoDecrypt = defaults.object(forKey: "autoDecrypt") as? Bool ?? false
        if let path = defaults.string(forKey: "modelPath") {
            let url = URL(fileURLWithPath: path)
            if (try? EnrollmentModelFile.validate(url)) != nil { modelURL = url }
            else { defaults.removeObject(forKey: "modelPath"); status = "The saved model was invalid. Click Decrypt to set up a real model." }
        }
        email = defaults.string(forKey: "email") ?? ""
    }
    func helper(_ name: String) throws -> URL {
        guard let resources = Bundle.main.resourceURL else { throw AppError.message("The app bundle is incomplete. Reinstall AppStore++.") }
        let url = resources.appendingPathComponent("Tools/" + name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw AppError.message("The bundled \(name) helper is missing. Reinstall AppStore++.") }
        return url
    }
    func note(_ text: String) { status = text; events.append(text); if events.count > 80 { events.removeFirst() } }
    func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    func start(_ title: String, action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; errorText = nil; licenseURL = nil; runner.reset(); note(title)
        Task {
            defer { busy = false; cancellable = true }
            do { try await action() }
            catch is CancellationError { note("Cancelled. Any incomplete download may be removed manually.") }
            catch {
                var text = error.localizedDescription
                if !password.isEmpty { text = text.replacingOccurrences(of: password, with: "[hidden]") }
                if !code.isEmpty { text = text.replacingOccurrences(of: code, with: "[hidden]") }
                if showLogin { loginError = text } else { errorText = text }
                note("The operation could not finish.")
            }
        }
    }
    func tool(_ name: String, _ args: [String], input: Data? = nil) async throws -> ToolResult {
        let result = try await runner.run(helper(name), args, input: input)
        if result.status != 0, name == "ipatool", result.failure.localizedCaseInsensitiveContains("license is required") {
            if let flag = args.firstIndex(of: "--app-id"), args.indices.contains(flag + 1), Int64(args[flag + 1]) != nil {
                licenseURL = URL(string: "https://apps.apple.com/app/id" + args[flag + 1])
            }
            throw AppError.message("Apple reports that this account has no download license for the app. Open its page in Apple’s App Store and choose Get (or the cloud-download button) using the SAME Apple Account as AppStore++. If it is unavailable on your Mac, get it on your iPhone or iPad using that account, then retry here. If you already own it, check the account and sign in again. This is an App Store ownership requirement, not a decryption-model error.")
        }
        guard result.status == 0 else { throw AppError.message(result.failure.isEmpty ? "\(name) stopped unexpectedly (\(result.status))." : result.failure) }
        return result
    }
    func login() {
        guard !email.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { return }
        if needsCode && (code.count != 6 || !code.allSatisfy({ $0.isASCII && $0.isNumber })) {
            loginError = "Enter the six-digit verification code from Apple."; return
        }
        loginError = nil
        start(needsCode ? "Verifying your Apple Account…" : "Signing in… First sign-in can take a few minutes.") {
            defer { if !self.needsCode { self.password = ""; self.code = "" } }
            let credentials = try JSONSerialization.data(withJSONObject: ["Email": self.email.trimmingCharacters(in: .whitespaces), "Password": self.password, "AuthCode": self.needsCode ? self.code : ""])
            do {
                let result = try await self.tool("ipatool", ["--format", "json", "--non-interactive", "auth", "login", "--credentials-stdin"], input: credentials)
                if result.records.contains(where: { ($0["message"] as? String)?.contains("2FA code is required") == true }) {
                    self.needsCode = true; self.code = ""; self.note("Enter Apple's six-digit verification code to continue."); return
                }
                guard let account = result.records.last(where: { $0["success"] as? Bool == true }) else { throw AppError.message("Apple did not confirm sign-in. Try signing in again.") }
                self.signedIn = true; self.needsCode = false
                self.accountName = account["email"] as? String ?? self.email
                self.defaults.set(self.accountName, forKey: "email")
                self.showLogin = false; self.note("Signed in. Search for an app to get started.")
            } catch {
                var text = error.localizedDescription
                if !self.password.isEmpty { text = text.replacingOccurrences(of: self.password, with: "[hidden]") }
                if !self.code.isEmpty { text = text.replacingOccurrences(of: self.code, with: "[hidden]") }
                self.loginError = text
                throw error
            }
        }
    }
    func dismissLogin() { guard !busy else { return }; password = ""; code = ""; needsCode = false; loginError = nil; showLogin = false }
    func checkSession() {
        start("Checking your saved session…") {
            let result = try await self.tool("ipatool", ["--format", "json", "--non-interactive", "auth", "info"])
            guard let account = result.records.last(where: { $0["success"] as? Bool == true }) else { throw AppError.message("No saved session. Sign in to continue.") }
            self.signedIn = true; self.accountName = account["email"] as? String ?? "Signed in"
            self.note("Signed in with your saved Apple Account.")
        }
    }
    func signOut() {
        start("Signing out…") {
            _ = try await self.tool("ipatool", ["--format", "json", "--non-interactive", "auth", "revoke"])
            self.signedIn = false; self.accountName = "Not signed in"; self.password = ""; self.code = ""; self.apps = []
            self.note("Signed out. Your decryption model is still stored locally.")
        }
    }
    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if !signedIn { showLogin = true; return }
        let platform = downloadPlatform
        start("Searching the App Store…") {
            let result = try await self.tool("ipatool", ["--format", "json", "--non-interactive", "search", term, "--limit", "20", "--platform", platform.rawValue])
            guard let records = result.records.last(where: { $0["apps"] != nil })?["apps"] as? [[String: Any]] else { throw AppError.message("The App Store returned an unreadable search response.") }
            self.apps = records.compactMap { StoreApp($0, platform: platform) }; self.searched = true
            self.note("Found \(self.apps.count) apps.")
        }
    }
    func openPanel(message: String, directory: Bool = false, types: [UTType] = []) -> URL? {
        let panel = NSOpenPanel(); panel.message = message; panel.allowsMultipleSelection = false
        panel.canChooseFiles = !directory; panel.canChooseDirectories = directory
        panel.treatsFilePackagesAsDirectories = false
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }
    func pickIPA() {
        guard let url = openPanel(message: "Choose an encrypted .ipa file", types: [UTType(filenameExtension: "ipa") ?? .data]), url.pathExtension.lowercased() == "ipa" else { return }
        ipa = url
    }
    func pickApp() {
        guard let url = openPanel(message: "Choose the matching iPhone/iPad app installed from the Mac App Store", types: [.applicationBundle]), url.pathExtension.lowercased() == "app" else { return }
        installedApp = url
    }
    func chooseOutputDirectory() {
        guard !busy, let url = openPanel(message: "Choose where to save decrypted IPAs", directory: true) else { return }
        outputDirectory = url; defaults.set(url.path, forKey: "outputDirectory")
    }
    func chooseDownloadDirectory() {
        guard !busy, let url = openPanel(message: "Choose where to save downloaded IPAs", directory: true) else { return }
        downloadDirectory = url; defaults.set(url.path, forKey: "downloadDirectory")
    }
    func pickSetupIPA() {
        guard let url = openPanel(message: "Optional: choose the IPA matching the installed setup app", types: [UTType(filenameExtension: "ipa") ?? .data]), url.pathExtension.lowercased() == "ipa" else { return }
        setupIPA = url
    }
    func validateModel(_ url: URL) async throws {
        try EnrollmentModelFile.validate(url)
        let result = try await runner.run(helper("unfairplay"), ["doctor", "--model", url.path])
        guard result.status == 0, let checks = result.document?["checks"] as? [String: Any], checks["model_valid"] as? Bool == true else {
            throw AppError.message("The enrollment model failed validation. Create a new one through Decryption setup.")
        }
    }
    func rememberModel(_ url: URL) { modelURL = url; defaults.set(url.path, forKey: "modelPath") }
    func forgetModel() { modelURL = nil; defaults.removeObject(forKey: "modelPath") }
    func importModel() {
        guard !busy, let url = openPanel(message: "Choose an existing fairplay-enrollment.bin model, not an IPA") else { return }
        start("Checking the imported model…") { try await self.importModelFile(url) }
    }
    func importModelFile(_ url: URL) async throws {
        try EnrollmentModelFile.validate(url)
        try privateDirectory(support)
        let target = support.appendingPathComponent("model-\(UUID().uuidString).bin")
        var accepted = false
        defer { if !accepted { try? FileManager.default.removeItem(at: target) } }
        try FileManager.default.copyItem(at: url, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try await validateModel(target)
        rememberModel(target); accepted = true
        if let request = pendingDecryption { try await finishDecryption(request, model: target) }
        else { note("Model validated and saved. You can now decrypt with one click.") }
    }
    func nextOutput(stem: String, extension ext: String, directory: URL? = nil) throws -> URL {
        let folder = directory ?? outputDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safe = String(stem.map { $0.isLetter || $0.isNumber || ".-_".contains($0) ? $0 : "_" }.prefix(100))
        return folder.appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(8)).\(ext)")
    }
    func download(_ app: StoreApp) {
        guard !busy else { return }
        guard signedIn else { showLogin = true; return }
        let decryptAfterDownload = autoDecrypt
        start("Downloading \(app.name)…") { try await self.downloadAndProcess(app, decryptAfterDownload: decryptAfterDownload) }
    }
    func downloadAndProcess(_ app: StoreApp, decryptAfterDownload: Bool) async throws {
        let destination = try nextOutput(stem: (app.bundleID.isEmpty ? String(app.id) : app.bundleID) + "-" + app.platform.rawValue, extension: "ipa", directory: downloadDirectory)
        // No --purchase: only use licenses already owned by this Apple Account.
        _ = try await self.tool("ipatool", ["--format", "json", "--non-interactive", "download", "--app-id", String(app.id), "--platform", app.platform.rawValue, "--output", destination.path])
        guard FileManager.default.fileExists(atPath: destination.path) else { throw AppError.message("The download finished without creating an IPA.") }
        ipa = destination; lastOutput = destination; note("Downloaded \(app.name).")
        if decryptAfterDownload {
            let output = try nextOutput(stem: destination.deletingPathExtension().lastPathComponent, extension: "decrypted.ipa")
            let request = DecryptionRequest(input: destination, output: output)
            try await processDecryption(request, bundleID: app.bundleID.isEmpty ? nil : app.bundleID)
        }
    }
    func decryptFile(_ input: URL, model: URL, output: URL) async throws {
        note("Decrypting and validating the IPA…")
        let report = output.deletingPathExtension().appendingPathExtension("json")
        _ = try await self.tool("unfairplay", ["decrypt", "--input", input.path, "--model", model.path, "--output", output.path, "--report", report.path])
        guard FileManager.default.fileExists(atPath: output.path) else { throw AppError.message("Decryption did not produce an IPA. The encrypted download has been kept.") }
        lastOutput = output; note("Decrypted IPA saved: \(output.lastPathComponent)")
    }
    func decrypt() {
        guard !busy else { return }
        if ipa == nil { pickIPA() }
        guard let ipa else { return }
        start("Preparing one-click decryption…") {
            let output = try self.nextOutput(stem: ipa.deletingPathExtension().lastPathComponent, extension: "decrypted.ipa")
            try await self.processDecryption(DecryptionRequest(input: ipa, output: output))
        }
    }
    func finishDecryption(_ request: DecryptionRequest, model: URL) async throws {
        do {
            try await decryptFile(request.input, model: model, output: request.output)
            pendingDecryption = nil; section = .decrypt
        } catch is CancellationError { throw CancellationError() }
        catch {
            let text = error.localizedDescription
            let mismatch = ["does not match", "no enrollment model", "selector mismatch", "account mismatch", "bound to selector"].contains { text.localizedCaseInsensitiveContains($0) }
            if mismatch {
                forgetModel(); pendingDecryption = request; section = .setup
                setupMessage = "This model does not match the IPA. Choose an installed iPhone/iPad app from the same Apple Account, then click Set up & finish decryption. Your download is kept."
                note("A matching enrollment is needed. Finish setup to resume decryption.")
            } else { throw error }
        }
    }
    func processDecryption(_ request: DecryptionRequest, bundleID: String? = nil) async throws {
        pendingDecryption = request
        if let model = modelURL {
            do { try await validateModel(model) }
            catch is CancellationError { throw CancellationError() }
            catch { forgetModel(); note("The saved model is invalid. Starting decryption setup…") }
        }
        if let model = modelURL { try await finishDecryption(request, model: model); return }
        let id: String
        if let bundleID, !bundleID.isEmpty { id = bundleID }
        else { id = try await ipaBundleID(request.input) }
        if let matching = findInstalledApp(bundleID: id) {
            installedApp = matching; setupIPA = request.input
            let model = try await recoverEnrollment(app: matching, seed: request.input)
            try await finishDecryption(request, model: model)
        } else {
            section = .setup
            setupMessage = "Your IPA is ready. A decryption model must be created once. Choose an iPhone/iPad app you installed and opened from the Mac App Store, then click Set up & finish decryption. We’ll download its matching setup IPA and resume automatically."
            note("Waiting for first-time setup. Your IPA is saved; no need to download it again.")
        }
    }
    func verify() {
        guard let ipa, let modelURL else { return }
        start("Checking whether this model can decrypt your IPA…") {
            try await self.validateModel(modelURL)
            _ = try await self.tool("unfairplay", ["verify", "--input", ipa.path, "--model", modelURL.path])
            self.note("Verified. This model successfully decrypts and validates the IPA.")
        }
    }
    func ipaBundleID(_ url: URL) async throws -> String {
        let listing = try await runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", url.path])
        let members = listing.output.split(separator: "\n").map(String.init).filter {
            let parts = $0.split(separator: "/")
            return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
        }
        guard listing.status == 0, members.count == 1 else { throw AppError.message("The selected file is not a readable iPhone/iPad IPA with a single app. Choose the original encrypted IPA.") }
        let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", url.path, members[0]])
        guard result.status == 0, let plist = (try? PropertyListSerialization.propertyList(from: result.data, format: nil)) as? [String: Any], let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else {
            throw AppError.message("Could not read the app identifier from this IPA.")
        }
        return id
    }
    func installedBundleID(_ url: URL) -> String? {
        var candidates = [url.appendingPathComponent("Info.plist")]
        let wrapper = url.appendingPathComponent("Wrapper")
        for inner in (try? FileManager.default.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil)) ?? [] where inner.pathExtension == "app" {
            candidates.append(inner.appendingPathComponent("Info.plist"))
        }
        for candidate in candidates {
            if let data = try? Data(contentsOf: candidate), let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any], let id = plist["CFBundleIdentifier"] as? String { return id }
        }
        return nil
    }
    func findInstalledApp(bundleID: String) -> URL? {
        for root in applicationDirectories {
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in entries {
                if url.pathComponents.count > root.pathComponents.count + 2 { entries.skipDescendants(); continue }
                if url.pathExtension == "app", installedBundleID(url) == bundleID { return url }
            }
        }
        return nil
    }
    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleQuote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    func cancelPendingDecryption() {
        guard !busy else { return }
        pendingDecryption = nil; note("Pending decryption cleared. Your downloaded IPA is kept.")
    }
    func recover() {
        guard !busy, let installedApp else { return }
        let request = pendingDecryption
        start("Preparing decryption setup…") {
            guard let id = self.installedBundleID(installedApp) else { throw AppError.message("Choose an iPhone/iPad app installed from the Mac App Store, not the App Store application itself.") }
            var seed = self.setupIPA
            if let candidate = seed, try await self.ipaBundleID(candidate) != id { seed = nil }
            if seed == nil, let candidate = self.ipa, try await self.ipaBundleID(candidate) == id { seed = candidate }
            if seed == nil {
                guard self.signedIn else { throw AppError.message("Sign in to download the matching setup IPA, or choose its IPA under Optional setup IPA. Your pending decryption is kept.") }
                try self.privateDirectory(self.support)
                let destination = self.support.appendingPathComponent("Setup-\(UUID().uuidString).ipa")
                self.note("Downloading the IPA matching your installed setup app…")
                _ = try await self.tool("ipatool", ["--format", "json", "--non-interactive", "download", "--bundle-identifier", id, "--platform", "iphone", "--output", destination.path])
                guard try await self.ipaBundleID(destination) == id else { throw AppError.message("The setup download did not match the installed app.") }
                seed = destination
            }
            guard let seed else { throw AppError.message("A matching setup IPA is required.") }
            self.setupIPA = seed
            let model = try await self.recoverEnrollment(app: installedApp, seed: seed)
            if let request { try await self.finishDecryption(request, model: model) }
            else { self.note("Decryption is ready. Choose an IPA and click Decrypt.") }
        }
    }
    func recoverEnrollment(app: URL, seed: URL) async throws -> URL {
        try privateDirectory(support)
        let session = support.appendingPathComponent("Enrollment-" + UUID().uuidString, isDirectory: true)
        try privateDirectory(session)
        let capture = session.appendingPathComponent("Capture", isDirectory: true)
        let recovery = session.appendingPathComponent("Recovery", isDirectory: true)
        note("Collecting enrollment… Approve the macOS administrator prompt.")
        cancellable = false
        defer { cancellable = true }
        if let collectOverride { try await collectOverride(app, seed, capture) }
        else {
            let command = ["/usr/bin/env", "SUDO_UID=\(getuid())", "SUDO_GID=\(getgid())", try helper("unfairplay").path, "collect", "--app", app.path, "--ipa", seed.path, "--output", capture.path].map(Self.shellQuote).joined(separator: " ")
            let script = "do shell script " + Self.appleQuote(command) + " with administrator privileges with prompt \"AppStore++ needs to read this Mac's FairPlay enrollment for decryption setup.\""
            let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
            guard result.status == 0 else { throw AppError.message(result.failure) }
        }
        cancellable = true
        note("Recovering and validating your decryption model… This may take several minutes.")
        _ = try await tool("unfairplay", ["recover", "--capture", capture.path, "--output", recovery.path])
        let model = recovery.appendingPathComponent("fairplay-enrollment.bin")
        try await validateModel(model)
        rememberModel(model)
        return model
    }
    func revealOutput() { if let lastOutput { NSWorkspace.shared.activateFileViewerSelecting([lastOutput]) } }
}
