import Foundation

/// A dotted release version such as "0.1.5" or "v0.2.0-beta.1", compared numerically, so
/// 0.1.10 is newer than 0.1.9. Trailing zeros don't matter ("0.2" equals "0.2.0"), and a
/// pre-release sorts before the plain version.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]
    public let prerelease: String?
    /// The version as written, without a leading "v".
    public let description: String

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        var components = numbers.compactMap { $0 }
        while components.count > 1, components.last == 0 { components.removeLast() }
        self.components = components
        prerelease = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        description = text
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool {
        a.components == b.components && a.prerelease == b.prerelease
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0 ..< max(a.components.count, b.components.count) {
            let x = index < a.components.count ? a.components[index] : 0
            let y = index < b.components.count ? b.components[index] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        case (_?, nil): return true
        default: return false
        }
    }
}

/// The parts of GitHub's "latest release" response the updater uses.
public struct ReleaseInfo: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browserDownloadURL: String
        /// "sha256:<hex>", supplied by GitHub for release assets.
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let htmlURL: String?
    public let draft: Bool?
    public let prerelease: Bool?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// A newer release the app can install.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: AppVersion
    public let downloadURL: URL
    /// Lowercase hex SHA-256 of the zip, when GitHub supplied one.
    public let sha256: String?
    public let notesURL: URL?
}

public enum UpdateCheck {
    public static let repository = "AlwinOvungal/Display-Monk"
    public static let assetName = "DisplayMonk.zip"
    public static var latestReleaseAPI: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }
    public static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases/latest")! }

    /// The update to offer, or nil when `release` isn't newer than `currentVersion`, isn't a
    /// final release, or has no zip downloaded from this repository's releases.
    public static func update(from release: ReleaseInfo, currentVersion: String) -> AvailableUpdate? {
        guard release.draft != true, release.prerelease != true,
              let latest = AppVersion(release.tagName), let current = AppVersion(currentVersion), latest > current,
              let asset = release.assets.first(where: { $0.name == assetName }),
              asset.browserDownloadURL.hasPrefix("https://github.com/\(repository)/releases/download/"),
              let url = URL(string: asset.browserDownloadURL)
        else { return nil }
        var sha256: String?
        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            sha256 = String(digest.dropFirst("sha256:".count)).lowercased()
        }
        return AvailableUpdate(version: latest, downloadURL: url, sha256: sha256, notesURL: release.htmlURL.flatMap(URL.init(string:)))
    }
}
