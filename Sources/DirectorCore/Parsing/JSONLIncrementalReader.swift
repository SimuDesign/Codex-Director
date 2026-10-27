import Foundation
import Darwin

/// One line read from a rollout JSONL file, with its byte offset and line
/// number in the source file.
public struct JSONLLine: Sendable, Equatable {
    public let byteOffset: UInt64
    public let lineNumber: Int
    public let text: String

    public init(byteOffset: UInt64, lineNumber: Int, text: String) {
        self.byteOffset = byteOffset
        self.lineNumber = lineNumber
        self.text = text
    }
}

/// Streaming, offset-tracking JSONL reader.
///
/// Reads files in chunks and searches each byte for a newline at most once.
/// The buffer is bounded by the current complete record, not by `chunkSize`:
/// an extremely large single line can still require memory proportional to
/// that line. Supports resuming from a byte offset without re-reading earlier
/// bytes (the caller commits the last processed offset as a checkpoint).
public final class JSONLIncrementalReader: @unchecked Sendable {
    public let url: URL

    private let fileHandle: FileHandle
    private var pending = Data()
    /// Index in `pending` of the first unconsumed byte. Slicing from this
    /// cursor instead of removing the consumed prefix keeps line extraction
    /// amortized O(line length); the buffer is compacted once the cursor
    /// passes a chunk's worth of consumed bytes. An unfinished line remains
    /// buffered in full until its newline or EOF arrives.
    private var pendingStartIndex = 0
    /// First byte that has not yet been inspected for a newline. Keeping this
    /// separate from the consumption cursor prevents every appended chunk
    /// from rescanning an unfinished long line from its beginning.
    private var newlineSearchIndex = 0
    private var bufferStartOffset: UInt64
    private var nextLineNumber: Int
    private let chunkSize: Int
    private let endOffsetExclusive: UInt64?
    private var fileReadOffset: UInt64
    private var eofReached = false
    private var boundedEndReached = false

    /// Deterministic test-only visibility into newline-search work. This is
    /// internal so production callers do not depend on an implementation
    /// detail while `@testable` tests can guard linear scanning.
    internal private(set) var newlineSearchBytesInspected: UInt64 = 0

    public init?(
        url: URL,
        startOffset: UInt64 = 0,
        startLine: Int = 1,
        chunkSize: Int = 64 * 1024,
        endOffsetExclusive: UInt64? = nil
    ) {
        guard chunkSize > 0,
              endOffsetExclusive.map({ $0 >= startOffset }) ?? true else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        try? handle.seek(toOffset: startOffset)
        self.url = url
        self.fileHandle = handle
        self.bufferStartOffset = startOffset
        self.nextLineNumber = startLine
        self.chunkSize = chunkSize
        self.endOffsetExclusive = endOffsetExclusive
        self.fileReadOffset = startOffset
        self.boundedEndReached = endOffsetExclusive == startOffset
    }

    deinit {
        try? fileHandle.close()
    }

    /// Byte offset of the next unread byte (the resume point).
    public var currentByteOffset: UInt64 { bufferStartOffset }

    /// Returns the next line, or nil at end of file. Throws on read errors.
    public func nextLine() throws -> JSONLLine? {
        while true {
            try Task.checkCancellation()
            if let line = takeLineFromPending() {
                return line
            }
            if eofReached {
                return flushPending()
            }
            // A bounded reader must never read through a very large line to
            // find its newline. Stop exactly at the requested byte boundary;
            // an unterminated tail at that boundary is intentionally omitted.
            if boundedEndReached {
                return nil
            }
            let readCount: Int
            if let endOffsetExclusive {
                let remaining = endOffsetExclusive - fileReadOffset
                guard remaining > 0 else {
                    boundedEndReached = true
                    continue
                }
                readCount = Int(min(UInt64(chunkSize), remaining))
            } else {
                readCount = chunkSize
            }
            let chunk = try fileHandle.read(upToCount: readCount) ?? Data()
            if chunk.isEmpty {
                eofReached = true
            } else {
                pending.append(chunk)
                fileReadOffset += UInt64(chunk.count)
                if let endOffsetExclusive, fileReadOffset >= endOffsetExclusive {
                    boundedEndReached = true
                }
            }
        }
    }

    private func takeLineFromPending() -> JSONLLine? {
        let searchLength = pending.count - newlineSearchIndex
        guard searchLength > 0 else { return nil }

        let searchStart = newlineSearchIndex
        let newlineIndex = pending.withUnsafeBytes { bytes -> Int? in
            guard let baseAddress = bytes.baseAddress,
                  let match = Darwin.memchr(
                    baseAddress.advanced(by: searchStart),
                    Int32(0x0A),
                    searchLength
                  ) else {
                return nil
            }
            return baseAddress.distance(to: UnsafeRawPointer(match))
        }

        guard let newlineIndex else {
            newlineSearchBytesInspected += UInt64(searchLength)
            newlineSearchIndex = pending.count
            return nil
        }
        newlineSearchBytesInspected += UInt64(newlineIndex - searchStart + 1)
        let lineData = pending[pendingStartIndex..<newlineIndex]
        let lineBytes = lineData.count
        let line = JSONLLine(
            byteOffset: bufferStartOffset,
            lineNumber: nextLineNumber,
            text: Self.decode(lineData)
        )
        pendingStartIndex = newlineIndex + 1
        newlineSearchIndex = pendingStartIndex
        compactIfNeeded()
        bufferStartOffset += UInt64(lineBytes + 1)
        nextLineNumber += 1
        return line
    }

    private func flushPending() -> JSONLLine? {
        guard pendingStartIndex < pending.count else { return nil }
        let text = Self.decode(pending[pendingStartIndex...])
        let count = pending.count - pendingStartIndex
        let line = JSONLLine(
            byteOffset: bufferStartOffset,
            lineNumber: nextLineNumber,
            text: text
        )
        pendingStartIndex = pending.count
        bufferStartOffset += UInt64(count)
        nextLineNumber += 1
        return line
    }

    /// Drops the already-consumed prefix once it reaches a chunk's worth of
    /// bytes, bounding `pending` while keeping line extraction O(1) amortized.
    private func compactIfNeeded() {
        if pendingStartIndex >= chunkSize {
            let removedBytes = pendingStartIndex
            pending.removeSubrange(0..<removedBytes)
            pendingStartIndex = 0
            newlineSearchIndex -= removedBytes
        }
    }

    /// Lossy UTF-8 decoding: an unreadable line still reaches the decoder,
    /// which records a malformed-JSON finding instead of aborting the file.
    private static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
