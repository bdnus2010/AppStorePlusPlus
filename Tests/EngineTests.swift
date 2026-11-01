import Foundation
import AppKit

@main
struct EngineTests {
    @MainActor
    static func main() async throws {
        precondition(Donation.url.absoluteString == "https://buymeacoffee.com/100xtoday")
        let parsed = ToolResult(status: 0, output: "preparing…\n{\"apps\":[{\"id\":123,\"name\":\"Example\",\"bundleID\":\"test.example\",\"version\":\"1\"}]}\n")
        precondition(parsed.records.count == 1)
        let app = StoreApp((parsed.records[0]["apps"] as! [[String: Any]])[0])!
        precondition(app.id == 123 && app.bundleID == "test.example")
        precondition(StoreApp(["name": "missing identifier"]) == nil)
        let runner = ToolRunner()
        let special = "a'b $(touch NEVER) \" quoted\nnext"
        let quoted = AppModel.shellQuote(special)
        let escaped = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf %s " + quoted])
        precondition(escaped.output == special, "shell quoting must preserve literals")
        let large = try await runner.run(URL(fileURLWithPath: "/usr/bin/head"), ["-c", "250000", "/dev/zero"])
        precondition(large.output.utf8.count == 250000, "large output must not deadlock")
        let sleeping = Task { try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"]) }
        try await Task.sleep(nanoseconds: 150_000_000)
        runner.cancel()
        do { _ = try await sleeping.value; preconditionFailure("cancel should throw") } catch is CancellationError { }
        runner.reset()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/test-fixtures")
        let work = root.appendingPathComponent("Run-" + UUID().uuidString)
        let domain = "local.appstoreplusplus.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var collections = 0
        let collect: (URL, URL, URL) async throws -> Void = { _, _, capture in
            collections += 1
            try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        }
        let m = AppModel(defaults: defaults, support: work.appendingPathComponent("Support"), applicationDirectories: [root.appendingPathComponent("NoApplications")], collectOverride: collect)
        m.outputDirectory = work.appendingPathComponent("Decrypted")
        m.downloadDirectory = work.appendingPathComponent("Downloads")
        m.showLogin = true; m.email = "person@example.test"; m.password = "test-secret"
        func idle() async throws {
            for _ in 0..<500 {
                if !m.busy { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            throw AppError.message("Test operation timed out")
        }
        m.login(); try await idle()
        precondition(m.needsCode && !m.signedIn && m.password == "test-secret", "first login must pause for 2FA")
        m.code = "short"; m.login()
        precondition(!m.busy && m.loginError != nil, "malformed code must not start a request")
        m.code = "000000"; m.login(); try await idle()
        precondition(m.needsCode && !m.signedIn && m.loginError != nil, "rejected code must allow retry")
        m.code = "123456"; m.login(); try await idle()
        precondition(m.signedIn && !m.needsCode && !m.showLogin && m.password.isEmpty && m.code.isEmpty, "success must clear secrets")
        m.query = "Example"; m.search(); try await idle()
        precondition(m.apps.count == 1 && m.apps[0].id == 123)
        for platform in DownloadPlatform.allCases {
            m.downloadPlatform = platform
            if platform != .iOS { precondition(m.apps.isEmpty && !m.searched, "platform changes must clear stale results") }
            m.search(); try await idle()
            precondition(m.apps[0].platform == platform && m.apps[0].version == platform.rawValue, "search must use the selected platform")
            let result = m.apps[0]
            try await m.downloadAndProcess(result, decryptAfterDownload: false)
            precondition(m.ipa!.deletingLastPathComponent().standardizedFileURL.path == m.downloadDirectory.standardizedFileURL.path, "downloads must use the download folder")
            let zip = try await runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", m.ipa!.path, "Payload/Example.app/Info.plist"])
            let metadata = try PropertyListSerialization.propertyList(from: zip.data, format: nil) as! [String: Any]
            precondition(metadata["TestPlatform"] as? String == platform.rawValue, "download must use the result's platform")
        }
        m.downloadPlatform = .iOS
        precondition(!m.events.joined().contains("test-secret") && !m.events.joined().contains("123456"), "activity must not expose credentials")
        let valid = root.appendingPathComponent("valid.bin")
        let originalIPA = root.appendingPathComponent("example.ipa")
        try EnrollmentModelFile.validate(valid)
        for invalid in [originalIPA, root.appendingPathComponent("bad-tables.bin")] {
            do { try await m.importModelFile(invalid); preconditionFailure("bad model must be rejected") } catch { }
            precondition(m.modelURL == nil, "failed import must not activate a model")
        }
        defaults.set(originalIPA.path, forKey: "modelPath")
        let migrated = AppModel(defaults: defaults, support: work.appendingPathComponent("Migration"), applicationDirectories: [])
        precondition(migrated.modelURL == nil && defaults.string(forKey: "modelPath") == nil)
        precondition(FileManager.default.fileExists(atPath: originalIPA.path), "migration must not delete the IPA")
        try await m.importModelFile(valid)
        precondition(m.modelURL != nil)
        let record: [String: Any] = ["id": 123, "name": "Example", "bundleID": "test.example", "version": "1"]
        let targetApp = StoreApp(record)!
        let unowned = StoreApp(["id": 998, "name": "Unowned", "bundleID": "test.unowned"])!
        do { try await m.downloadAndProcess(unowned, decryptAfterDownload: true); preconditionFailure("unowned app should fail before decryption") }
        catch { precondition(error.localizedDescription.contains("choose Get") && m.licenseURL?.absoluteString == "https://apps.apple.com/app/id998") }
        try await m.downloadAndProcess(targetApp, decryptAfterDownload: true)
        precondition(m.lastOutput?.lastPathComponent.hasSuffix("decrypted.ipa") == true)
        precondition(m.lastOutput!.deletingLastPathComponent().standardizedFileURL.path == m.outputDirectory.standardizedFileURL.path, "decryption must use its chosen output folder")
        precondition(m.pendingDecryption == nil && m.section == .decrypt)
        let decrypted = m.lastOutput!
        precondition(FileManager.default.fileExists(atPath: m.ipa!.path), "encrypted input must be kept")
        m.decrypt(); try await idle()
        precondition(m.lastOutput != decrypted, "one-click retry must use a new output path without a save dialog")
        precondition(FileManager.default.fileExists(atPath: decrypted.path), "repeat decryption must preserve earlier output")
        try await m.downloadAndProcess(targetApp, decryptAfterDownload: false)
        precondition(m.lastOutput == m.ipa, "download-only must not decrypt")
        m.modelURL = originalIPA // Simulate an invalid legacy selection still in memory.
        try await m.downloadAndProcess(targetApp, decryptAfterDownload: true)
        let waiting = m.pendingDecryption!
        precondition(m.modelURL == nil && m.section == .setup && m.lastOutput == waiting.input)
        precondition(collections == 0, "missing installed app must pause without attempting collection")
        m.installedApp = root.appendingPathComponent("Installed/Seed.app")
        m.recover(); try await idle()
        precondition(m.errorText == nil && m.pendingDecryption == nil && collections == 1)
        precondition(m.lastOutput == waiting.output, "setup must resume original target, not decrypt the seed instead")
        let seedID = try await m.ipaBundleID(m.setupIPA!)
        precondition(seedID == "test.seed", "recovery should download matching seed automatically")
        let failureApp = StoreApp(["id": 999, "name": "Failure", "bundleID": "test.failure"])!
        do { try await m.downloadAndProcess(failureApp, decryptAfterDownload: true); preconditionFailure("engine failure must propagate") } catch { }
        precondition(m.lastOutput == m.ipa && FileManager.default.fileExists(atPath: m.ipa!.path), "failure must preserve encrypted download")
        m.cancelPendingDecryption(); precondition(m.pendingDecryption == nil)
        m.rememberModel(root.appendingPathComponent("mismatch.bin"))
        try await m.downloadAndProcess(targetApp, decryptAfterDownload: true)
        precondition(m.modelURL == nil && m.pendingDecryption != nil && m.section == .setup, "mismatched enrollment must offer recovery")
        let autoModel = AppModel(defaults: UserDefaults(suiteName: domain + ".auto")!, support: work.appendingPathComponent("AutomaticSupport"), applicationDirectories: [root.appendingPathComponent("Automatic")], collectOverride: collect)
        autoModel.outputDirectory = work.appendingPathComponent("AutomaticDownloads")
        let automaticOutput = try autoModel.nextOutput(stem: "result", extension: "ipa")
        try await autoModel.processDecryption(DecryptionRequest(input: originalIPA, output: automaticOutput))
        precondition(autoModel.pendingDecryption == nil && autoModel.modelURL != nil && collections == 2)
        m.signOut(); try await idle(); precondition(!m.signedIn && m.apps.isEmpty)
        print("PASS: free download/decrypt workflows without payment authorization, JSON search parsing, literal shell quoting, large output, cancellation, 2FA pause/retry/success, secret clearing, iOS/iPadOS/tvOS search and download routing, separate download/output folders, invalid model rejection/migration, one-click decryption, download-only, automatic setup/resume, enrollment mismatch, input preservation and sign-out (mock helpers).")
    }
}
