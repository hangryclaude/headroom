import AppKit

@main
struct Headroom {
    static func main() {
        // A headless verification path that needs neither a bundle nor a window
        // server, so the data layer can be proven without Xcode. See Probe.
        if CommandLine.arguments.contains("--probe") {
            Probe.run()
            return
        }

        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }

        if let i = CommandLine.arguments.firstIndex(of: "--vault") {
            VaultCLI.run(Array(CommandLine.arguments.dropFirst(i + 1)))
            return
        }

        if let i = CommandLine.arguments.firstIndex(of: "--devin") {
            DevinCLI.run(Array(CommandLine.arguments.dropFirst(i + 1)))
            return
        }

        if let i = CommandLine.arguments.firstIndex(of: "--icon"),
           let directory = CommandLine.arguments[safe: i + 1] {
            MainActor.assumeIsolated { IconRenderer.run(directory: directory) }
            return
        }

        if let i = CommandLine.arguments.firstIndex(of: "--render"),
           let directory = CommandLine.arguments[safe: i + 1] {
            MainActor.assumeIsolated { Render.run(directory: directory) }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

extension Array {
    /// Bounds-checked subscript, so a missing `--render` argument is a nil
    /// rather than a crash on the command line.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
