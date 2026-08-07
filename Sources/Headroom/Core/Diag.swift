import Foundation

/// Unbuffered progress output. `print` to a pipe is block-buffered, which hides
/// exactly the progress you need when something is hanging.
enum Diag {
    static let enabled = ProcessInfo.processInfo.environment["HEADROOM_DEBUG"] != nil

    static func log(_ message: String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
