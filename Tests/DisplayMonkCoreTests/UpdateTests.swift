import Foundation
import XCTest
@testable import DisplayMonkCore

final class UpdateTests: XCTestCase {
    private func version(_ text: String) -> AppVersion {
        AppVersion(text)!
    }

    func testVersionsCompareNumerically() {
        XCTAssertGreaterThan(version("0.1.10"), version("0.1.9"))
        XCTAssertGreaterThan(version("0.2"), version("0.1.9"))
        XCTAssertGreaterThan(version("1.0.0"), version("0.9.9"))
        XCTAssertEqual(version("v0.1.5"), version("0.1.5"))
        XCTAssertEqual(version("0.2"), version("0.2.0"))
        XCTAssertLessThan(version("0.2.0-beta.1"), version("0.2.0"))
        XCTAssertLessThan(version("0.2.0-beta.2"), version("0.2.0-beta.10"))
        XCTAssertEqual(version("v0.1.5").description, "0.1.5")
    }

    func testRejectsMalformedVersions() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("0.1.x"))
        XCTAssertNil(AppVersion("0..1"))
    }

    private func release(tag: String, url: String = "https://github.com/AlwinOvungal/Display-Monk/releases/download/v0.1.6/DisplayMonk.zip", digest: String? = "sha256:ABC123", prerelease: Bool = false) throws -> ReleaseInfo {
        let digestJSON = digest.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"tag_name": "\(tag)", "html_url": "https://github.com/AlwinOvungal/Display-Monk/releases/tag/\(tag)",
         "draft": false, "prerelease": \(prerelease),
         "assets": [
           {"name": "DisplayMonk.dmg", "browser_download_url": "https://github.com/AlwinOvungal/Display-Monk/releases/download/\(tag)/DisplayMonk.dmg", "digest": null},
           {"name": "DisplayMonk.zip", "browser_download_url": "\(url)", "digest": \(digestJSON)}
         ]}
        """
        return try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
    }

    func testOffersNewerRelease() throws {
        let update = try XCTUnwrap(UpdateCheck.update(from: release(tag: "v0.1.6"), currentVersion: "0.1.5"))
        XCTAssertEqual(update.version, version("0.1.6"))
        XCTAssertEqual(update.downloadURL.lastPathComponent, "DisplayMonk.zip")
        XCTAssertEqual(update.sha256, "abc123")
        XCTAssertEqual(update.notesURL?.lastPathComponent, "v0.1.6")
    }

    func testIgnoresSameOrOlderRelease() throws {
        XCTAssertNil(UpdateCheck.update(from: try release(tag: "v0.1.5"), currentVersion: "0.1.5"))
        XCTAssertNil(UpdateCheck.update(from: try release(tag: "v0.1.4"), currentVersion: "0.1.5"))
    }

    func testIgnoresPrereleasesAndForeignDownloads() throws {
        XCTAssertNil(UpdateCheck.update(from: try release(tag: "v0.1.6", prerelease: true), currentVersion: "0.1.5"))
        XCTAssertNil(UpdateCheck.update(from: try release(tag: "v0.1.6", url: "https://example.com/DisplayMonk.zip"), currentVersion: "0.1.5"))
    }

    func testWorksWithoutDigest() throws {
        let update = try XCTUnwrap(UpdateCheck.update(from: release(tag: "v0.1.6", digest: nil), currentVersion: "0.1.5"))
        XCTAssertNil(update.sha256)
    }
}
