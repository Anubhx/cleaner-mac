import Foundation
import AppKit
import os

internal final class ApplicationActivationObserver: Sendable {
    private struct Registration: @unchecked Sendable {
        let center: NotificationCenter
        let token: any NSObjectProtocol
    }

    private struct Registrations: Sendable {
        var activation: Registration?
        var termination: Registration?
    }

    private let registrations = OSAllocatedUnfairLock<Registrations>(initialState: Registrations())

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
        let previous = registrations.withLock { store -> Registration? in
            let old = store.activation
            store.activation = next
            return old
        }
        if let previous {
            previous.center.removeObserver(previous.token)
        }
    }

    func observeWillTerminate(
        on notificationCenter: NotificationCenter,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        let token = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    handler()
                }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        handler()
                    }
                }
            }
        }
        let next = Registration(center: notificationCenter, token: token)
        let previous = registrations.withLock { store -> Registration? in
            let old = store.termination
            store.termination = next
            return old
        }
        if let previous {
            previous.center.removeObserver(previous.token)
        }
    }

    func invalidate() {
        let removed = registrations.withLock { store -> Registrations in
            let old = store
            store = Registrations()
            return old
        }
        if let activation = removed.activation {
            activation.center.removeObserver(activation.token)
        }
        if let termination = removed.termination {
            termination.center.removeObserver(termination.token)
        }
    }
}
