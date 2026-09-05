import XCTest
@testable import DirectorCore

final class PresentationDirectoryTests: XCTestCase {
    func testReadOnlyDirectorySnapshotIsCoherentAndCancellationReusable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let writer = try DatabaseStore(url: url)
        try await writer.replaceResourceInventory(resources: [], projects: [], provenance: [], relations: [])
        let session = TaskSummary(id: "session:directory", projectID: nil, startedAt: Date(), endedAt: Date(), status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "source", title: nil)
        try await writer.replaceSession(PersistedSessionBatch(session: session, calls: [], tokenSnapshots: [], quotaSnapshots: [], findings: []))
        let identity = try await writer.presentationIdentity()
        let reader = try DatabaseStore(url: url, readOnly: true)
        let token = SQLiteCancellationToken(); token.cancel()
        do { _ = try await reader.fetchPresentationDirectory(cancellation: token); XCTFail("cancelled directory read unexpectedly succeeded") } catch { }
        let snapshot = try await reader.fetchPresentationDirectory()
        XCTAssertEqual(snapshot.metadata.identity, identity)
        XCTAssertTrue(snapshot.resources.isEmpty)
        XCTAssertTrue(snapshot.relations.isEmpty)
        XCTAssertTrue(snapshot.projects.isEmpty)
        XCTAssertTrue(snapshot.provenance.isEmpty)
        XCTAssertEqual(snapshot.indexedSessionCount, 1)
        let window = CapabilityQueryWindow(start: Date(timeIntervalSince1970: 0), end: Date(), timeZone: .gmt)
        let token2 = SQLiteCancellationToken(); token2.cancel()
        do { _ = try await reader.fetchStartupPresentation(window: window, cancellation: token2); XCTFail("cancelled startup read unexpectedly succeeded") } catch { }
        let startup = try await reader.fetchStartupPresentation(window: window)
        XCTAssertEqual(startup.directory.metadata.identity, identity)
        XCTAssertEqual(startup.quota.identity, identity)
        XCTAssertEqual(startup.quota.window, window)
        XCTAssertTrue(startup.recentUsage.isEmpty)
    }

    func testRelationInsertAdvancesGenerationAndInvalidInputDoesNot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let writer = try DatabaseStore(url: url)
        let before = try await writer.presentationIdentity()
        let relation = ResourceRelation(sourceResourceID: "plugin:p", targetResourceID: "skill:s", relationKind: "contains", confidence: .exact, evidenceSummary: nil)
        try await writer.insertRelations([relation])
        let after = try await writer.presentationIdentity()
        XCTAssertGreaterThan(after.dataGeneration, before.dataGeneration)
        let reader = try DatabaseStore(url: url, readOnly: true)
        let directorySnapshot = try await reader.fetchPresentationDirectory()
        XCTAssertEqual(directorySnapshot.metadata.identity, after)
        XCTAssertEqual(directorySnapshot.relations, [relation])
        let invalid = ResourceRelation(sourceResourceID: "bad", targetResourceID: "bad", relationKind: "contains", confidence: .exact, evidenceSummary: "/Users/example/private")
        do { try await writer.insertRelations([invalid]); XCTFail("invalid relation unexpectedly persisted") } catch { }
        let unchanged = try await writer.presentationIdentity()
        XCTAssertEqual(unchanged, after)
    }

    func testSuccessfulSourceIndexMetadataIsAtomicAndDoesNotChangeGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let writer = try DatabaseStore(url: url)
        let old = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        try await writer.markSourceCheckCompleted(at: old)
        try await writer.markIndexCompleted(at: old)
        let before = try await writer.presentationIdentity()
        try await writer.markSuccessfulSourceIndex(at: newer)
        let after = try await writer.presentationIdentity()
        let metadata = try await writer.fetchPresentationIndexMetadata()
        XCTAssertEqual(after, before)
        XCTAssertEqual(metadata.lastSourceCheckAt, newer)
        XCTAssertEqual(metadata.lastIndexCompletedAt, newer)

        let reader = try DatabaseStore(url: url, readOnly: true)
        do { try await reader.markSuccessfulSourceIndex(at: Date(timeIntervalSince1970: 300)); XCTFail("readonly metadata write unexpectedly succeeded") } catch { }
        let preserved = try await reader.fetchPresentationIndexMetadata()
        XCTAssertEqual(preserved.identity, before)
        XCTAssertEqual(preserved.lastSourceCheckAt, newer)
        XCTAssertEqual(preserved.lastIndexCompletedAt, newer)
    }

    func testStartupPresentationIncludesBoundedResourceUsageAndQuota() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("startup-positive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let writer = try DatabaseStore(url: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let resource = CapabilityResource(id: "skill:positive", name: "Positive", kind: .skill, status: .idle, scope: .global, projectID: nil, confidence: .exact, summary: nil, sourceRootID: "synthetic", relativeSourcePath: "skill.md", sourcePathHash: nil, lastSeenAt: date, ownership: .userOwned, origin: .local)
        try await writer.replaceResourceInventory(resources: [resource], projects: [], provenance: [], relations: [])
        let session = TaskSummary(id: "session:positive", projectID: nil, startedAt: date, endedAt: date, status: .completed, coverage: .complete, parserVersion: "1", sourceFileID: "source", title: nil)
        let call = InvocationEvent(id: "call:positive", sessionID: session.id, parentCallID: nil, ordinal: 0, timestamp: date, actorName: nil, resourceID: resource.id, kind: .skill, status: .completed, durationMs: 1, confidence: .exact, errorCategory: nil)
        let quota = try QuotaSnapshot(id: "quota:positive", capturedAt: date, windowMinutes: 10_080, usedPercent: 25, resetsAt: date.addingTimeInterval(3600), limitID: "account", limitName: "Account", confidence: .exact)
        try await writer.replaceSession(PersistedSessionBatch(session: session, calls: [call], tokenSnapshots: [], quotaSnapshots: [quota], findings: []))
        let reader = try DatabaseStore(url: url, readOnly: true)
        let window = CapabilityQueryWindow(start: date.addingTimeInterval(-1), end: date.addingTimeInterval(1), timeZone: .gmt)
        let snapshot = try await reader.fetchStartupPresentation(window: window)
        XCTAssertEqual(snapshot.directory.resources.map(\.id), [resource.id])
        XCTAssertEqual(snapshot.recentUsage.first?.resourceID, resource.id)
        XCTAssertEqual(snapshot.recentUsage.first?.callCount, 1)
        XCTAssertEqual(snapshot.quota.window, window)
        XCTAssertEqual(snapshot.quota.sources.first?.current?.usedPercent, 25)
        XCTAssertEqual(snapshot.directory.metadata.identity, snapshot.quota.identity)
    }
}
