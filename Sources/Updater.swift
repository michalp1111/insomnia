import AppKit
import Security

/// Asks GitHub once a day for a newer release and installs it in place: downloads the zip, makes sure it
/// holds a valid Insomnia signed like this copy, swaps the app and relaunches. Anything unexpected sends
/// the user to the release page instead.
@MainActor
final class Updater {
    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }

        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }

    /// The repository's numeric ID survives renames, so nobody can step into an old name and serve an update.
    private static let latest = URL(string: "https://api.github.com/repositories/1414741619/releases/latest")!

    var onChange: () -> Void = {}
    private(set) var version: String?
    private(set) var isInstalling = false
    private var release: Release?
    private var timer: Timer?

    init() {
        Task { await check() }
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.check() }
            }
        }
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() async {
        guard !isInstalling, let (data, _) = try? await URLSession.shared.data(from: Self.latest),
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return }
        let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let isNewer = latest.compare(current, options: .numeric) == .orderedDescending
        (self.release, version) = isNewer ? (release, latest) : (nil, nil)
        onChange()
        #if DEBUG
        if isNewer, ProcessInfo.processInfo.environment["INSOMNIA_UPDATE_NOW"] == "1" { await install() }
        #endif
    }

    func install() async {
        guard let release, let version, !isInstalling else { return }
        isInstalling = true
        onChange()
        do {
            guard let asset = release.assets.first(where: { $0.name == "Insomnia.zip" }) else { throw CocoaError(.fileNoSuchFile) }
            let (zip, _) = try await URLSession.shared.download(from: asset.browser_download_url)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Insomnia \(version)")
            try? FileManager.default.removeItem(at: folder)
            try await run("/usr/bin/ditto", "-x", "-k", zip.path, folder.path)
            let app = folder.appendingPathComponent("Insomnia.app")
            guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
                  Self.isSignedLikeThisCopy(app) else { throw CocoaError(.fileReadCorruptFile) }
            _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
            relaunch()
        } catch {
            // A copy macOS keeps read-only, like one opened straight from Downloads, can still be updated by hand.
            isInstalling = false
            onChange()
            NSWorkspace.shared.open(release.html_url)
        }
    }

    /// A valid signature, and once Insomnia is signed with a Developer ID, the same developer as this copy.
    private static func isSignedLikeThisCopy(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        if let team = teamIdentifier {
            SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement)
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static var teamIdentifier: String? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Opens the new copy once this one has quit and let go of the Mac.
    private func relaunch() {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/sh")
        opener.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                            Bundle.main.bundlePath]
        try? opener.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ arguments: String...) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadCorruptFile))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}
