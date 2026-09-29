import Foundation

public protocol CapabilityPluginInventoryProviding: Sendable {
    func inventory(at date: Date) async -> CapabilityPackagePluginList
}

/// Honest fallback used when no executable Codex runtime is available. An
/// unavailable query is never represented as a complete empty plugin list.
public struct UnavailableCapabilityPluginInventoryProvider: CapabilityPluginInventoryProviding, Sendable {
    private let issue: String

    public init(issue: String = "plugin_query_unavailable") {
        self.issue = issue
    }

    public func inventory(at date: Date) async -> CapabilityPackagePluginList {
        CapabilityPackagePluginList(
            status: .incomplete,
            generatedAt: date,
            plugins: [],
            issue: issue
        )
    }
}

public struct RuntimeCapabilityPluginInventoryProvider: CapabilityPluginInventoryProviding, Sendable {
    private let commandClient: (any RuntimeCommandClient)?
    private let installedPluginReading: (any CodexInstalledPluginInventoryReading)?

    public init(commandClient: any RuntimeCommandClient) {
        self.commandClient = commandClient
        self.installedPluginReading = nil
    }

    public init(installedPluginReading: any CodexInstalledPluginInventoryReading) {
        self.commandClient = nil
        self.installedPluginReading = installedPluginReading
    }

    public func inventory(at date: Date) async -> CapabilityPackagePluginList {
        if let installedPluginReading {
            do {
                let result = try await installedPluginReading.read()
                return packageList(
                    at: date,
                    entries: result.plugins.map { ($0.id, $0.name, $0.marketplace, $0.version, $0.enabled) },
                    complete: result.isComplete,
                    issue: result.issue
                )
            } catch let error as CodexInstalledPluginReadError {
                let issue: String
                switch error {
                case .timedOut: issue = "plugin_query_timed_out"
                case .cancelled: issue = "plugin_query_cancelled"
                case .outputTooLarge: issue = "plugin_query_output_too_large"
                case .malformedResponse, .protocolError: issue = "plugin_query_protocol_error"
                case .unavailable: issue = "plugin_query_unavailable"
                }
                return incomplete(at: date, issue: issue)
            } catch {
                return incomplete(at: date, issue: "plugin_query_unavailable")
            }
        }
        guard let commandClient else { return incomplete(at: date, issue: "plugin_query_unavailable") }
        do {
            let result = try await commandClient.run(arguments: ["plugin", "list", "--json"])
            guard result.exitCode == 0, !result.timedOut, !result.hadStderrOutput,
                  let data = result.stdout.data(using: .utf8) else {
                return incomplete(at: date, issue: result.timedOut ? "plugin_query_timed_out" : "plugin_query_failed")
            }
            let decoded = try JSONDecoder().decode(RuntimePluginResponse.self, from: data)
            return packageList(
                at: date,
                entries: decoded.installed.filter(\.installed).map { plugin in
                    (
                        plugin.pluginID ?? [plugin.name, plugin.marketplaceName].compactMap { $0 }.joined(separator: "@"),
                        plugin.name, plugin.marketplaceName, plugin.version, plugin.enabled
                    )
                },
                complete: true,
                issue: nil
            )
        } catch {
            return incomplete(at: date, issue: "plugin_query_unavailable")
        }
    }

    private func incomplete(at date: Date, issue: String) -> CapabilityPackagePluginList {
        CapabilityPackagePluginList(status: .incomplete, generatedAt: date, plugins: [], issue: issue)
    }

    private func packageList(
        at date: Date,
        entries: [(id: String, name: String, marketplace: String?, version: String?, enabled: Bool)],
        complete: Bool,
        issue: String?
    ) -> CapabilityPackagePluginList {
        var omittedUnsafeMetadata = false
        let plugins = entries.compactMap { entry -> CapabilityPackagePlugin? in
            let values = [entry.id, entry.name, entry.marketplace, entry.version].compactMap { $0 }
            guard values.allSatisfy({ !PersistenceAllowlist.containsForbiddenValue($0) }) else {
                omittedUnsafeMetadata = true
                return nil
            }
            return CapabilityPackagePlugin(
                identifier: entry.id,
                name: entry.name,
                marketplace: entry.marketplace,
                version: entry.version,
                enabled: entry.enabled
            )
        }.sorted {
            if $0.identifier == $1.identifier { return $0.name < $1.name }
            return $0.identifier < $1.identifier
        }
        return CapabilityPackagePluginList(
            status: complete && !omittedUnsafeMetadata ? .complete : .incomplete,
            generatedAt: date,
            plugins: plugins,
            issue: omittedUnsafeMetadata ? "unsafe_plugin_metadata_omitted" : issue
        )
    }
}

private struct RuntimePluginResponse: Decodable {
    let installed: [RuntimePlugin]
}

private struct RuntimePlugin: Decodable {
    let pluginID: String?
    let name: String
    let marketplaceName: String?
    let version: String?
    let installed: Bool
    let enabled: Bool
}
