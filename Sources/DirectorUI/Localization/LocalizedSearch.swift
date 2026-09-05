import Foundation

/// Stable bilingual aliases for searchable Director-owned enum metadata.
/// Canonical raw values remain in the search haystack as required by the
/// evidence model.
public enum LocalizedSearch {
    public static func aliases(for rawValue: String) -> [String] {
        switch rawValue {
        case "agent", "Agent": return ["代理", "智能体"]
        case "skill", "Skill": return ["技能"]
        case "instruction", "Project Instructions": return ["项目说明", "项目指令"]
        case "workflow", "Workflow": return ["工作流"]
        case "tool", "Tool": return ["工具"]
        case "plugin", "Plugin", "Plugin Capabilities": return ["插件", "插件能力"]
        case "mcp", "MCP": return ["MCP"]
        case "app", "App": return ["应用", "App"]
        case "hook", "Hook": return ["钩子", "Hook"]
        case "output", "Output": return ["输出", "Output"]
        case "unknown", "Unknown": return ["未知"]
        case "userOwned": return ["用户拥有"]
        case "installed": return ["已安装"]
        case "builtIn", "Built-in": return ["内置"]
        case "pluginProvided": return ["插件提供"]
        case "codexSystem": return ["Codex 系统"]
        case "runtime": return ["运行时"]
        case "system": return ["系统"]
        case "global": return ["全局"]
        case "project", "Project": return ["项目"]
        case "observed", "Observed": return ["已观测", "已观察"]
        case "notObserved", "Not observed": return ["未观测", "未观察"]
        case "hasFailures", "Failures": return ["有失败", "失败"]
        case "evidenceLimited": return ["证据有限"]
        case "notEvaluated", "Not evaluated": return ["未评估"]
        case "github", "GitHub": return ["GitHub"]
        case "registry", "Registry": return ["注册源", "Registry"]
        case "local", "Local": return ["本地"]
        default: return []
        }
    }

    public static func haystack(_ values: [String]) -> String {
        values.flatMap { [$0] + aliases(for: $0) }.joined(separator: " ").lowercased()
    }
}
