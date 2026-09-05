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
    private let commandClient: any RuntimeCommandClient

    public init(commandClient: any RuntimeCommandClient) {
        self.commandClient = commandClient
    }

    public func inventory(at date: Date) async -> CapabilityPackagePluginList {
        do {
            let result = try await commandClient.run(arguments: ["plugin", "list", "--json"])
            guard result.exitCode == 0, !result.timedOut, let data = result.stdout.data(using: .utf8) else {
                return incomplete(at: date, issue: result.timedOut ? "plugin_query_timed_out" : "plugin_query_failed")
            }
            let decoded = try JSONDecoder().decode(RuntimePluginResponse.self, from: data)
            var omittedUnsafeMetadata = false
            let plugins = decoded.installed
                .filter(\.installed)
                .compactMap { plugin -> CapabilityPackagePlugin? in
                    let values = [plugin.pluginID, plugin.name, plugin.marketplaceName, plugin.version]
                        .compactMap { $0 }
                    guard values.allSatisfy({ !PersistenceAllowlist.containsForbiddenValue($0) }) else {
                        omittedUnsafeMetadata = true
                        return nil
                    }
                    let identifier = plugin.pluginID
                        ?? [plugin.name, plugin.marketplaceName].compactMap { $0 }.joined(separator: "@")
                    return CapabilityPackagePlugin(
                        identifier: identifier,
                        name: plugin.name,
                        marketplace: plugin.marketplaceName,
                        version: plugin.version,
                        enabled: plugin.enabled
                    )
                }
                .sorted {
                    if $0.identifier == $1.identifier { return $0.name < $1.name }
                    return $0.identifier < $1.identifier
                }
            return CapabilityPackagePluginList(
                status: omittedUnsafeMetadata ? .incomplete : .complete,
                generatedAt: date,
                plugins: plugins,
                issue: omittedUnsafeMetadata ? "unsafe_plugin_metadata_omitted" : nil
            )
        } catch {
            return incomplete(at: date, issue: "plugin_query_unavailable")
        }
    }

    private func incomplete(at date: Date, issue: String) -> CapabilityPackagePluginList {
        CapabilityPackagePluginList(status: .incomplete, generatedAt: date, plugins: [], issue: issue)
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
