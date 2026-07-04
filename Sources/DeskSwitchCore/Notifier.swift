import Foundation

public protocol Notifier {
    func notify(title: String, body: String)
}

/// Fallback notifier for CLI/serve contexts where UNUserNotificationCenter
/// is unavailable (requires an app bundle).
public struct StderrNotifier: Notifier {
    public init() {}
    public func notify(title: String, body: String) {
        FileHandle.standardError.write(Data("[\(title)] \(body)\n".utf8))
    }
}
