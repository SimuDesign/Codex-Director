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
        let fileSize = try FileManager.default.attributesOfItem(
            atPath: fixture("no-trailing-newline.jsonl").path
        )[.size] as? UInt64 ?? 0
        XCTAssertEqual(reader.newlineSearchBytesInspected, fileSize)
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
        let fileSize = try FileManager.default.attributesOfItem(
            atPath: fixture("basic.jsonl").path
        )[.size] as? UInt64 ?? 0
        XCTAssertEqual(
            resumed.newlineSearchBytesInspected,
            fileSize - resumeTarget.byteOffset
        )
    }

    func testBoundedReadDoesNotEmitTailWithoutNewlineAtBoundary() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-bounded-tail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("first\nsecond-is-cut\nthird\n".utf8).write(to: file)

        let boundary = UInt64(Data("first\nsecond".utf8).count)
        guard let reader = JSONLIncrementalReader(
            url: file,
            chunkSize: 3,
            endOffsetExclusive: boundary
        ) else {
            return XCTFail("reader failed to open")
        }

        XCTAssertEqual(try reader.nextLine()?.text, "first")
        XCTAssertNil(try reader.nextLine())
        XCTAssertLessThan(reader.currentByteOffset, boundary)
        XCTAssertEqual(reader.newlineSearchBytesInspected, boundary)
    }

    func testBoundedReadAtNewlineEmitsOnlyCompleteWindowLines() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-bounded-complete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("first\nsecond\nthird\n".utf8).write(to: file)

        let start = UInt64(Data("first\n".utf8).count)
        let end = start + UInt64(Data("second\n".utf8).count)
        guard let reader = JSONLIncrementalReader(
            url: file,
            startOffset: start,
            chunkSize: 2,
            endOffsetExclusive: end
        ) else {
            return XCTFail("reader failed to open")
        }

        XCTAssertEqual(try reader.nextLine()?.text, "second")
        XCTAssertNil(try reader.nextLine())
        XCTAssertEqual(reader.currentByteOffset, end)
        XCTAssertEqual(reader.newlineSearchBytesInspected, end - start)
    }

    func testVeryLongLineSearchesEachByteOnlyOnce() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-linear-newline-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = String(repeating: "x", count: 512 * 1_024)
        let contents = Data("\(first)\nsecond\n".utf8)
        try contents.write(to: file)

        guard let reader = JSONLIncrementalReader(url: file, chunkSize: 1_024) else {
            return XCTFail("reader failed to open")
        }

        XCTAssertEqual(try reader.nextLine()?.text, first)
        XCTAssertEqual(try reader.nextLine()?.text, "second")
        XCTAssertNil(try reader.nextLine())
        XCTAssertEqual(reader.currentByteOffset, UInt64(contents.count))
        XCTAssertEqual(reader.newlineSearchBytesInspected, UInt64(contents.count))
    }

    func testSearchCursorPreservesUTF8AndOffsetsAcrossCompaction() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-search-cursor-compaction-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = ["前缀🙂", String(repeating: "界", count: 257), "尾行"]
        let contents = Data(expected.joined(separator: "\n").utf8)
        try contents.write(to: file)

        guard let reader = JSONLIncrementalReader(url: file, chunkSize: 7) else {
            return XCTFail("reader failed to open")
        }

        var lines: [JSONLLine] = []
        while let line = try reader.nextLine() {
            lines.append(line)
        }

        XCTAssertEqual(lines.map(\.text), expected)
        XCTAssertEqual(lines.map(\.lineNumber), [1, 2, 3])
        XCTAssertEqual(
            lines.map(\.byteOffset),
            [
                0,
                UInt64(Data("前缀🙂\n".utf8).count),
                UInt64(Data("前缀🙂\n\(expected[1])\n".utf8).count),
            ]
        )
        XCTAssertEqual(reader.currentByteOffset, UInt64(contents.count))
        XCTAssertEqual(reader.newlineSearchBytesInspected, UInt64(contents.count))
    }

    func testCancellationIsObservedBeforeReadingAnotherChunk() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-search-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("first\nsecond\n".utf8).write(to: file)
        guard let reader = JSONLIncrementalReader(url: file, chunkSize: 1) else {
            return XCTFail("reader failed to open")
        }

        let task = Task { () throws -> JSONLLine? in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return try reader.nextLine()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled read unexpectedly continued")
        } catch is CancellationError {
            XCTAssertEqual(reader.currentByteOffset, 0)
            XCTAssertEqual(reader.newlineSearchBytesInspected, 0)
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(JSONLIncrementalReader(url: fixture("does-not-exist.jsonl")))
    }
}
