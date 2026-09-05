import XCTest
@testable import DirectorCore

/// Independent contracts for structured session-to-project association.
final class ProjectAssociationTests: XCTestCase {
    private func directory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-project-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSession(_ id: String, cwd: String, to url: URL) throws {
        let line = #"{"type":"session_meta","timestamp":"2026-08-28T01:00:00Z","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"#
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func configuration(projectRoots: [ScanRoot], active: URL) -> IndexingCoordinator.Configuration {
        IndexingCoordinator.Configuration(scanRoots: projectRoots, activeSessionRoots: [active], archivedSessionRoot: nil)
    }

    func testNestedProjectUsesLongestStructuredCWDMatch() async throws {
        let outer = try directory("outer")
        let inner = outer.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let active = try directory("active")
        try writeSession("session:nested", cwd: inner.appendingPathComponent("src").path, to: active.appendingPathComponent("nested.jsonl"))
        let store = try DatabaseStore(url: try directory("store").appendingPathComponent("index.sqlite"))
        let roots = [
            ScanRoot(id: "project:outer", url: outer, scope: .project, kind: .projects),
            ScanRoot(id: "project:inner", url: inner, scope: .project, kind: .projects)
        ]
        _ = try await IndexingCoordinator(store: store).run(configuration: configuration(projectRoots: roots, active: active))
        let sessions = try await store.fetchAllSessions()
        XCTAssertEqual(sessions.first?.projectID, "project:inner")
    }

    func testSiblingNamePrefixDoesNotAssociateAndUnknownRemainsNil() async throws {
        let base = try directory("boundary")
        let project = base.appendingPathComponent("app", isDirectory: true)
        let sibling = base.appendingPathComponent("app-archive", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let active = try directory("active")
        try writeSession("session:sibling", cwd: sibling.path, to: active.appendingPathComponent("sibling.jsonl"))
        try writeSession("session:unknown", cwd: "/tmp/not-registered", to: active.appendingPathComponent("unknown.jsonl"))
        let store = try DatabaseStore(url: try directory("store").appendingPathComponent("index.sqlite"))
        let roots = [ScanRoot(id: "project:app", url: project, scope: .project, kind: .projects)]
        _ = try await IndexingCoordinator(store: store).run(configuration: configuration(projectRoots: roots, active: active))
        let sessions = try await store.fetchAllSessions()
        XCTAssertNil(sessions.first { $0.id == "session:sibling" }?.projectID)
        XCTAssertNil(sessions.first { $0.id == "session:unknown" }?.projectID)
    }

    func testAppendRetainsExistingProjectAssociation() async throws {
        let project = try directory("append")
        let active = try directory("active")
        let file = active.appendingPathComponent("append.jsonl")
        try writeSession("session:append", cwd: project.path, to: file)
        let store = try DatabaseStore(url: try directory("store").appendingPathComponent("index.sqlite"))
        let roots = [ScanRoot(id: "project:append", url: project, scope: .project, kind: .projects)]
        let coordinator = IndexingCoordinator(store: store)
        let config = configuration(projectRoots: roots, active: active)
        _ = try await coordinator.run(configuration: config)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n".utf8))
        try handle.close()
        _ = try await coordinator.run(configuration: config)
        let sessions = try await store.fetchAllSessions()
        XCTAssertEqual(sessions.first?.projectID, "project:append")
    }
}
