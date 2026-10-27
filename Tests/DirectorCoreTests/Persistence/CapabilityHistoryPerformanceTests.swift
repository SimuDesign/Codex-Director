import Darwin
import XCTest
@testable import DirectorCore

final class CapabilityHistoryPerformanceTests: XCTestCase {
    private final class IOProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var mainThreadSamples: [Bool] = []

        func record() {
            lock.lock()
            mainThreadSamples.append(Thread.isMainThread)
            lock.unlock()
        }

        var observedMainThreadIO: Bool {
            lock.lock(); defer { lock.unlock() }
            return mainThreadSamples.contains(true)
        }
    }

    func testTwoThousandCapabilitiesTwentyThousandEventsStayWithinFileAndMemoryBudget() async throws {
        let residentBefore = residentBytes()
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let state = makeState(reference: reference)
        XCTAssertEqual(state.baselines.count, 2_000)
        XCTAssertEqual(state.events.count, 20_000)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(state)
        XCTAssertLessThanOrEqual(encoded.count, CapabilityHistoryStore.defaultMaximumBytes)
        XCTAssertGreaterThan(encoded.count, 1_000_000, "fixture must exercise a material persisted document")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-performance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private", isDirectory: true)
        let historyURL = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try encoded.write(to: historyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)

        let probe = IOProbe()
        let store = try CapabilityHistoryStore.faultInjecting(
            url: historyURL,
            lockTimeout: 0,
            faultInjection: .init { phase in
                if phase == .beforeTemporaryWrite { probe.record() }
            }
        )
        let clock = ContinuousClock()
        let coldStarted = clock.now
        let status = await store.status()
        let coldReadMS = milliseconds(coldStarted.duration(to: clock.now))
        XCTAssertEqual(status.baselineCount, 2_000)
        XCTAssertEqual(status.eventCount, 20_000)

        let warmStarted = clock.now
        let page = try await store.page(.init(limit: 200))
        let warmPageMS = milliseconds(warmStarted.duration(to: clock.now))
        XCTAssertEqual(page.events.count, 200)

        let observations = state.baselines.map { baseline in
            CapabilityHistoryObservation(
                resourceID: baseline.resourceID,
                sourceRootID: baseline.sourceRootID,
                name: baseline.name,
                kind: baseline.resourceKind,
                scope: baseline.scope,
                projectID: baseline.projectID,
                documents: Set(baseline.documents),
                signature: baseline.signature,
                documentSignatures: baseline.documentSignatures,
                observedAt: reference.addingTimeInterval(11)
            )
        }
        let updateStarted = clock.now
        let permit = try await store.issueWritePermit()
        let result = try await store.commit(.init(
            observedAt: reference.addingTimeInterval(11),
            scopes: [.init(
                rootID: "global-skills",
                scope: .global,
                rootKind: .skills,
                coverage: .complete
            )],
            observations: observations
        ), permit: permit)
        let atomicUpdateMS = milliseconds(updateStarted.duration(to: clock.now))
        XCTAssertTrue(result.newEvents.isEmpty)
        XCTAssertFalse(probe.observedMainThreadIO, "history persistence must not execute on the main thread")

        let persistedBytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: historyURL.path)[.size] as? NSNumber)?.intValue
        )
        XCTAssertLessThanOrEqual(persistedBytes, CapabilityHistoryStore.defaultMaximumBytes)
        let residentAfter = residentBytes()
        let metrics: [String: Any] = [
            "fixtureCapabilities": 2_000,
            "fixtureEvents": 20_000,
            "persistedBytes": persistedBytes,
            "coldReadMilliseconds": coldReadMS,
            "warmPageMilliseconds": warmPageMS,
            "atomicUpdateMilliseconds": atomicUpdateMS,
            "testProcessResidentBeforeBytes": residentBefore,
            "testProcessResidentAfterBytes": residentAfter,
            "testProcessResidentDeltaBytes": Int64(residentAfter) - Int64(residentBefore),
            "rssScope": "swift-test process; not Codex Director.app",
        ]
        let metricsData = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("HISTORY_PERF \(String(decoding: metricsData, as: UTF8.self))")
    }

    private func makeState(reference: Date) -> CapabilityHistoryStateV1 {
        let signature = String(repeating: "a", count: 64)
        let documentSignature = CapabilityTrackedDocumentSignature(
            document: .skillManifest,
            sha256: signature
        )
        var baselines: [CapabilityHistoryBaseline] = []
        var events: [CapabilityChangeEvent] = []
        baselines.reserveCapacity(2_000)
        events.reserveCapacity(20_000)
        var sequence: Int64 = 1
        for resourceIndex in 0..<2_000 {
            let resourceID = String(format: "skill:perf:%04d", resourceIndex)
            let name = String(format: "Performance Skill %04d", resourceIndex)
            baselines.append(CapabilityHistoryBaseline(
                resourceID: resourceID,
                sourceRootID: "global-skills",
                name: name,
                resourceKind: .skill,
                scope: .global,
                projectID: nil,
                documents: [.skillManifest],
                signature: signature,
                documentSignatures: [documentSignature],
                signatureAlgorithm: CapabilityHistoryObservation.signatureAlgorithm,
                presence: .present,
                lastConfirmedAt: reference.addingTimeInterval(10),
                missingSince: nil
            ))
            for eventIndex in 0..<10 {
                let observedAt = reference.addingTimeInterval(Double(eventIndex))
                events.append(CapabilityChangeEvent(
                    id: "history-501-\(sequence)",
                    resourceID: resourceID,
                    name: name,
                    resourceKind: .skill,
                    scope: .global,
                    projectID: nil,
                    kind: .modified,
                    changedDocuments: [.skillManifest],
                    changedDocumentsAreExact: true,
                    observedAt: observedAt,
                    previousConfirmedAt: observedAt.addingTimeInterval(-1),
                    sequence: sequence,
                    retentionObservedAt: observedAt
                ))
                sequence += 1
            }
        }
        return CapabilityHistoryStateV1(
            epoch: 501,
            revision: 1,
            nextSequence: sequence,
            retentionAnchorAt: reference.addingTimeInterval(10),
            latestScanCoverage: .complete,
            scopes: [.init(
                rootID: "global-skills",
                scope: .global,
                rootKind: ScanRootKind.skills.rawValue,
                initializedAt: reference,
                lastCompleteAt: reference.addingTimeInterval(10)
            )],
            baselines: baselines,
            events: events
        )
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
