import Foundation

public struct CapabilityChangeDetectionResult: Sendable, Equatable {
    public let state: CapabilityHistoryStateV1
    public let newEvents: [CapabilityChangeEvent]
    public let issueCodes: [CapabilityHistoryIssueCode]
    public let didChange: Bool

    public init(
        state: CapabilityHistoryStateV1,
        newEvents: [CapabilityChangeEvent],
        issueCodes: [CapabilityHistoryIssueCode],
        didChange: Bool
    ) {
        self.state = state
        self.newEvents = newEvents
        self.issueCodes = issueCodes
        self.didChange = didChange
    }
}

/// Pure capability-history state machine. It consumes only verified,
/// privacy-safe observations and never performs filesystem or persistence I/O.
public struct CapabilityChangeDetector: Sendable {
    public let retentionPolicy: CapabilityHistoryRetentionPolicy

    public init(retentionPolicy: CapabilityHistoryRetentionPolicy = .standard) {
        precondition(retentionPolicy.duration >= 0)
        precondition(retentionPolicy.maximumEventsPerResource > 0)
        precondition(retentionPolicy.maximumEvents > 0)
        self.retentionPolicy = retentionPolicy
    }

    public func apply(
        _ previous: CapabilityHistoryStateV1,
        batch: CapabilityHistoryScanBatch
    ) -> CapabilityChangeDetectionResult {
        guard batch.source == .filesystem else {
            return CapabilityChangeDetectionResult(
                state: previous,
                newEvents: [],
                issueCodes: [.cacheBatchIgnored],
                didChange: false
            )
        }
        let possibleEventCount = batch.observations.count.addingReportingOverflow(previous.baselines.count)
        guard previous.revision >= 0,
              previous.revision < Int64.max - 1,
              previous.nextSequence > 0,
              previous.nextSequence < Int64.max,
              !possibleEventCount.overflow,
              possibleEventCount.partialValue <= Int(Int64.max),
              Int64(possibleEventCount.partialValue) < Int64.max - previous.nextSequence else {
            return CapabilityChangeDetectionResult(
                state: previous,
                newEvents: [],
                issueCodes: [.invalidObservation],
                didChange: false
            )
        }

        var issues = Set<CapabilityHistoryIssueCode>()
        var scopesByID: [String: CapabilityHistoryScanScope] = [:]
        for scope in batch.scopes.sorted(by: { $0.rootID < $1.rootID }) {
            guard Self.isValid(scope: scope) else {
                issues.insert(.invalidObservation)
                continue
            }
            if let existing = scopesByID[scope.rootID] {
                let compatible = existing.scope == scope.scope && existing.rootKind == scope.rootKind
                scopesByID[scope.rootID] = CapabilityHistoryScanScope(
                    rootID: existing.rootID,
                    scope: existing.scope,
                    rootKind: existing.rootKind,
                    coverage: compatible
                        ? existing.coverage.dominating(with: scope.coverage)
                        : .partial
                )
                if !compatible { issues.insert(.invalidObservation) }
            } else {
                scopesByID[scope.rootID] = scope
            }
        }

        var observationsByID: [String: CapabilityHistoryObservation] = [:]
        var invalidRoots = Set<String>()
        for observation in batch.observations.sorted(by: { $0.resourceID < $1.resourceID }) {
            guard let scope = scopesByID[observation.sourceRootID],
                  Self.isValid(observation: observation, in: scope),
                  observationsByID[observation.resourceID] == nil else {
                issues.insert(.invalidObservation)
                invalidRoots.insert(observation.sourceRootID)
                continue
            }
            observationsByID[observation.resourceID] = observation
        }
        for rootID in invalidRoots {
            guard let scope = scopesByID[rootID] else { continue }
            scopesByID[rootID] = CapabilityHistoryScanScope(
                rootID: scope.rootID,
                scope: scope.scope,
                rootKind: scope.rootKind,
                coverage: scope.coverage.dominating(with: .partial)
            )
        }
        let latestScanCoverage = CapabilityHistoryCoverage.aggregate(
            scopesByID.values.map(\.coverage)
        )

        guard let initialScopes = Self.uniqueDictionary(previous.scopes, key: \.rootID),
              let initialBaselines = Self.uniqueDictionary(previous.baselines, key: \.resourceID),
              let initialPending = Self.uniqueDictionary(previous.pendingMissing, key: \.resourceID) else {
            return CapabilityChangeDetectionResult(
                state: previous,
                newEvents: [],
                issueCodes: [.invalidObservation],
                didChange: false
            )
        }
        var scopes = initialScopes
        var baselines = initialBaselines
        var pending = initialPending
        var events = previous.events
        var newEvents: [CapabilityChangeEvent] = []
        var nextSequence = previous.nextSequence
        let priorAnchor = previous.retentionAnchorAt
        let retentionAnchor = maxDate(priorAnchor, batch.observedAt)
        if let priorAnchor, batch.observedAt < priorAnchor {
            issues.insert(.clockRollback)
        }

        let currentRootIDs = Set(scopesByID.keys)
        let interruptedResourceIDs = pending.values.compactMap { pendingValue -> String? in
            guard let scope = scopesByID[pendingValue.sourceRootID],
                  scope.coverage == .complete else { return pendingValue.resourceID }
            return nil
        }
        if !interruptedResourceIDs.isEmpty {
            issues.insert(.interruptedMissingConfirmation)
            for resourceID in interruptedResourceIDs { pending.removeValue(forKey: resourceID) }
        }

        for rootID in currentRootIDs.sorted() {
            guard let scanScope = scopesByID[rootID] else { continue }
            let rootObservations = observationsByID.values
                .filter { $0.sourceRootID == rootID }
                .sorted { $0.resourceID < $1.resourceID }
            var initializedScope = scopes[rootID]

            if initializedScope == nil {
                // Positive records from an incomplete first scan are useful as
                // a seed, but the scope is not initialized until one complete
                // scan proves its whole current membership.
                for observation in rootObservations {
                    baselines[observation.resourceID] = Self.baseline(from: observation)
                    pending.removeValue(forKey: observation.resourceID)
                }
                if scanScope.coverage == .complete {
                    let initialized = CapabilityHistoryScopeBaseline(
                        rootID: rootID,
                        scope: scanScope.scope,
                        rootKind: scanScope.rootKind.rawValue,
                        initializedAt: batch.observedAt,
                        lastCompleteAt: batch.observedAt
                    )
                    scopes[rootID] = initialized
                    initializedScope = initialized
                } else {
                    continue
                }
            }

            let compatibleScope = initializedScope?.scope == scanScope.scope
                && initializedScope?.rootKind == scanScope.rootKind.rawValue
            let effectiveCoverage: CapabilityHistoryCoverage = compatibleScope
                ? scanScope.coverage
                : .partial
            if !compatibleScope { issues.insert(.invalidObservation) }

            for observation in rootObservations {
                if let old = baselines[observation.resourceID] {
                    if old.signatureAlgorithm != observation.signatureAlgorithm {
                        issues.insert(.signatureAlgorithmChanged)
                        baselines[observation.resourceID] = Self.baseline(from: observation)
                        pending.removeValue(forKey: observation.resourceID)
                        continue
                    }

                    let documentChanges = Self.changedDocuments(from: old, to: observation)
                    let signatureChanged = old.signature != observation.signature
                    let kind: CapabilityChangeKind?
                    if old.presence == .missing {
                        kind = .reappeared
                    } else if signatureChanged || !documentChanges.documents.isEmpty {
                        kind = .modified
                    } else {
                        kind = nil
                    }
                    if let kind {
                        let event = Self.event(
                            epoch: previous.epoch,
                            sequence: nextSequence,
                            observation: observation,
                            kind: kind,
                            changedDocuments: documentChanges.documents,
                            changedDocumentsAreExact: documentChanges.isExact,
                            previousConfirmedAt: old.lastConfirmedAt,
                            retentionObservedAt: retentionAnchor
                        )
                        nextSequence += 1
                        events.append(event)
                        newEvents.append(event)
                    }
                    baselines[observation.resourceID] = Self.baseline(from: observation)
                } else {
                    let event = Self.event(
                        epoch: previous.epoch,
                        sequence: nextSequence,
                        observation: observation,
                        kind: .added,
                        changedDocuments: Set(observation.documents),
                        changedDocumentsAreExact: true,
                        previousConfirmedAt: nil,
                        retentionObservedAt: retentionAnchor
                    )
                    nextSequence += 1
                    events.append(event)
                    newEvents.append(event)
                    baselines[observation.resourceID] = Self.baseline(from: observation)
                }
                pending.removeValue(forKey: observation.resourceID)
            }

            guard effectiveCoverage == .complete else { continue }
            scopes[rootID] = CapabilityHistoryScopeBaseline(
                rootID: rootID,
                scope: scanScope.scope,
                rootKind: scanScope.rootKind.rawValue,
                initializedAt: initializedScope?.initializedAt ?? batch.observedAt,
                lastCompleteAt: batch.observedAt
            )
            let observedIDs = Set(rootObservations.map(\.resourceID))
            let absent = baselines.values
                .filter {
                    $0.sourceRootID == rootID
                        && $0.presence == .present
                        && !observedIDs.contains($0.resourceID)
                }
                .sorted { $0.resourceID < $1.resourceID }
            for baseline in absent {
                if let prior = pending[baseline.resourceID], prior.sourceRootID == rootID {
                    let event = CapabilityChangeEvent(
                        id: Self.eventID(epoch: previous.epoch, sequence: nextSequence),
                        resourceID: baseline.resourceID,
                        name: baseline.name,
                        resourceKind: baseline.resourceKind,
                        scope: baseline.scope,
                        projectID: baseline.projectID,
                        kind: .missing,
                        changedDocuments: [],
                        observedAt: batch.observedAt,
                        previousConfirmedAt: baseline.lastConfirmedAt,
                        sequence: nextSequence,
                        retentionObservedAt: retentionAnchor
                    )
                    nextSequence += 1
                    events.append(event)
                    newEvents.append(event)
                    baselines[baseline.resourceID] = CapabilityHistoryBaseline(
                        resourceID: baseline.resourceID,
                        sourceRootID: baseline.sourceRootID,
                        name: baseline.name,
                        resourceKind: baseline.resourceKind,
                        scope: baseline.scope,
                        projectID: baseline.projectID,
                        documents: baseline.documents,
                        signature: baseline.signature,
                        documentSignatures: baseline.documentSignatures,
                        signatureAlgorithm: baseline.signatureAlgorithm,
                        presence: .missing,
                        lastConfirmedAt: baseline.lastConfirmedAt,
                        missingSince: batch.observedAt
                    )
                    pending.removeValue(forKey: baseline.resourceID)
                } else {
                    pending[baseline.resourceID] = CapabilityHistoryPendingMissing(
                        resourceID: baseline.resourceID,
                        sourceRootID: rootID,
                        firstMissingAt: batch.observedAt,
                        previousConfirmedAt: baseline.lastConfirmedAt
                    )
                }
            }
        }

        // An explicitly omitted root cannot be used as a second confirmation.
        // Its pending record was removed above; its baseline remains intact.
        _ = currentRootIDs

        var truncatedBefore = previous.truncatedBefore
        let cutoff = retentionAnchor.addingTimeInterval(-retentionPolicy.duration)
        for baseline in baselines.values where baseline.presence == .missing {
            guard let missingSince = baseline.missingSince, missingSince < cutoff else { continue }
            baselines.removeValue(forKey: baseline.resourceID)
            pending.removeValue(forKey: baseline.resourceID)
        }
        let removed = events.filter { $0.retentionObservedAt < cutoff }
        events.removeAll { $0.retentionObservedAt < cutoff }
        Self.recordTruncation(removed, into: &truncatedBefore)

        let perResourceGroups = Dictionary(grouping: events, by: \.resourceID)
        var keptSequences = Set<Int64>()
        for values in perResourceGroups.values {
            for event in values.sorted(by: { $0.sequence > $1.sequence }).prefix(retentionPolicy.maximumEventsPerResource) {
                keptSequences.insert(event.sequence)
            }
        }
        let perResourceRemoved = events.filter { !keptSequences.contains($0.sequence) }
        events.removeAll { !keptSequences.contains($0.sequence) }
        Self.recordTruncation(perResourceRemoved, into: &truncatedBefore)

        if events.count > retentionPolicy.maximumEvents {
            let retained = events.sorted { $0.sequence > $1.sequence }.prefix(retentionPolicy.maximumEvents)
            let globalSequences = Set(retained.map(\.sequence))
            let removed = events.filter { !globalSequences.contains($0.sequence) }
            events.removeAll { !globalSequences.contains($0.sequence) }
            Self.recordTruncation(removed, into: &truncatedBefore)
        }
        if truncatedBefore != previous.truncatedBefore { issues.insert(.retentionTruncated) }

        let persistedIssues = Set(previous.issueCodes).union(issues)
        let nextState = CapabilityHistoryStateV1(
            epoch: previous.epoch,
            revision: previous.revision + 1,
            nextSequence: nextSequence,
            retentionAnchorAt: retentionAnchor,
            truncatedBefore: truncatedBefore,
            latestScanCoverage: latestScanCoverage,
            scopes: Array(scopes.values),
            baselines: Array(baselines.values),
            pendingMissing: Array(pending.values),
            events: events,
            issueCodes: Array(persistedIssues)
        )
        return CapabilityChangeDetectionResult(
            state: nextState,
            newEvents: newEvents,
            issueCodes: Array(issues).sorted { $0.rawValue < $1.rawValue },
            didChange: nextState != previous
        )
    }

    private static func isValid(scope: CapabilityHistoryScanScope) -> Bool {
        guard Self.isSafeIdentifier(scope.rootID),
              scope.scope == .global || scope.scope == .project else { return false }
        return scope.rootKind == .skills || scope.rootKind == .agents || scope.rootKind == .projects
    }

    private static func isValid(
        observation: CapabilityHistoryObservation,
        in scope: CapabilityHistoryScanScope
    ) -> Bool {
        guard observation.sourceRootID == scope.rootID,
              observation.scope == scope.scope,
              observation.resourceID == observation.id,
              Self.isSafeIdentifier(observation.resourceID),
              Self.isSafeIdentifier(observation.sourceRootID),
              observation.name.count <= 256,
              !observation.name.isEmpty,
              !PersistenceAllowlist.containsForbiddenValue(observation.name),
              observation.signature.count == 64,
              observation.signature.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              Self.validDocumentSignatures(observation.documentSignatures, documents: observation.documents),
              !observation.signatureAlgorithm.isEmpty,
              observation.signatureAlgorithm.count <= 64,
              observation.observedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
        switch observation.kind {
        case .agent:
            guard !observation.documents.isEmpty,
                  observation.documents.isSubset(of: [.agentConfiguration, .agentBrief]) else { return false }
        case .skill:
            guard observation.documents == [.skillManifest] else { return false }
        default:
            return false
        }
        if observation.scope == .project {
            guard let projectID = observation.projectID,
                  Self.isSafeIdentifier(projectID) else { return false }
        } else if observation.projectID != nil {
            return false
        }
        return true
    }

    private static func baseline(from observation: CapabilityHistoryObservation) -> CapabilityHistoryBaseline {
        CapabilityHistoryBaseline(
            resourceID: observation.resourceID,
            sourceRootID: observation.sourceRootID,
            name: observation.name,
            resourceKind: observation.kind,
            scope: observation.scope,
            projectID: observation.projectID,
            documents: Array(observation.documents),
            signature: observation.signature,
            documentSignatures: observation.documentSignatures,
            signatureAlgorithm: observation.signatureAlgorithm,
            presence: .present,
            lastConfirmedAt: observation.observedAt,
            missingSince: nil
        )
    }

    private static func changedDocuments(
        from baseline: CapabilityHistoryBaseline,
        to observation: CapabilityHistoryObservation
    ) -> (documents: Set<CapabilityTrackedDocument>, isExact: Bool) {
        let old = Set(baseline.documents)
        let new = observation.documents
        guard baseline.signature != observation.signature || old != new else {
            return ([], true)
        }
        let oldSignatures = Self.uniqueDocumentSignatures(baseline.documentSignatures)
        let newSignatures = observation.signaturesByDocument
        guard let oldSignatures,
              oldSignatures.count == old.count,
              newSignatures.count == new.count,
              Set(oldSignatures.keys) == old,
              Set(newSignatures.keys) == new else {
            return ([], false)
        }
        let changed = old.union(new).filter { oldSignatures[$0] != newSignatures[$0] }
        return changed.isEmpty ? ([], false) : (Set(changed), true)
    }

    private static func event(
        epoch: UInt64,
        sequence: Int64,
        observation: CapabilityHistoryObservation,
        kind: CapabilityChangeKind,
        changedDocuments: Set<CapabilityTrackedDocument>,
        changedDocumentsAreExact: Bool,
        previousConfirmedAt: Date?,
        retentionObservedAt: Date?
    ) -> CapabilityChangeEvent {
        CapabilityChangeEvent(
            id: eventID(epoch: epoch, sequence: sequence),
            resourceID: observation.resourceID,
            name: observation.name,
            resourceKind: observation.kind,
            scope: observation.scope,
            projectID: observation.projectID,
            kind: kind,
            changedDocuments: changedDocuments,
            changedDocumentsAreExact: changedDocumentsAreExact,
            observedAt: observation.observedAt,
            previousConfirmedAt: previousConfirmedAt,
            sequence: sequence,
            retentionObservedAt: retentionObservedAt
        )
    }

    private static func eventID(epoch: UInt64, sequence: Int64) -> String {
        "history-\(epoch)-\(sequence)"
    }

    private static func validDocumentSignatures(
        _ signatures: [CapabilityTrackedDocumentSignature],
        documents: Set<CapabilityTrackedDocument>
    ) -> Bool {
        guard !signatures.isEmpty else { return true }
        let keyed = Dictionary(grouping: signatures, by: \.document)
        return Set(keyed.keys) == documents
            && keyed.values.allSatisfy { values in
                values.count == 1
                    && values[0].sha256.count == 64
                    && values[0].sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            }
    }

    private static func uniqueDictionary<Element, Key: Hashable>(
        _ values: [Element],
        key: KeyPath<Element, Key>
    ) -> [Key: Element]? {
        var result: [Key: Element] = [:]
        for value in values {
            let key = value[keyPath: key]
            guard result[key] == nil else { return nil }
            result[key] = value
        }
        return result
    }

    private static func uniqueDocumentSignatures(
        _ values: [CapabilityTrackedDocumentSignature]
    ) -> [CapabilityTrackedDocument: String]? {
        var result: [CapabilityTrackedDocument: String] = [:]
        for value in values {
            guard result[value.document] == nil else { return nil }
            result[value.document] = value.sha256
        }
        return result
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
            && !value.contains("://")
            && !value.lowercased().hasPrefix("file:")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !PersistenceAllowlist.containsForbiddenValue(value)
    }

    private static func recordTruncation(
        _ removed: [CapabilityChangeEvent],
        into truncatedBefore: inout Date?
    ) {
        guard let newestRemoved = removed.map(\.observedAt).max() else { return }
        truncatedBefore = maxDate(truncatedBefore, newestRemoved)
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        Self.maxDate(lhs, rhs)
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }
}
