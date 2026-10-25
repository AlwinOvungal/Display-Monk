import AppKit
import CryptoKit
import DisplayKit
import DisplayMonkCore
import Foundation

/// Checks GitHub for a newer release and installs it in place. Files downloaded by the app
/// itself carry no quarantine flag, so the new version opens without a Gatekeeper prompt.
///
/// Battery: there is no polling timer. Automatic checks run at most every 12 hours, shortly
/// after launch and from a daily background activity that macOS schedules when it's cheap.
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// The newest release found, kept while it downloads and after a failed install.
    private(set) var update: AvailableUpdate?
    private var scheduler: NSBackgroundActivityScheduler?
    private var downloadSession: URLSession?

    private static let lastCheckKey = "lastUpdateCheck"
    private static let automaticInterval: TimeInterval = 12 * 60 * 60

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Updating only makes sense for the bundled app, not for `swift run`.
    private var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    // MARK: Checking

    /// Starts or stops the automatic checks to match the preference.
    func scheduleChecks() {
        scheduler?.invalidate()
        scheduler = nil
        guard isBundled, Preferences.autoUpdateCheck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.check(manual: false)
        }
        let scheduler = NSBackgroundActivityScheduler(identifier: "app.displaymonk.DisplayMonk.updateCheck")
        scheduler.repeats = true
        scheduler.interval = 24 * 60 * 60
        scheduler.tolerance = 60 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            DispatchQueue.main.async { self?.check(manual: false) }
            completion(.finished)
        }
        self.scheduler = scheduler
    }

    func check(manual: Bool) {
        guard !isBusy else { return }
        guard isBundled else {
            if manual { status = .failed("Updates work in the installed app only.") }
            return
        }
        if !manual {
            guard Preferences.autoUpdateCheck else { return }
            if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
               Date().timeIntervalSince(last) < Self.automaticInterval { return }
        }
        if manual { status = .checking }
        var request = URLRequest(url: UpdateCheck.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DisplayMonk/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let release = data.flatMap { try? JSONDecoder().decode(ReleaseInfo.self, from: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                guard ok, let release else {
                    if manual { self.status = .failed("Couldn't reach GitHub. Try again later.") }
                    return
                }
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                if let update = UpdateCheck.update(from: release, currentVersion: self.currentVersion) {
                    self.update = update
                    self.status = .available(update)
                } else {
                    self.update = nil
                    self.status = manual ? .upToDate : .idle
                    if manual { self.clearUpToDateSoon() }
                }
            }
        }.resume()
    }

    private func clearUpToDateSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.status == .upToDate { self?.status = .idle }
        }
    }

    /// Hides a failure message; an update that was found stays on offer.
    func dismiss() {
        guard !isBusy else { return }
        status = update.map(Status.available) ?? .idle
    }

    func openReleasePage() {
        NSWorkspace.shared.open(update?.notesURL ?? UpdateCheck.releasesPage)
    }

    // MARK: Installing

    func install() {
        guard let update, !isBusy else { return }
        status = .downloading(0)
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        downloadSession = session
        session.downloadTask(with: update.downloadURL).resume()
        session.finishTasksAndInvalidate()
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            self.downloadSession = nil
            self.status = .failed(message)
        }
    }

    /// Where the new version goes: over the running copy, unless that is on a disk image or
    /// translocated by Gatekeeper, in which case it goes to /Applications.
    private var destination: URL {
        let current = Bundle.main.bundleURL.standardizedFileURL
        if current.path.contains("/AppTranslocation/") || current.path.hasPrefix("/Volumes/") {
            return URL(fileURLWithPath: "/Applications").appendingPathComponent(current.lastPathComponent)
        }
        return current
    }

    /// Runs on the download session's queue. Checks the zip and unpacks the app next to the
    /// destination, so the final move stays on one volume.
    private func prepare(_ zip: URL, for update: AvailableUpdate) throws -> URL {
        if let expected = update.sha256 {
            let data = try Data(contentsOf: zip, options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw UpdateError("The download didn't match its checksum.") }
        }
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        try Self.run("/usr/bin/ditto", "-x", "-k", zip.path, staging.path)
        guard let app = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw UpdateError("The download doesn't contain the app.") }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let version = (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
              version == update.version
        else { throw UpdateError("The download isn't the expected version of Display Monk.") }
        try Self.run("/usr/bin/codesign", "--verify", "--deep", "--strict", app.path)
        try? Self.run("/usr/bin/xattr", "-dr", "com.apple.quarantine", app.path)
        return app
    }

    /// Main thread. Swaps the new app in (the running copy keeps working from memory), then
    /// quits and relaunches from the new copy.
    private func finish(with app: URL) {
        status = .installing
        let destination = destination
        do {
            if FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path),
               !FileManager.default.fileExists(atPath: destination.path) || FileManager.default.isWritableFile(atPath: destination.path) {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: app)
                } else {
                    try FileManager.default.moveItem(at: app, to: destination)
                }
            } else {
                // Installed by an administrator: ask for the password to replace it.
                // The copy is made beside the old app first, so a failure never leaves neither.
                let new = Privileged.quote(app.path)
                let old = Privileged.quote(destination.path)
                let staged = Privileged.quote(destination.path + ".update")
                try Privileged.run("rm -rf \(staged) && /usr/bin/ditto \(new) \(staged) && rm -rf \(old) && mv \(staged) \(old) && (/usr/bin/xattr -dr com.apple.quarantine \(old) || true)")
            }
        } catch Privileged.Failure.cancelled {
            status = update.map(Status.available) ?? .idle
            return
        } catch {
            status = .failed("Couldn't replace the app: \(error.localizedDescription)")
            return
        }
        relaunch(destination)
    }

    private func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"", String(getpid()), app.path]
        do {
            try process.run()
        } catch {
            status = .failed("Installed. Quit and reopen Display Monk to finish.")
            return
        }
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed while checking the download.")
        }
    }
}

extension Updater: URLSessionDownloadDelegate {
    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0 else { return }
        let progress = Double(written) / Double(expected)
        DispatchQueue.main.async {
            if case .downloading = self.status { self.status = .downloading(progress) }
        }
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let update else { return }
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            fail("The download failed. Try again later.")
            return
        }
        do {
            let app = try prepare(location, for: update)
            DispatchQueue.main.async {
                self.downloadSession = nil
                self.finish(with: app)
            }
        } catch {
            fail((error as? UpdateError)?.message ?? "The download couldn't be checked.")
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { fail("The download failed. Try again later.") }
    }
}

private struct UpdateError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
