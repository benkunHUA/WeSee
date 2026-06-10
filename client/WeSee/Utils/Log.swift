import Foundation
import os

enum WeSeeLog {
    private static let base = OSLog(subsystem: "com.wesee", category: "general")

    private static func log(_ message: String, type: OSLogType = .default) {
        os_log(type, log: base, "%{public}@", message)
    }

    static func debug(_ message: String) {
        log("[DEBUG] \(message)", type: .debug)
    }

    static func info(_ message: String) {
        log("[INFO] \(message)", type: .info)
    }

    static func error(_ message: String) {
        log("[ERROR] \(message)", type: .error)
    }
}
