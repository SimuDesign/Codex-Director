import XCTest
@testable import DirectorCore

final class JSONLIncrementalReaderTests: XCTestCase {

    private var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parsing", isDirectory: true)
    }

    private func fixture(_ name: String) -> URL {
        fixturesRoot.appendingPathComponent(name)
    }

    func testEmptyFileYieldsNoLines() throws {
        guard let reader = JSONLIncrementalReader(url: fixture("empty.jsonl")) else {
            return XCTFail("reader failed to open")
        }
        XCTAssertNil(try reader.nextLine())
    }

    func testFileWithoutTrailingNewlineEmitsLastLine() throws {
        guard let reader = JSONLIncrementalReader(url: fixture("no-trailing-newline.jsonl")) else {
            return XCTFail("reader failed to open")
        }
        let first = try reader.nextLine()
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.lineNumber, 1)
        XCTAssertTrue(first?.text.contains("task_started") ?? false)
        XCTAssertNil(try reader.nextLine())
    }

    func testReadsAllLinesWithOffsetsAndNumbers() throws {
        guard let reader = JSONLIncrementalReader(url: fixture("basic.jsonl")) else {
            return XCTFail("reader failed to open")
        }
        var lines: [JSONLLine] = []
        while let line = try reader.nextLine() {
            lines.append(line)
        }
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.map(\.lineNumber), [1, 2, 3, 4, 5])
        for index in 1..<lines.count {
            XCTAssertGreaterThan(lines[index].byteOffset, lines[index - 1].byteOffset)
        }
        // The last line in basic.jsonl ends with a newline, so the reader
        // consumes exactly the file size.
        let fileSize = try FileManager.default.attributesOfItem(atPath: fixture("basic.jsonl").path)[.size] as? UInt64 ?? 0
        XCTAssertEqual(reader.currentByteOffset, fileSize)
    }

    func testResumeFromByteOffsetWithoutDuplication() throws {
        // First pass: read all lines and remember the third line's offset.
        guard let fullReader = JSONLIncrementalReader(url: fixture("basic.jsonl")) else {
            return XCTFail("reader failed to open")
        }
        var allLines: [JSONLLine] = []
        while let line = try fullReader.nextLine() {
            allLines.append(line)
        }
        XCTAssertEqual(allLines.count, 5)
        let resumeTarget = allLines[2]

        // Second pass: resume exactly at that line's offset and line number.
        guard let resumed = JSONLIncrementalReader(
            url: fixture("basic.jsonl"),
            startOffset: resumeTarget.byteOffset,
            startLine: resumeTarget.lineNumber
        ) else {
            return XCTFail("reader failed to open")
        }
        var resumedLines: [JSONLLine] = []
        while let line = try resumed.nextLine() {
            resumedLines.append(line)
        }
        XCTAssertEqual(resumedLines.map(\.lineNumber), [3, 4, 5])
        XCTAssertEqual(resumedLines.first, resumeTarget)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(JSONLIncrementalReader(url: fixture("does-not-exist.jsonl")))
    }
}
