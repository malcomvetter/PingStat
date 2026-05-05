import AppKit
import Foundation
import os

/// Best-effort guards for process-level issues (Objective‑C exceptions). Swift traps (e.g. force unwrap)
/// cannot be caught here; those are prevented by defensive coding elsewhere.
///
/// The handler must not capture external state (C function pointer requirement).
enum AppResilience {
    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(16).joined(separator: " │ ")
            let msg =
                "event=uncaught_ns_exception name=\(exception.name.rawValue) reason=\(exception.reason ?? "nil") stacksample=\(stack)"
            NSLog("%@", msg)
            fputs("\(msg)\n", stderr)
            let log = Logger(subsystem: AppVersion.loggingSubsystem, category: LogCategory.errors.rawValue)
            log.fault("\(msg, privacy: .public)")
        }
    }
}
