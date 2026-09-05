import XCTest
@testable import DirectorCore

final class RolloutEventDecoderTests: XCTestCase {

    private var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parsing", isDirectory: true)
    }

    private func fixture(_ name: String) -> URL {
        fixturesRoot.appendingPathComponent(name)
    }

    private func decodeAll(_ url: URL) throws -> (lines: [DecodedLine], issues: [RolloutDecodingIssue]) {
        guard let reader = JSONLIncrementalReader(url: url) else {
            throw XCTSkip("cannot open fixture")
        }
        let decoder = RolloutEventDecoder()
        var lines: [DecodedLine] = []
        var issues: [RolloutDecodingIssue] = []
        while let line = try reader.nextLine() {
            let result = decoder.decode(line)
            if let decoded = result.line {
                lines.append(decoded)
            }
            issues.append(contentsOf: result.issues)
        }
        return (lines, issues)
    }

    private func envelopes(_ lines: [DecodedLine]) -> [RolloutEnvelope] {
        lines.compactMap { line in
            if case .envelope(let envelope) = line { return envelope }
            return nil
        }
    }

    func testDecodesKnownEnvelopesInOrder() throws {
        let (lines, issues) = try decodeAll(fixture("basic.jsonl"))
        XCTAssertTrue(issues.isEmpty)
        let envelopes = envelopes(lines)
        XCTAssertEqual(envelopes.map(\.type), [
            .sessionMeta, .turnContext, .responseItem, .eventMessage, .compacted,
        ])
    }

    func testTimestampParsedAsISO8601() throws {
        let (lines, _) = try decodeAll(fixture("basic.jsonl"))
        let first = envelopes(lines).first
        let expected = try? Date("2026-08-15T04:11:50.973Z", strategy: .iso8601)
        XCTAssertNotNil(expected)
        XCTAssertEqual(first?.timestamp, expected)
    }

    func testMalformedMiddleLineSkippedAndParsingContinues() throws {
        let (lines, issues) = try decodeAll(fixture("malformed-middle.jsonl"))
        let envelopes = envelopes(lines)
        XCTAssertEqual(envelopes.count, 2)
        XCTAssertEqual(envelopes.map(\.type), [.eventMessage, .eventMessage])
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.category, .malformedJSON)
        XCTAssertEqual(issues.first?.lineNumber, 2)
    }

    func testUnknownEventRecordedWithoutPayload() throws {
        let (lines, _) = try decodeAll(fixture("unknown-event.jsonl"))
        XCTAssertEqual(lines.count, 1)
        guard case .unknownEvent(let record) = lines[0] else {
            return XCTFail("expected unknown event record")
        }
        XCTAssertEqual(record.typeName, "mystery_event")
        XCTAssertEqual(record.lineNumber, 1)
    }

    func testCompactionEventsDecoded() throws {
        let (lines, _) = try decodeAll(fixture("compacted.jsonl"))
        let envelopes = envelopes(lines)
        XCTAssertEqual(envelopes.count, 2)
        XCTAssertTrue(envelopes.allSatisfy { $0.type == .compacted })
        XCTAssertNotNil(envelopes.first?.payload)
    }

    func testMissingTypeProducesIssue() throws {
        let decoder = RolloutEventDecoder()
        let line = JSONLLine(byteOffset: 0, lineNumber: 7, text: #"{"timestamp":"2026-08-15T04:11:50.973Z","payload":{}}"#)
        let result = decoder.decode(line)
        XCTAssertNil(result.line)
        XCTAssertEqual(result.issues.first?.category, .missingType)
        XCTAssertEqual(result.issues.first?.lineNumber, 7)
    }

    func testSupportedEventTypesCoverAllKnownTypes() {
        let expected = Set(RolloutEventType.allCases.map(\.rawValue))
        XCTAssertEqual(Set(RolloutEventDecoder.supportedEventTypes), expected)
        XCTAssertEqual(RolloutEventDecoder.supportedEventTypes.count, expected.count)
    }

    func testParserVersionTriggersDerivedDataReindexAfterIdentityFix() {
        XCTAssertEqual(RolloutEventDecoder.parserVersion, "1.2.0")
    }
}
