import Foundation

public struct HardLinkTracker: Sendable {
    private var seen: Set<InodeIdentity> = []

    public init() {}

    public var trackedCount: Int { seen.count }

    public mutating func registerIfFirstSighting(of identity: InodeIdentity?) -> Bool {
        guard let identity else { return true }
        return seen.insert(identity).inserted
    }
}

