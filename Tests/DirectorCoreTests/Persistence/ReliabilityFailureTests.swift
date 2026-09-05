import XCTest
@testable import DirectorCore

final class ReliabilityFailureTests: XCTestCase {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-reliability-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func snapshot(identity: PresentationIdentity, generatedAt: Date) -> PresentationSnapshot {
        PresentationSnapshot(
            identity: identity,
            classificationRevision: "reliability-test",
            window: CapabilityQueryWindow(
                start: Date(timeIntervalSince1970: 1_800_000_000),
                end: Date(timeIntervalSince1970: 1_800_000_600),
                timeZone: .gmt
            ),
            generatedAt: generatedAt,
            home: PresentationHomeSummary(
                customAgents: Int(generatedAt.timeIntervalSince1970),
                customAgentsGlobal: 0,
                customAgentsProject: 0,
                customSkills: 0,
                customSkillsGlobal: 0,
                customSkillsProject: 0,
                installedSkills: 0,
                installedSkillsIndependent: 0,
                installedSkillsPluginProvided: 0,
                installedPlugins: 0,
                enabledPlugins: 0
            )
        )
    }

    func testCorruptDatabaseFailsClosedWithoutReplacingSourceBytes() throws {
        let root = try temporaryRoot("corrupt-database")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("derived.sqlite")
        let original = Data("synthetic-not-a-sqlite-database".utf8)
        try original.write(to: databaseURL)

        XCTAssertThrowsError(try DatabaseStore(url: databaseURL))
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
    }

    func testUnreadableDatabaseFailsClosed() throws {
        let root = try temporaryRoot("unreadable-database")
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("derived.sqlite")
        try Data("synthetic".utf8).write(to: databaseURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: databaseURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path) }

        XCTAssertThrowsError(try DatabaseStore(url: databaseURL, readOnly: true))
    }

    func testSQLiteFullFailureLeavesConnectionUsable() throws {
        let root = try temporaryRoot("sqlite-full")
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = try XCTUnwrap(SQLiteConnection(url: root.appendingPathComponent("limited.sqlite")))
        XCTAssertTrue(connection.exec("PRAGMA page_size = 512"))
        XCTAssertTrue(connection.exec("PRAGMA max_page_count = 4"))
        XCTAssertTrue(connection.exec("CREATE TABLE payload (value BLOB NOT NULL)"))

        let statement = try connection.prepare("INSERT INTO payload(value) VALUES (zeroblob(65536))")
        XCTAssertThrowsError(try statement.step())
        XCTAssertTrue(connection.exec("SELECT 1"))
    }

    func testAtomicCacheWriteFailureRetainsLastValidSnapshotAndCleansTemporaryFile() async throws {
        let root = try temporaryRoot("cache-write")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let cacheURL = root.appendingPathComponent("presentation.json")
        let store = PresentationSnapshotStore(url: cacheURL)
        let identity = PresentationIdentity(databaseEpoch: "reliability-epoch", dataGeneration: 1)
        let permit = await store.activate(identity: identity)
        let original = snapshot(identity: identity, generatedAt: Date(timeIntervalSince1970: 1))
        try await store.write(original, permit: permit)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let replacement = snapshot(identity: identity, generatedAt: Date(timeIntervalSince1970: 2))
        do {
            try await store.write(replacement, permit: permit)
            XCTFail("a write into a non-writable cache directory unexpectedly succeeded")
        } catch PresentationSnapshotStore.StoreError.atomicWriteFailed {
            // Expected.
        }

        let retained = try await store.read()
        XCTAssertEqual(retained, original)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, [cacheURL.lastPathComponent])
    }
}
