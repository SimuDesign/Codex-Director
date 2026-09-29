import Foundation

/// A minimal, transient projection of Codex's installed-plugin response.
/// The source path is used only to inspect an approved local package and must
/// never be written to Director's database, cache, logs, or capability pack.
public struct CodexInstalledPlugin: Sendable, Equatable {
    public let id: String
    public let name: String
    public let marketplace: String
    public let version: String?
    public let enabled: Bool
    public let sourcePath: String?

    public init(id: String, name: String, marketplace: String, version: String?, enabled: Bool, sourcePath: String?) {
        self.id = id
        self.name = name
        self.marketplace = marketplace
        self.version = version
        self.enabled = enabled
        self.sourcePath = sourcePath
    }
}

public struct CodexInstalledPluginInventory: Sendable, Equatable {
    public let plugins: [CodexInstalledPlugin]
    /// A successful JSON-RPC exchange alone is not proof of completeness:
    /// Codex can suppress remote-fetch errors and return local plugins only.
    public let isComplete: Bool
    public let issue: String?

    public init(plugins: [CodexInstalledPlugin], isComplete: Bool, issue: String? = nil) {
        self.plugins = plugins
        self.isComplete = isComplete
        self.issue = issue
    }
}

public protocol CodexInstalledPluginInventoryReading: Sendable {
    func read() async throws -> CodexInstalledPluginInventory
}

public enum CodexInstalledPluginReadError: Error, Equatable, Sendable {
    case unavailable
    case timedOut
    case cancelled
    case outputTooLarge
    case malformedResponse
    case protocolError
}

/// Reads only `plugin/installed` from a short-lived local Codex app-server.
/// No login, installation, removal, shell, or workspace path is involved.
public struct CodexInstalledPluginReading: CodexInstalledPluginInventoryReading, Sendable {
    public typealias Exchange = CodexAccountUsageReading.Exchange

    private let executableURL: URL?
    private let timeoutSeconds: TimeInterval
    private let maxOutputBytes: Int
    private let exchange: Exchange

    public init(executableURL: URL?, timeoutSeconds: TimeInterval = 30, maxOutputBytes: Int = 2 * 1024 * 1024) {
        self.executableURL = executableURL
        self.timeoutSeconds = max(0.1, timeoutSeconds)
        self.maxOutputBytes = max(1, maxOutputBytes)
        self.exchange = { url, request, timeout, limit in
            try await CodexAppServerProcess.exchange(executableURL: url, request: request, timeout: timeout, maxOutputBytes: limit)
        }
    }

    public init(
        transport: @escaping Exchange,
        executableURL: URL? = URL(fileURLWithPath: "/synthetic/codex"),
        timeoutSeconds: TimeInterval = 30,
        maxOutputBytes: Int = 2 * 1024 * 1024
    ) {
        self.executableURL = executableURL
        self.timeoutSeconds = max(0.1, timeoutSeconds)
        self.maxOutputBytes = max(1, maxOutputBytes)
        self.exchange = transport
    }

    public func read() async throws -> CodexInstalledPluginInventory {
        guard let executableURL else { throw CodexInstalledPluginReadError.unavailable }
        do {
            let response = try await exchange(executableURL, Self.requestPayload(), timeoutSeconds, maxOutputBytes)
            return try Self.parse(response: response, maxOutputBytes: maxOutputBytes)
        } catch let error as CodexInstalledPluginReadError {
            throw error
        } catch let error as CodexAccountUsageReadError {
            switch error {
            case .timedOut: throw CodexInstalledPluginReadError.timedOut
            case .cancelled: throw CodexInstalledPluginReadError.cancelled
            case .outputTooLarge: throw CodexInstalledPluginReadError.outputTooLarge
            case .protocolError, .malformedResponse: throw CodexInstalledPluginReadError.protocolError
            default: throw CodexInstalledPluginReadError.unavailable
            }
        } catch is CancellationError {
            throw CodexInstalledPluginReadError.cancelled
        } catch {
            throw CodexInstalledPluginReadError.unavailable
        }
    }

    public static func parse(response: Data, maxOutputBytes: Int = 2 * 1024 * 1024) throws -> CodexInstalledPluginInventory {
        guard response.count <= maxOutputBytes else { throw CodexInstalledPluginReadError.outputTooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw CodexInstalledPluginReadError.malformedResponse
        }
        if object["error"] != nil { throw CodexInstalledPluginReadError.protocolError }
        guard let result = object["result"] as? [String: Any],
              let marketplaces = result["marketplaces"] as? [[String: Any]],
              let loadErrors = result["marketplaceLoadErrors"] as? [Any] else {
            throw CodexInstalledPluginReadError.malformedResponse
        }

        var byID: [String: CodexInstalledPlugin] = [:]
        var remoteMarketplaceObserved = false
        var conflictingDuplicate = false
        for marketplace in marketplaces {
            guard let marketplaceName = marketplace["name"] as? String,
                  !marketplaceName.isEmpty,
                  let entries = marketplace["plugins"] as? [[String: Any]] else {
                throw CodexInstalledPluginReadError.malformedResponse
            }
            if marketplace["path"] == nil || marketplace["path"] is NSNull {
                remoteMarketplaceObserved = true
            }
            for entry in entries {
                guard let installed = entry["installed"] as? Bool,
                      let enabled = entry["enabled"] as? Bool,
                      let id = entry["id"] as? String,
                      let name = entry["name"] as? String,
                      !name.isEmpty,
                      id == name + "@" + marketplaceName else {
                    throw CodexInstalledPluginReadError.malformedResponse
                }
                guard installed else { continue }
                let version = (entry["localVersion"] as? String) ?? (entry["version"] as? String)
                let safeValues = [id, name, marketplaceName, version].compactMap { $0 }
                guard safeValues.allSatisfy({ !PersistenceAllowlist.containsForbiddenValue($0) }) else {
                    throw CodexInstalledPluginReadError.malformedResponse
                }
                let source = entry["source"] as? [String: Any]
                let sourcePath = source?["type"] as? String == "local" ? source?["path"] as? String : nil
                let plugin = CodexInstalledPlugin(
                    id: id, name: name, marketplace: marketplaceName,
                    version: version, enabled: enabled, sourcePath: sourcePath
                )
                if let prior = byID[id], prior != plugin {
                    conflictingDuplicate = true
                } else {
                    byID[id] = plugin
                }
            }
        }
        let plugins = byID.values.sorted { $0.id < $1.id }
        let issue: String? = if !loadErrors.isEmpty {
            "plugin_marketplace_partial"
        } else if conflictingDuplicate {
            "plugin_identity_conflict"
        } else if !remoteMarketplaceObserved {
            // The app-server currently swallows some remote-fetch failures and
            // returns a success-shaped local-only result. Without a remote
            // marketplace witness, even an empty list is not verified zero.
            "plugin_remote_unverified"
        } else {
            nil
        }
        return CodexInstalledPluginInventory(plugins: plugins, isComplete: issue == nil, issue: issue)
    }

    private static func requestPayload() -> Data {
        let messages: [[String: Any]] = [
            ["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "codex_director", "title": "Codex Director", "version": "1.4.1"],
                "capabilities": ["experimentalApi": true]
            ]],
            ["method": "initialized", "params": [:]],
            ["id": 2, "method": "plugin/installed", "params": [:]]
        ]
        return messages.reduce(into: Data()) { data, message in
            guard let line = try? JSONSerialization.data(withJSONObject: message) else { return }
            data.append(line)
            data.append(0x0A)
        }
    }
}
