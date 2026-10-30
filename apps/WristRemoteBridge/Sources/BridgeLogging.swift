import Foundation
import Network
import os

/// The bridge had no logging at all, so a failed bind could not be diagnosed
/// after the fact: the only copy of the error was the text in the window.
enum AppLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "org.example.wristremote.bridge"

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}

/// A bind failure is shown in the window verbatim, and `NWError 48` says nothing
/// about which port collided or what to do about it.
enum ListenFailure {
    static func describe(_ error: Error, port: UInt16) -> String {
        if let networkError = error as? NWError,
           case let .posix(code) = networkError,
           code == .EADDRINUSE {
            if port == 60_928 { return "端口 \(port) 已被占用：请检查占用后重新启动腕上遥控桥。" }
            return "端口 \(port) 已被占用：可能另一个腕上遥控桥还在退出，或别的程序占用了它。会自动重试。"
        }
        return error.localizedDescription
    }
}
