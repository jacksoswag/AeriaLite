import Foundation
import XCTest
@testable import aerialite

final class LibraryTests: XCTestCase {
    func testNonVideoResponseCannotBecomeDownload() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let errorPage = folder.appendingPathComponent("wallpaper.mp4")
        try Data("<html>not a video</html>".utf8).write(to: errorPage)

        let playable = await Library.isPlayableVideo(errorPage)
        XCTAssertFalse(playable)
    }

    func testInvalidSuccessfulResponseCannotReplaceExistingDownload() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entry = Entry(name: "Test Download", source: Source(link: "https://example.test/video"))
        let target = folder.appendingPathComponent(entry.storage).appendingPathExtension("mp4")
        try Data("known good placeholder".utf8).write(to: target)

        StubURLProtocol.statusCode = 200
        StubURLProtocol.body = Data("<html>upstream error</html>".utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let landed = await withCheckedContinuation { continuation in
            _ = Library.fetch(entry, into: folder, session: session, progress: { _ in },
                              done: { continuation.resume(returning: $0) })
        }

        XCTAssertNil(landed)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "known good placeholder")
    }

    func testEntryIdentityAndStorageSurviveRenameAndRoundTrip() throws {
        var entry = Entry(name: "Original Name", source: Source(link: "https://example.com/clip.mov"))
        let id = entry.id
        let storage = entry.storage
        entry.name = "Better Name"

        let decoded = try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.storage, storage)
        XCTAssertEqual(decoded.name, "Better Name")
    }

    func testRenamedEntryDoesNotClaimFileNamedAfterNewTitle() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var entry = Entry(name: "Original Name")
        entry.name = "Another Download"
        try Data("belongs elsewhere".utf8).write(
            to: folder.appendingPathComponent("Another-Download.mp4"))

        XCTAssertTrue(Library.variants(entry, in: folder).isEmpty)
    }

    func testLegacyEntryGainsStableIdentityAndStorage() throws {
        let data = Data(#"{"name":"Old Name","source":{"link":"https://example.com/clip.mov"}}"#.utf8)
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        XCTAssertEqual(entry.id, "https://example.com/clip.mov")
        XCTAssertEqual(entry.storage, "Old-Name")
    }

    func testLegacyBlankNameStillGetsUsableStorage() throws {
        let data = Data(#"{"name":"","source":{"link":"https://example.com/clip.mov"}}"#.utf8)
        let entry = try JSONDecoder().decode(Entry.self, from: data)
        XCTAssertEqual(entry.storage, "clip")
    }

    func testAtomicLandingReplacesOnlyAfterNewFileExists() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target.mp4")
        let source = folder.appendingPathComponent("source.mp4")
        try Data("old".utf8).write(to: target)
        try Data("new".utf8).write(to: source)

        XCTAssertTrue(Library.land(source, at: target))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        XCTAssertFalse(Library.land(folder.appendingPathComponent("missing"), at: target))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
    }

    func testCacheTrimCountsKeptFileAndPreservesIt() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try file("old", bytes: 10, in: folder, accessed: Date(timeIntervalSince1970: 1))
        let recent = try file("recent", bytes: 10, in: folder, accessed: Date(timeIntervalSince1970: 2))
        let current = try file("current", bytes: 10, in: folder, accessed: Date(timeIntervalSince1970: 3))
        var cache = Settings.Cache()
        cache.videos = 1
        cache.space = "100"

        Library.trimCache(cache, keeping: "current", in: folder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    func testCacheByteCapIncludesKeptFile() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try file("old", bytes: 20, in: folder, accessed: Date(timeIntervalSince1970: 1))
        let current = try file("current", bytes: 20, in: folder, accessed: Date(timeIntervalSince1970: 2))
        var cache = Settings.Cache()
        cache.videos = 10
        cache.space = "0.00003" // 30 bytes

        Library.trimCache(cache, keeping: "current", in: folder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
    }

    func testCacheTrimNeverDeletesInFlightStagingFile() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let committed = try file("committed", bytes: 20, in: folder,
                                 accessed: Date(timeIntervalSince1970: 1))
        let staging = folder.appendingPathComponent(".clip.aerialite.fetch.id.mp4")
        try Data(repeating: 1, count: 20).write(to: staging)
        var cache = Settings.Cache()
        cache.videos = 0
        cache.space = "0"

        Library.trimCache(cache, keeping: nil, in: folder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testFractionalMegabyteCacheLimitIsNotTruncated() {
        var cache = Settings.Cache()
        cache.space = "0.00003"
        XCTAssertEqual(cache.bytes, 30)
    }

    func testInterruptedStorageMigrationMergesNestedDirectoriesWithoutOverwrite() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("old", isDirectory: true)
        let destination = folder.appendingPathComponent("new", isDirectory: true)
        let oldWallpapers = source.appendingPathComponent("Wallpapers", isDirectory: true)
        let newWallpapers = destination.appendingPathComponent("Wallpapers", isDirectory: true)
        try FileManager.default.createDirectory(at: oldWallpapers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newWallpapers, withIntermediateDirectories: true)
        try Data("old collision".utf8).write(
            to: oldWallpapers.appendingPathComponent("existing.mp4"))
        try Data("new collision".utf8).write(
            to: newWallpapers.appendingPathComponent("existing.mp4"))
        try Data("recover me".utf8).write(
            to: oldWallpapers.appendingPathComponent("missing.mp4"))

        Paths.migrateContents(from: source, to: destination)

        XCTAssertEqual(try String(contentsOf: newWallpapers.appendingPathComponent("existing.mp4"),
                                  encoding: .utf8), "new collision")
        XCTAssertEqual(try String(contentsOf: newWallpapers.appendingPathComponent("missing.mp4"),
                                  encoding: .utf8), "recover me")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: oldWallpapers.appendingPathComponent("existing.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: oldWallpapers.appendingPathComponent("missing.mp4").path))
    }

    func testCatalogNamesStayShortAndAvoidFillerWords() {
        let cases = [
            CatalogNames.title(label: "West Africa to the Alps", shotID: "A001_C004_1207W5"),
            CatalogNames.title(label: "The Ganges", shotID: "ANN0110"),
            CatalogNames.title(label: "A very long label with many extra words", shotID: "unknown"),
        ]
        let filler: Set<String> = ["the", "and", "a", "of", "in"]
        for title in cases {
            let words = title.split(separator: " ").map { $0.lowercased() }
            XCTAssertTrue((2...4).contains(words.count), title)
            XCTAssertTrue(filler.isDisjoint(with: words), title)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aerialite-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func file(_ stem: String, bytes: Int, in folder: URL, accessed: Date) throws -> URL {
        let url = folder.appendingPathComponent(stem).appendingPathExtension("mp4")
        try Data(repeating: 1, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: accessed], ofItemAtPath: url.path)
        return url
    }
}

private final class StubURLProtocol: URLProtocol {
    static var statusCode = 200
    static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
