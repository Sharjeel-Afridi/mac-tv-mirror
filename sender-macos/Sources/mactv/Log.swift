import Foundation

enum Log {
    nonisolated(unsafe) static var verbose = false

    static func info(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    static func warn(_ message: String) {
        info("warning: " + message)
    }

    static func debug(_ message: String) {
        if verbose { info(message) }
    }
}
