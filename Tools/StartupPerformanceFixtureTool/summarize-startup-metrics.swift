#!/usr/bin/env swift

import Foundation
import Darwin

private let allowedRoot = "/tmp/codex-director-startup-perf"
private let metricFileLimit = 2 * 1024 * 1024
private let coreMarkers = ["root_appeared", "cache_visible", "startup_ready", "input_to_selection", "input_to_window_update"]

private struct MetricMarker: Decodable {
    let stage: String
    let elapsedMilliseconds: Double
}

private struct MetricSnapshot: Decodable {
    let schemaVersion: Int
    let processID: String
    let markers: [MetricMarker]
    let counters: [String: Int]
    let flushSequence: UInt64
    let processBirthToAppInitMilliseconds: Double?
    let processBirthBridgeUncertaintyMilliseconds: Double?
}

private struct Sample {
    let snapshot: MetricSnapshot
    let markerValues: [String: [Double]]
    let directory: URL
}

private let startupFirstMarkers = ["root_appeared", "cache_visible", "startup_ready"]

private func firstMarkerValue(_ sample: Sample, stage: String) -> Double? {
    sample.snapshot.markers.first(where: { $0.stage == stage })?.elapsedMilliseconds
}

private enum ToolError: Error, CustomStringConvertible {
    case usage
    case unsafePath
    case duplicatePath
    case unreadableDirectory

    var description: String {
        switch self {
        case .usage: return "usage"
        case .unsafePath: return "unsafe_metrics_path"
        case .duplicatePath: return "duplicate_metrics_path"
        case .unreadableDirectory: return "unreadable_metrics_directory"
        }
    }
}

private func safeAggregateKey(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 80 && value.unicodeScalars.allSatisfy { scalar in
        scalar == "_" || scalar == "-" || (scalar.isASCII &&
            ((48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)))
    }
}

private func isSymbolicLink(_ url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
    return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
}

private func validatedMetricsDirectory(_ rawPath: String) throws -> URL {
    guard rawPath.hasPrefix(allowedRoot + "/"), !rawPath.contains("/../"), !rawPath.hasSuffix("/") else { throw ToolError.unsafePath }
    let url = URL(fileURLWithPath: rawPath, isDirectory: true)
    let components = url.pathComponents
    let rootComponents = URL(fileURLWithPath: allowedRoot).pathComponents
    guard components.count == rootComponents.count + 2,
          Array(components.prefix(rootComponents.count)) == rootComponents,
          components.last == "metrics",
          let fixtureID = components.dropLast().last,
          UUID(uuidString: fixtureID) != nil else { throw ToolError.unsafePath }

    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: allowedRoot, isDirectory: true)
    let fixture = url.deletingLastPathComponent()
    guard !isSymbolicLink(root),
          !isSymbolicLink(fixture),
          !isSymbolicLink(url),
          fileManager.fileExists(atPath: url.path),
          (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        throw ToolError.unsafePath
    }
    guard let rootAttributes = try? fileManager.attributesOfItem(atPath: root.path),
          let fixtureAttributes = try? fileManager.attributesOfItem(atPath: fixture.path),
          let rootOwner = rootAttributes[.ownerAccountID] as? NSNumber,
          rootOwner.uint32Value == getuid(),
          let rootPermissions = rootAttributes[.posixPermissions] as? NSNumber,
          rootPermissions.intValue & 0o077 == 0,
          let fixtureOwner = fixtureAttributes[.ownerAccountID] as? NSNumber,
          fixtureOwner.uint32Value == getuid(),
          let fixturePermissions = fixtureAttributes[.posixPermissions] as? NSNumber,
          fixturePermissions.intValue & 0o777 == 0o700,
          let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          let owner = attributes[.ownerAccountID] as? NSNumber,
          owner.uint32Value == getuid(),
          let metricsPermissions = attributes[.posixPermissions] as? NSNumber,
          metricsPermissions.intValue & 0o777 == 0o700 else { throw ToolError.unsafePath }
    return url
}

private func readSamples(from directory: URL) throws -> (samples: [Sample], invalidFiles: Int) {
    let fileManager = FileManager.default
    guard let children = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: []
    ) else { throw ToolError.unreadableDirectory }

    var samples: [Sample] = []
    var invalidFiles = 0
    for child in children {
        let name = child.lastPathComponent
        guard name.hasPrefix("startup-metrics-"), name.hasSuffix(".json") else {
            throw ToolError.unsafePath
        }
        let processID = String(name.dropFirst("startup-metrics-".count).dropLast(".json".count))
        guard UUID(uuidString: processID) != nil,
              !isSymbolicLink(child),
              (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let attributes = try? fileManager.attributesOfItem(atPath: child.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let referenceCount = attributes[.referenceCount] as? NSNumber,
              referenceCount.intValue == 1,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= metricFileLimit else { throw ToolError.unsafePath }

        do {
            let snapshot = try JSONDecoder().decode(MetricSnapshot.self, from: Data(contentsOf: child, options: [.mappedIfSafe]))
            guard snapshot.schemaVersion == 1,
                  UUID(uuidString: snapshot.processID) != nil,
                  snapshot.processID.caseInsensitiveCompare(processID) == .orderedSame,
                  snapshot.flushSequence > 0,
                  snapshot.counters.values.allSatisfy({ $0 >= 0 }),
                  snapshot.counters.keys.allSatisfy(safeAggregateKey),
                  snapshot.markers.allSatisfy({ safeAggregateKey($0.stage) && $0.elapsedMilliseconds.isFinite && $0.elapsedMilliseconds >= 0 }),
                  snapshot.processBirthToAppInitMilliseconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  snapshot.processBirthBridgeUncertaintyMilliseconds.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                invalidFiles += 1
                continue
            }
            let markerValues = Dictionary(grouping: snapshot.markers, by: \.stage)
                .mapValues { $0.map(\.elapsedMilliseconds) }
            samples.append(Sample(snapshot: snapshot, markerValues: markerValues, directory: directory))
        } catch {
            invalidFiles += 1
        }
    }
    return (samples, invalidFiles)
}

private func nearestRank(_ values: [Double], percentile: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = max(1, Int(ceil(percentile * Double(sorted.count))))
    return sorted[min(rank, sorted.count) - 1]
}

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func formatted(_ value: Double?) -> String {
    guard let value else { return "unobserved" }
    return String(format: "%.3f", value)
}

private func counterSummary(_ samples: [Sample], key: String) -> (observed: Int, total: Int) {
    var observed = 0
    var total = 0
    for sample in samples {
        if let value = sample.snapshot.counters[key] {
            observed += 1
            total += value
        }
    }
    return (observed, total)
}

private func hasFailure(_ sample: Sample) -> Bool {
    sample.snapshot.markers.contains { $0.stage.contains("fail") || $0.stage.contains("invalid") } ||
    sample.snapshot.counters.contains { key, value in value > 0 && (key.contains("fail") || key.contains("invalid")) }
}

private func hasUnsupported(_ sample: Sample) -> Bool {
    sample.snapshot.counters.contains { key, value in value > 0 && (key.contains("unsupported") || key.contains("uncertain")) } ||
    ["query_observer_connected", "source_observer_connected"].contains { sample.snapshot.counters[$0] == nil }
}

private func printReport(scenario: String, samples: [Sample], invalidFiles: Int, duplicateProcessSamples: Int, givenDirectoryCount: Int) {
    print("scenario=\(scenario)")
    print("given_directories=\(givenDirectoryCount)")
    print("valid_samples=\(samples.count)")
    print("invalid_metric_files=\(invalidFiles)")
    print("duplicate_process_samples=\(duplicateProcessSamples)")
    print("failure_samples=\(samples.filter(hasFailure).count)")
    print("unsupported_samples=\(samples.filter(hasUnsupported).count)")

    for marker in coreMarkers {
        let values: [Double]
        if startupFirstMarkers.contains(marker) {
            values = samples.compactMap { firstMarkerValue($0, stage: marker) }
        } else {
            values = samples.flatMap { $0.markerValues[marker] ?? [] }
        }
        let present = samples.filter {
            if startupFirstMarkers.contains(marker) { return firstMarkerValue($0, stage: marker) != nil }
            return !($0.markerValues[marker] ?? []).isEmpty
        }.count
        print("marker.\(marker).present_samples=\(present) missing_samples=\(samples.count - present) median_ms=\(formatted(median(values))) p95_ms=\(formatted(nearestRank(values, percentile: 0.95))) max_ms=\(formatted(values.max()))")
    }

    let processBirth = samples.compactMap(\.snapshot.processBirthToAppInitMilliseconds)
    let processBirthObserved = processBirth.count
    print("process_birth_bridge.present_samples=\(processBirthObserved) missing_samples=\(samples.count - processBirthObserved) median_ms=\(formatted(median(processBirth))) p95_ms=\(formatted(nearestRank(processBirth, percentile: 0.95))) max_ms=\(formatted(processBirth.max())) note=wall_clock_bridge_not_pixel_proof")

    let uncertainBridgeSamples = samples.filter { sample in
        ["process_birth_unsupported", "process_birth_clock_uncertain"].contains { key in
            (sample.snapshot.counters[key] ?? 0) > 0
        } || sample.snapshot.processBirthBridgeUncertaintyMilliseconds != nil
    }.count
    print("process_birth_bridge_uncertain_samples=\(uncertainBridgeSamples)")

    let bridgeUncertainty = samples.compactMap { $0.snapshot.processBirthBridgeUncertaintyMilliseconds }
    print("process_birth_bridge_uncertainty_ms.present_samples=\(bridgeUncertainty.count) missing_samples=\(samples.count - bridgeUncertainty.count) median_ms=\(formatted(median(bridgeUncertainty))) p95_ms=\(formatted(nearestRank(bridgeUncertainty, percentile: 0.95))) max_ms=\(formatted(bridgeUncertainty.max()))")

    for (label, marker) in [("process_to_root", "root_appeared"), ("process_to_cache", "cache_visible"), ("process_to_startup_ready", "startup_ready")] {
        let values = samples.compactMap { sample -> Double? in
            guard let bridge = sample.snapshot.processBirthToAppInitMilliseconds,
                  let markerValue = firstMarkerValue(sample, stage: marker) else { return nil }
            return bridge + markerValue
        }
        let missingBridge = samples.filter { $0.snapshot.processBirthToAppInitMilliseconds == nil }.count
        let missingMarker = samples.filter { firstMarkerValue($0, stage: marker) == nil }.count
        print("\(label).present_samples=\(values.count) missing_bridge=\(missingBridge) missing_marker=\(missingMarker) median_ms=\(formatted(median(values))) p95_ms=\(formatted(nearestRank(values, percentile: 0.95))) max_ms=\(formatted(values.max())) note=wall_clock_bridge_plus_first_marker_not_pixel_proof")
    }

    let cacheHits = samples.filter { firstMarkerValue($0, stage: "cache_visible") != nil }.count
    print("cache_hits=\(cacheHits) cache_misses_or_unobserved=\(samples.count - cacheHits)")

    let queryKeys = Set(samples.flatMap { $0.snapshot.counters.keys.filter { $0.hasPrefix("query_") } }).sorted()
    let sourceKeys = Set(samples.flatMap { $0.snapshot.counters.keys.filter { $0.hasPrefix("source_") } }).sorted()
    for key in queryKeys {
        let value = counterSummary(samples, key: key)
        print("counter.\(key).observed_samples=\(value.observed) total=\(value.observed == 0 ? "unobserved" : String(value.total))")
    }
    for key in sourceKeys {
        let value = counterSummary(samples, key: key)
        print("counter.\(key).observed_samples=\(value.observed) total=\(value.observed == 0 ? "unobserved" : String(value.total))")
    }
    for key in ["query_directory", "query_identity"] where !queryKeys.contains(key) {
        let value = counterSummary(samples, key: key)
        print("counter.\(key).observed_samples=\(value.observed) total=\(value.observed == 0 ? "unobserved" : String(value.total))")
    }

    if scenario == "cachedIndexed" {
        let observerReady = samples.filter {
            $0.snapshot.counters["query_observer_connected"] != nil &&
            $0.snapshot.counters["source_observer_connected"] != nil
        }
        let unverifiable = observerReady.filter { sample in
            ["source_started", "query_startup", "query_quota"].contains { sample.snapshot.counters[$0] == nil }
        }.count
        let verifiable = observerReady.filter { sample in
            ["source_started", "query_startup", "query_quota"].allSatisfy { sample.snapshot.counters[$0] != nil }
        }
        let violations = verifiable.filter {
            $0.snapshot.counters["source_started"]! != 0 ||
            $0.snapshot.counters["query_startup"]! != 0 ||
            $0.snapshot.counters["query_quota"]! != 0
        }.count
        print("cached_zero_aggregation_gate=all_given_valid_samples observer_ready=\(observerReady.count) unverifiable_samples=\(unverifiable) violating_samples=\(violations) note=no_launch_order_inferred")
    } else {
        print("cached_zero_aggregation_gate=not_applicable")
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 3, arguments.count <= 5,
          arguments.first == "--scenario" else { throw ToolError.usage }
    let scenario = arguments[1]
    guard ["cachedIndexed", "uncachedIndexed", "uncachedNoIndex"].contains(scenario) else { throw ToolError.usage }
    let paths = Array(arguments.dropFirst(2))
    var directories = [URL](); var seen = Set<String>()
    for path in paths {
        let directory = try validatedMetricsDirectory(path)
        guard seen.insert(directory.path).inserted else { throw ToolError.duplicatePath }
        directories.append(directory)
    }
    var samples = [Sample](); var invalidFiles = 0; var duplicateProcessSamples = 0
    var seenProcessIDs = Set<String>()
    for directory in directories {
        let result = try readSamples(from: directory)
        for sample in result.samples {
            if seenProcessIDs.insert(sample.snapshot.processID.lowercased()).inserted {
                samples.append(sample)
            } else {
                duplicateProcessSamples += 1
            }
        }
        invalidFiles += result.invalidFiles
    }
    printReport(scenario: scenario, samples: samples, invalidFiles: invalidFiles, duplicateProcessSamples: duplicateProcessSamples, givenDirectoryCount: directories.count)
} catch let error as ToolError {
    FileHandle.standardError.write(Data("error=\(error.description)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("error=metrics_read_failed\n".utf8))
    exit(2)
}
