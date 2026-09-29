import Foundation
import XCTest
@testable import DirectorCore

final class CodexInstalledPluginReadingTests: XCTestCase {
    private func response(marketplaces: [[String: Any]], errors: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": 2,
            "result": ["marketplaces": marketplaces, "marketplaceLoadErrors": errors]
        ])
    }

    private func plugin(
        id: String = "alpha@remote-catalog",
        name: String = "alpha",
        installed: Bool = true,
        enabled: Bool = true,
        source: [String: Any] = ["type": "remote"]
    ) -> [String: Any] {
        ["id": id, "name": name, "installed": installed, "enabled": enabled,
         "version": "2.0.0", "source": source,
         "remotePluginId": "private-account-id", "shareContext": ["creatorName": "private-person"]]
    }

    func testInstalledRemoteMarketplaceProducesVerifiedCanonicalInventory() throws {
        let data = try response(marketplaces: [[
            "name": "remote-catalog", "path": NSNull(),
            "plugins": [plugin(), plugin(id: "beta@remote-catalog", name: "beta", enabled: false)]
        ]])
        let result = try CodexInstalledPluginReading.parse(response: data)
        XCTAssertTrue(result.isComplete)
        XCTAssertNil(result.issue)
        XCTAssertEqual(result.plugins.map(\.id), ["alpha@remote-catalog", "beta@remote-catalog"])
        XCTAssertEqual(result.plugins.map(\.enabled), [true, false])
        XCTAssertEqual(result.plugins.first?.version, "2.0.0")
        XCTAssertNil(result.plugins.first?.sourcePath)
        XCTAssertFalse(String(describing: result).contains("private-account-id"))
        XCTAssertFalse(String(describing: result).contains("private-person"))
    }

    func testRemoteMarketplaceCanVerifyExplicitEmptyInventory() throws {
        let data = try response(marketplaces: [["name": "remote-catalog", "path": NSNull(), "plugins": []]])
        let result = try CodexInstalledPluginReading.parse(response: data)
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.plugins.isEmpty)
    }

    func testLocalOnlySuccessIsNotPromotedToComplete() throws {
        let data = try response(marketplaces: [[
            "name": "local-market", "path": "/synthetic/marketplace.json",
            "plugins": [plugin(id: "alpha@local-market", source: ["type": "local", "path": "/synthetic/plugin"])]
        ]])
        let result = try CodexInstalledPluginReading.parse(response: data)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.issue, "plugin_remote_unverified")
        XCTAssertEqual(result.plugins.first?.sourcePath, "/synthetic/plugin")
    }

    func testMarketplaceLoadErrorMakesRemoteResultIncomplete() throws {
        let data = try response(
            marketplaces: [["name": "remote-catalog", "path": NSNull(), "plugins": [plugin()]]],
            errors: [["marketplacePath": "/synthetic/private", "message": "private raw error"]]
        )
        let result = try CodexInstalledPluginReading.parse(response: data)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.issue, "plugin_marketplace_partial")
        XCTAssertFalse(String(describing: result).contains("private raw error"))
    }

    func testDuplicateCanonicalIDWithDifferentValuesIsIncomplete() throws {
        let data = try response(marketplaces: [[
            "name": "remote-catalog", "path": NSNull(),
            "plugins": [plugin(), plugin(enabled: false)]
        ]])
        let result = try CodexInstalledPluginReading.parse(response: data)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.issue, "plugin_identity_conflict")
        XCTAssertEqual(result.plugins.count, 1)
    }

    func testSameNameDifferentMarketplaceRemainsTwoPlugins() throws {
        let data = try response(marketplaces: [
            ["name": "remote-catalog", "path": NSNull(), "plugins": [plugin()]],
            ["name": "local-market", "path": "/synthetic/marketplace.json",
             "plugins": [plugin(id: "alpha@local-market", source: ["type": "local", "path": "/synthetic/plugin"])]]
        ])
        let result = try CodexInstalledPluginReading.parse(response: data)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.plugins.map(\.id), ["alpha@local-market", "alpha@remote-catalog"])
    }

    func testMalformedFieldsAndProtocolErrorAreNotEmptyLists() throws {
        let missingInstalled = try response(marketplaces: [[
            "name": "remote-catalog", "path": NSNull(),
            "plugins": [["id": "alpha@remote-catalog", "name": "alpha", "enabled": true]]
        ]])
        XCTAssertThrowsError(try CodexInstalledPluginReading.parse(response: missingInstalled)) { error in
            XCTAssertEqual(error as? CodexInstalledPluginReadError, .malformedResponse)
        }
        let protocolError = try JSONSerialization.data(withJSONObject: ["id": 2, "error": ["code": -32601, "message": "private detail"]])
        XCTAssertThrowsError(try CodexInstalledPluginReading.parse(response: protocolError)) { error in
            XCTAssertEqual(error as? CodexInstalledPluginReadError, .protocolError)
        }
    }

    func testUnsafePluginMetadataAndOversizedResponseAreRejected() throws {
        let unsafe = try response(marketplaces: [[
            "name": "remote-catalog", "path": NSNull(),
            "plugins": [plugin(id: "/Users/example/private@remote-catalog", name: "/Users/example/private")]
        ]])
        XCTAssertThrowsError(try CodexInstalledPluginReading.parse(response: unsafe)) { error in
            XCTAssertEqual(error as? CodexInstalledPluginReadError, .malformedResponse)
        }
        let valid = try response(marketplaces: [["name": "remote-catalog", "path": NSNull(), "plugins": [plugin()]]])
        XCTAssertThrowsError(try CodexInstalledPluginReading.parse(response: valid, maxOutputBytes: valid.count - 1)) { error in
            XCTAssertEqual(error as? CodexInstalledPluginReadError, .outputTooLarge)
        }
    }

    func testTransportUsesOnlyInstalledReadAndMapsTimeout() async throws {
        let data = try response(marketplaces: [["name": "remote-catalog", "path": NSNull(), "plugins": [plugin()]]])
        let reader = CodexInstalledPluginReading(transport: { _, request, _, _ in
            let messages = request.split(separator: 0x0A).compactMap {
                try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
            }
            XCTAssertEqual(messages.compactMap { $0["method"] as? String }, ["initialize", "initialized", "plugin/installed"])
            XCTAssertEqual((messages.last?["params"] as? [String: Any])?.count, 0)
            return data
        })
        let inventory = try await reader.read()
        XCTAssertEqual(inventory.plugins.count, 1)

        let timedOut = CodexInstalledPluginReading(transport: { _, _, _, _ in
            throw CodexAccountUsageReadError.timedOut
        })
        do {
            _ = try await timedOut.read()
            XCTFail("A timeout must not become an empty plugin list")
        } catch let error as CodexInstalledPluginReadError {
            XCTAssertEqual(error, .timedOut)
        }

        let cancelled = CodexInstalledPluginReading(transport: { _, _, _, _ in
            throw CodexAccountUsageReadError.cancelled
        })
        do {
            _ = try await cancelled.read()
            XCTFail("Cancellation must not become an empty plugin list")
        } catch let error as CodexInstalledPluginReadError {
            XCTAssertEqual(error, .cancelled)
        }
    }
}
