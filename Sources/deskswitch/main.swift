import Foundation

// App-bundle launch with no arguments (Finder, login item) → menu bar app.
// Anything else (terminal, swift run, explicit subcommand) → CLI.
if CommandLine.arguments.count <= 1 && Bundle.main.bundlePath.hasSuffix(".app") {
    DeskSwitchApp.main()
} else {
    DeskSwitchCLI.main()
}
