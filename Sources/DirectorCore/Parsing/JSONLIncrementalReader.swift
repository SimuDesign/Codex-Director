import Foundation

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
/// Reads bounded chunks and splits on newlines, so arbitrarily large files
/// and very long lines never load the whole file into memory. Supports
/// resuming from a byte offset without re-reading earlier bytes (the caller
/// commits the last processed offset as a checkpoint).
public final class JSONLIncrementalReader: @unchecked Sendable {
    public let url: URL

    private let fileHandle: FileHandle
    private var pending = Data()
    /// Index in `pending` of the first unconsumed byte. Slicing from this
    /// cursor instead of removing the consumed prefix keeps line extraction
    /// amortized O(line length); the buffer is compacted once the cursor
    /// passes a chunk's worth of consumed bytes.
    private var pendingStartIndex = 0
    private var bufferStartOffset: UInt64
    private var nextLineNumber: Int
    private let chunkSize: Int
    private var eofReached = false

    public init?(url: URL, startOffset: UInt64 = 0, startLine: Int = 1, chunkSize: Int = 64 * 1024) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        try? handle.seek(toOffset: startOffset)
        self.url = url
        self.fileHandle = handle
        self.bufferStartOffset = startOffset
        self.nextLineNumber = startLine
        self.chunkSize = chunkSize
    }

    deinit {
        try? fileHandle.close()
    }

    /// Byte offset of the next unread byte (the resume point).
    public var currentByteOffset: UInt64 { bufferStartOffset }

    /// Returns the next line, or nil at end of file. Throws on read errors.
    public func nextLine() throws -> JSONLLine? {
        while true {
            if let line = takeLineFromPending() {
                return line
            }
            if eofReached {
                return flushPending()
            }
            let chunk = try fileHandle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                eofReached = true
            } else {
                pending.append(chunk)
            }
        }
    }

    private func takeLineFromPending() -> JSONLLine? {
        // ArraySlice indices are shared with `pending`, so the found index
        // is valid for slicing the base buffer directly.
        guard let newlineIndex = pending[pendingStartIndex...].firstIndex(of: 0x0A) else { return nil }
        let lineData = pending[pendingStartIndex..<newlineIndex]
        let lineBytes = lineData.count
        let line = JSONLLine(
            byteOffset: bufferStartOffset,
            lineNumber: nextLineNumber,
            text: Self.decode(lineData)
        )
        pendingStartIndex = newlineIndex + 1
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
            pending.removeSubrange(0..<pendingStartIndex)
            pendingStartIndex = 0
        }
    }

    /// Lossy UTF-8 decoding: an unreadable line still reaches the decoder,
    /// which records a malformed-JSON finding instead of aborting the file.
    private static func decode(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }
}
