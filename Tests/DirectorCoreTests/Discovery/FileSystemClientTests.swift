import Darwin
import Foundation
import XCTest
@testable import DirectorCore

final class FileSystemClientTests: XCTestCase {
    func testProductionDirectoryTypeChecksAvoidFoundationAttributeDictionaries() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DirectorCore/Discovery/FileSystemClient.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let readStart = try XCTUnwrap(source.range(of: "private static func productionDirectoryRead"))
        let statusStart = try XCTUnwrap(source.range(of: "private static func productionDirectoryStatus"))
        let verifiedReadStart = try XCTUnwrap(source.range(of: "private static func productionVerifiedRead"))
        let directoryReadBody = source[readStart.lowerBound..<statusStart.lowerBound]
        let directoryStatusBody = source[statusStart.lowerBound..<verifiedReadStart.lowerBound]

        XCTAssertFalse(directoryReadBody.contains("attributesOfItem"))
        XCTAssertFalse(directoryStatusBody.contains("attributesOfItem"))
    }

    func testProductionDirectoryEnumerationUsesDescriptorBackedPOSIXOperations() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DirectorCore/Discovery/FileSystemClient.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let readStart = try XCTUnwrap(source.range(of: "private static func productionDirectoryRead"))
        let statusStart = try XCTUnwrap(source.range(of: "private static func productionDirectoryStatus"))
        let directoryReadBody = source[readStart.lowerBound..<statusStart.lowerBound]

        XCTAssertFalse(directoryReadBody.contains("contentsOfDirectory"))
        XCTAssertTrue(directoryReadBody.contains("O_DIRECTORY"))
        XCTAssertTrue(directoryReadBody.contains("O_NOFOLLOW"))
        XCTAssertTrue(directoryReadBody.contains("O_CLOEXEC"))
        XCTAssertTrue(directoryReadBody.contains("O_NONBLOCK"))
        XCTAssertTrue(directoryReadBody.contains("fdopendir"))
        XCTAssertTrue(directoryReadBody.contains("readdir"))
        XCTAssertTrue(directoryReadBody.contains("closedir"))
        XCTAssertTrue(directoryReadBody.contains("Darwin.close(descriptor)"))
        XCTAssertTrue(directoryReadBody.contains("Darwin.fstat"))
        XCTAssertTrue(directoryReadBody.contains("changedDuringRead"))
    }

    func testDirectoryOperationsClassifyDirectoryRegularFileAndMissingPath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        let regularFile = root.appendingPathComponent("regular.txt")
        let missing = root.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: directory.appendingPathComponent("child.txt"))
        try Data("fixture".utf8).write(to: regularFile)
        let client = FileSystemClient()

        guard case .success(let entries) = client.enumerateDirectory(directory) else {
            return XCTFail("Expected directory enumeration to succeed")
        }
        XCTAssertEqual(entries.map(\.lastPathComponent), ["child.txt"])
        XCTAssertEqual(client.directoryStatus(directory), .success(true))
        XCTAssertEqual(client.directoryStatus(regularFile), .success(false))
        XCTAssertEqual(client.enumerateDirectory(regularFile), .failure(.notDirectory))
        XCTAssertEqual(client.directoryStatus(missing), .failure(.notFound))
        XCTAssertEqual(client.enumerateDirectory(missing), .failure(.notFound))
    }

    func testDirectoryEnumerationRejectsNonFileURLWithoutReadingItsLocalPathComponent() throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://example.invalid/tmp"))

        XCTAssertEqual(
            FileSystemClient().enumerateDirectory(remoteURL),
            .failure(.enumerationFailed)
        )
    }

    func testDirectoryOperationsPreserveSymlinkBehavior() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        let regularFile = root.appendingPathComponent("regular.txt")
        let directoryLink = root.appendingPathComponent("directory-link")
        let fileLink = root.appendingPathComponent("file-link")
        let brokenLink = root.appendingPathComponent("broken-link")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: directory.appendingPathComponent("child.txt"))
        try Data("fixture".utf8).write(to: regularFile)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: regularFile)
        try FileManager.default.createSymbolicLink(
            at: brokenLink,
            withDestinationURL: root.appendingPathComponent("absent-target")
        )
        let client = FileSystemClient()

        // Directory status historically resolves symlinks, while directory
        // enumeration checks the link object itself before reading entries.
        XCTAssertEqual(client.directoryStatus(directoryLink), .success(true))
        XCTAssertEqual(client.enumerateDirectory(directoryLink), .failure(.notDirectory))
        XCTAssertEqual(client.directoryStatus(fileLink), .success(false))
        XCTAssertEqual(client.enumerateDirectory(fileLink), .failure(.notDirectory))
        XCTAssertEqual(client.directoryStatus(brokenLink), .success(false))
        XCTAssertEqual(client.enumerateDirectory(brokenLink), .failure(.notDirectory))
    }

    func testDirectoryEnumerationPreservesSpecialEntryNamesAndIncludesLinksWithoutFollowingThem() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expectedNames = [
            ".hidden",
            "Unicode-能力-🙂",
            "percent%name",
            "hash#name",
            "question?name",
            "brackets[name]",
            "plus+name",
            "space name",
            "semi;name",
            String(repeating: "x", count: 255),
        ]
        for name in expectedNames {
            try Data("fixture".utf8).write(to: directory.appendingPathComponent(name))
        }
        let childDirectory = directory.appendingPathComponent("child-directory", isDirectory: true)
        let childLink = directory.appendingPathComponent("Unicode-链接-🙂")
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: childLink, withDestinationURL: childDirectory)

        let client = FileSystemClient()
        let entries = try XCTUnwrap(client.enumerateDirectory(directory).successValue)
        let names = Set(entries.map(\.lastPathComponent))

        XCTAssertEqual(names, Set(expectedNames + ["child-directory", "Unicode-链接-🙂"]))
        XCTAssertFalse(names.contains("."))
        XCTAssertFalse(names.contains(".."))
        for entry in entries {
            XCTAssertEqual(
                entry.path,
                directory.appendingPathComponent(entry.lastPathComponent).path
            )
        }
        XCTAssertTrue(entries.first { $0.lastPathComponent == "child-directory" }?.hasDirectoryPath == true)
        XCTAssertFalse(entries.first { $0.lastPathComponent == "Unicode-链接-🙂" }?.hasDirectoryPath == true)
        XCTAssertEqual(client.directoryStatus(childLink), .success(true))
        XCTAssertEqual(client.enumerateDirectory(childLink), .failure(.notDirectory))
    }

    func testDirectoryEnumerationTreatsExistingBaseAsDirectoryRegardlessOfURLHintOrTrailingSlash() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("directory", isDirectory: true)
        let child = directory.appendingPathComponent("child%23-能力")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: child)
        let bases = [
            URL(fileURLWithPath: directory.path, isDirectory: false),
            URL(fileURLWithPath: directory.path + "/", isDirectory: true),
        ]
        let client = FileSystemClient()

        for base in bases {
            let entries = try XCTUnwrap(client.enumerateDirectory(base).successValue)
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.path, child.path)
            XCTAssertEqual(entries.first?.lastPathComponent, "child%23-能力")
        }
    }

    func testRepeatedDirectoryEnumerationClosesOwnedDescriptors() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("entry"))
        let client = FileSystemClient()
        let before = try openDescriptorCount()

        for _ in 0..<512 {
            guard case .success(let entries) = client.enumerateDirectory(root) else {
                return XCTFail("Expected repeated directory enumeration to succeed")
            }
            XCTAssertEqual(entries.count, 1)
        }

        let after = try openDescriptorCount()
        XCTAssertLessThanOrEqual(after, before + 2)
    }

    func testUnreadableDirectoryEnumerationFailsClosedWithTypedPermissionError() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("unreadable", isDirectory: true)
        let inaccessibleParent = root.appendingPathComponent("inaccessible-parent", isDirectory: true)
        let inaccessibleChild = inaccessibleParent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inaccessibleChild, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: directory.appendingPathComponent("child.txt"))
        XCTAssertEqual(Darwin.chmod(directory.path, 0), 0)
        XCTAssertEqual(Darwin.chmod(inaccessibleParent.path, 0), 0)
        defer {
            _ = Darwin.chmod(directory.path, S_IRWXU)
            _ = Darwin.chmod(inaccessibleParent.path, S_IRWXU)
        }

        let client = FileSystemClient()
        XCTAssertEqual(client.enumerateDirectory(directory), .failure(.permissionDenied))
        XCTAssertEqual(client.directoryStatus(inaccessibleChild), .failure(.permissionDenied))
        XCTAssertEqual(client.enumerateDirectory(inaccessibleChild), .failure(.permissionDenied))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("director-filesystem-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func openDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }
}

private extension Result {
    var successValue: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}
