import Foundation

/// Pure logic behind the CLI subcommands, kept in Core so it is unit-testable.
public enum CommandCore {
    public static func applyProbe(readings: [String: UInt16], config: Config) -> Config {
        var updated = config
        for (name, code) in readings {
            var monitor = updated.monitors[name] ?? Config.Monitor(inputs: [:])
            monitor.inputs[updated.machineName] = code
            updated.monitors[name] = monitor
        }
        return updated
    }

    public static func probeText(readings: [String: UInt16], machine: String) -> String {
        readings.keys.sorted()
            .map { "\($0): recorded input \(readings[$0]!) for \(machine)" }
            .joined(separator: "\n")
    }

    public static func statusText(local: LocalStatus, peer: LocalStatus?) -> String {
        var lines = section(for: local)
        if let peer {
            lines += section(for: peer)
        } else {
            lines.append("[peer] unreachable")
        }
        return lines.joined(separator: "\n")
    }

    private static func section(for status: LocalStatus) -> [String] {
        var lines = ["[\(status.machine)]"]
        if status.monitors.isEmpty {
            lines.append("  drives no external displays")
        }
        lines += status.monitors.map { "  \($0.name): input \($0.inputCode) (\($0.owner ?? "unmapped"))" }
        return lines
    }
}
