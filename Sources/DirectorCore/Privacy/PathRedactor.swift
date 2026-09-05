import Foundation

/// Converts absolute paths into privacy-safe display forms.
///
/// Applied to session working directories, error descriptions, accessibility
/// labels, and any surface that could expose the user's home path or username.
public struct PathRedactor: Sendable {

    public init() {}

    /// Replaces the home directory with `~`, including when the path is
    /// embedded inside a longer string such as an error description.
    public func redactHome(_ path: String, homeDirectory: String) -> String {
        guard !homeDirectory.isEmpty else { return path }
        if path == homeDirectory { return "~" }
        let marker = homeDirectory + "/"
        guard let range = path.range(of: marker) else { return path }
        return String(path[..<range.lowerBound]) + "~/" + String(path[range.upperBound...])
    }

    /// Removes a `/Users/<userName>` prefix (username removal), including when
    /// embedded inside a longer string.
    public func redactUser(_ path: String, userName: String) -> String {
        guard !userName.isEmpty else { return path }
        let marker = "/Users/\(userName)/"
        if path == "/Users/\(userName)" { return "~" }
        guard let range = path.range(of: marker) else { return path }
        return String(path[..<range.lowerBound]) + "~/" + String(path[range.upperBound...])
    }

    /// Applies home and username redaction.
    public func redact(_ path: String, homeDirectory: String, userName: String? = nil) -> String {
        var result = redactHome(path, homeDirectory: homeDirectory)
        if let userName {
            result = redactUser(result, userName: userName)
        }
        return result
    }

    /// True when the string still contains the user's name token.
    public func containsUserName(_ text: String, userName: String) -> Bool {
        guard !userName.isEmpty else { return false }
        return text.localizedCaseInsensitiveContains(userName)
    }
}
