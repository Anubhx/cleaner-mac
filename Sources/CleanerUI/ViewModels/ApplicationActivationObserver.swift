import Foundation
import AppKit
import os

internal final class ApplicationActivationObserver: Sendable {
    private struct Registration: @unchecked Sendable {
        let center: NotificationCenter
        let token: any NSObjectProtocol
    }

    private let registration = OSAllocatedUnfairLock<Registration?>(initialState: nil)

    init() {}

    deinit {
        invalidate()
    }

    func observeApplicationActivation(
        on notificationCenter: NotificationCenter,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        let token = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    handler()
                }
            } else {
                Task { @MainActor in
                    handler()
                }
            }
        }
        let next = Registration(center: notificationCenter, token: token)
        let previous = registration.withLock { current -> Registration? in
            let old = current
            current = next
            return old
        }
        if let previous {
            previous.center.removeObserver(previous.token)
        }
    }

    func invalidate() {
        let removed = registration.withLock { current -> Registration? in
            let old = current
            current = nil
            return old
        }
        if let removed {
            removed.center.removeObserver(removed.token)
        }
    }
}
