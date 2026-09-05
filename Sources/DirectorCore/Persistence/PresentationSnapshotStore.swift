import Foundation

public actor PresentationSnapshotStore {
    public enum StoreError: Error, Equatable, Sendable { case oversized, corrupt, unsupportedVersion, staleIdentity, atomicWriteFailed }
    public struct WritePermit: Sendable, Equatable { fileprivate let identity: PresentationIdentity; fileprivate let revision: Int64 }
    public let url: URL
    public let maxBytes: Int
    private var activeIdentity: PresentationIdentity?
    private var revokedIdentity: PresentationIdentity?
    private var revision: Int64 = 0
    public init(url: URL, maxBytes: Int = 2 * 1024 * 1024) { self.url = url; self.maxBytes = maxBytes }

    public func read(expectedIdentity: PresentationIdentity? = nil) throws -> PresentationSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.intValue <= maxBytes else { throw StoreError.oversized }
        let data: Data
        do { data = try Data(contentsOf: url, options: [.mappedIfSafe]) } catch { throw StoreError.corrupt }
        let snapshot: PresentationSnapshot
        do { snapshot = try JSONDecoder().decode(PresentationSnapshot.self, from: data) } catch { throw StoreError.corrupt }
        guard data.count <= maxBytes else { throw StoreError.oversized }
        try validate(snapshot)
        if let expectedIdentity, snapshot.identity != expectedIdentity { throw StoreError.staleIdentity }
        return snapshot
    }

    public func activate(identity: PresentationIdentity) -> WritePermit {
        revision += 1; activeIdentity = identity; revokedIdentity = nil
        return WritePermit(identity: identity, revision: revision)
    }

    public func invalidate() {
        revision += 1; revokedIdentity = activeIdentity; activeIdentity = nil
    }

    public func write(_ snapshot: PresentationSnapshot, permit: WritePermit) throws {
        guard permit.revision == revision, permit.identity == snapshot.identity,
              activeIdentity == permit.identity, revokedIdentity?.databaseEpoch != permit.identity.databaseEpoch else { throw StoreError.staleIdentity }
        try writeData(preservingScheduleIfNeeded(snapshot))
    }

    public func write(_ snapshot: PresentationSnapshot, expectedIdentity: PresentationIdentity? = nil, generation: Int64? = nil) throws {
        if let expectedIdentity, snapshot.identity != expectedIdentity { throw StoreError.staleIdentity }
        if let generation, snapshot.identity.dataGeneration != generation { throw StoreError.staleIdentity }
        if let activeIdentity, activeIdentity != snapshot.identity { throw StoreError.staleIdentity }
        if revokedIdentity?.databaseEpoch == snapshot.identity.databaseEpoch { throw StoreError.staleIdentity }
        if activeIdentity == nil {
            // A store reopened around an existing file must activate explicitly;
            // otherwise a late writer from the previous process could replace it.
            if FileManager.default.fileExists(atPath: url.path) { throw StoreError.staleIdentity }
            revision += 1; activeIdentity = snapshot.identity
        }
        try writeData(preservingScheduleIfNeeded(snapshot))
    }

    private func writeData(_ snapshot: PresentationSnapshot) throws {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot), data.count <= maxBytes else { throw StoreError.oversized }
        try validate(snapshot)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: url) }
        } catch { try? FileManager.default.removeItem(at: temporary); throw StoreError.atomicWriteFailed }
    }

    private func preservingScheduleIfNeeded(_ snapshot: PresentationSnapshot) -> PresentationSnapshot {
        let existing: PresentationSnapshot?
        do { existing = try read() } catch { return snapshot }
        guard let existing,
              existing.identity.databaseEpoch == snapshot.identity.databaseEpoch,
              let schedule = existing.refreshSchedule else { return snapshot }
        if let incoming = snapshot.refreshSchedule {
            guard schedule.revision > incoming.revision else { return snapshot }
        }
        return PresentationSnapshot(
            schemaVersion: snapshot.schemaVersion,
            identity: snapshot.identity,
            classificationRevision: snapshot.classificationRevision,
            window: snapshot.window,
            generatedAt: snapshot.generatedAt,
            lastSourceCheckAt: snapshot.lastSourceCheckAt,
            lastIndexCompletedAt: snapshot.lastIndexCompletedAt,
            statisticsThrough: snapshot.statisticsThrough,
            quota: snapshot.quota,
            home: snapshot.home,
            failureCount: snapshot.failureCount,
            nextRetryAt: snapshot.nextRetryAt,
            refreshSchedule: schedule
        )
    }

    private func validate(_ snapshot: PresentationSnapshot) throws {
        guard snapshot.schemaVersion == PresentationSnapshot.currentSchemaVersion else { throw StoreError.unsupportedVersion }
        guard !snapshot.identity.databaseEpoch.isEmpty, snapshot.identity.dataGeneration >= 0,
              snapshot.window.start <= snapshot.window.end,
              TimeZone(identifier: snapshot.window.timeZoneIdentifier) != nil else { throw StoreError.corrupt }
        if let quota = snapshot.quota {
            guard quota.identity == snapshot.identity, quota.window == snapshot.window,
                  quota.sources.allSatisfy({ $0.daily.count <= 7 }) else { throw StoreError.corrupt }
        }
        if let home = snapshot.home,
           !(1...PresentationHomeSummary.currentRankingCapacity).contains(home.rankingCapacity) ||
           home.customAgentsTop.count > home.rankingCapacity ||
           home.customSkillsTop.count > home.rankingCapacity ||
           home.installedSkillsTop.count > home.rankingCapacity { throw StoreError.corrupt }
    }

    public func merge(_ snapshot: PresentationSnapshot, expectedIdentity: PresentationIdentity? = nil, generation: Int64? = nil) throws {
        guard let existing = try read(), existing.identity == snapshot.identity else {
            try write(snapshot, expectedIdentity: expectedIdentity, generation: generation); return
        }
        guard existing.window == snapshot.window, existing.classificationRevision == snapshot.classificationRevision else { throw StoreError.staleIdentity }
        let merged = PresentationSnapshot(
            schemaVersion: snapshot.schemaVersion, identity: snapshot.identity,
            classificationRevision: snapshot.classificationRevision, window: snapshot.window,
            generatedAt: snapshot.generatedAt, lastSourceCheckAt: snapshot.lastSourceCheckAt ?? existing.lastSourceCheckAt,
            lastIndexCompletedAt: snapshot.lastIndexCompletedAt ?? existing.lastIndexCompletedAt,
            statisticsThrough: snapshot.statisticsThrough ?? existing.statisticsThrough,
            quota: snapshot.quota ?? existing.quota, home: snapshot.home ?? existing.home,
            failureCount: snapshot.failureCount, nextRetryAt: snapshot.nextRetryAt,
            refreshSchedule: snapshot.refreshSchedule ?? existing.refreshSchedule)
        try write(merged, expectedIdentity: expectedIdentity, generation: generation)
    }

    /// Updates only scheduler metadata on the existing payload. The payload's
    /// identity and generation are never rewritten, and older callbacks cannot
    /// replace a newer schedule revision.
    public func updateSchedule(
        _ schedule: PresentationRefreshSchedule,
        databaseEpoch: String,
        permit: WritePermit,
        classificationRevision: String? = nil,
        window: CapabilityQueryWindow? = nil
    ) throws {
        let existing = try read()
        if existing == nil {
            // A first projection can fail before a full payload exists. Keep
            // retry metadata durable in a deliberately empty container, but
            // never invent quota or Home content. Callers must provide the
            // identity's classification/window captured for that request.
            guard let activeIdentity,
                  activeIdentity.databaseEpoch == databaseEpoch,
                  permit.revision == revision,
                  permit.identity == activeIdentity,
                  let classificationRevision,
                  let window else { return }
            let placeholder = PresentationSnapshot(
                identity: activeIdentity,
                classificationRevision: classificationRevision,
                window: window,
                generatedAt: schedule.recordedAt,
                refreshSchedule: schedule
            )
            try writeData(placeholder)
            return
        }
        guard let existing, existing.identity.databaseEpoch == databaseEpoch else { return }
        // A source commit may advance dataGeneration while projection fails;
        // the old payload must retain the new same-epoch retry schedule without
        // being relabeled. A live permit for that epoch proves the cache has
        // not been revoked; an unactivated/reopened store must not accept a
        // delayed callback.
        guard let activeIdentity,
              permit.revision == revision,
              permit.identity == activeIdentity,
              activeIdentity.databaseEpoch == existing.identity.databaseEpoch,
              revokedIdentity?.databaseEpoch != existing.identity.databaseEpoch else {
            throw StoreError.staleIdentity
        }
        if let current = existing.refreshSchedule, current.revision > schedule.revision { return }
        let updated = PresentationSnapshot(
            schemaVersion: existing.schemaVersion,
            identity: existing.identity,
            classificationRevision: existing.classificationRevision,
            window: existing.window,
            generatedAt: existing.generatedAt,
            lastSourceCheckAt: existing.lastSourceCheckAt,
            lastIndexCompletedAt: existing.lastIndexCompletedAt,
            statisticsThrough: existing.statisticsThrough,
            quota: existing.quota,
            home: existing.home,
            failureCount: existing.failureCount,
            nextRetryAt: existing.nextRetryAt,
            refreshSchedule: schedule
        )
        try writeData(updated)
    }

    public func delete(expectedIdentity: PresentationIdentity? = nil) throws {
        if let expectedIdentity, let existing = try read(), existing.identity != expectedIdentity { throw StoreError.staleIdentity }
        // Revoke every previously issued permit before touching the file. The
        // revision bump makes a late writer stale even when file removal
        // fails, so deletion cannot be followed by cache resurrection.
        revision &+= 1
        revokedIdentity = expectedIdentity ?? activeIdentity
        activeIdentity = nil
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            guard values.isDirectory != true, values.isRegularFile == true else {
                throw StoreError.atomicWriteFailed
            }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.atomicWriteFailed
        }
        do { try FileManager.default.removeItem(at: url) } catch { throw StoreError.atomicWriteFailed }
    }
}
