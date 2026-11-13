import Foundation
import SwiftUI
import CleanerCore

public struct MultiSelectState: Sendable, Equatable {
    public private(set) var focusedID: UUID?
    public private(set) var highlightedIDs: Set<UUID> = []
    public private(set) var checkedIDs: Set<UUID> = []
    private var anchorID: UUID?

    public init() {}

    public mutating func handleClick(
        id: UUID,
        modifiers: EventModifiers,
        orderedIDs: [UUID]
    ) {
        focusedID = id

        if modifiers.contains(.shift),
           let anchorID,
           let startIndex = orderedIDs.firstIndex(of: anchorID),
           let endIndex = orderedIDs.firstIndex(of: id) {
            let range = min(startIndex, endIndex)...max(startIndex, endIndex)
            let rangeIDs = Set(orderedIDs[range])
            if modifiers.contains(.command) {
                highlightedIDs.formUnion(rangeIDs)
            } else {
                highlightedIDs = rangeIDs
            }
            return
        }

        if modifiers.contains(.command) {
            if highlightedIDs.contains(id) {
                highlightedIDs.remove(id)
            } else {
                highlightedIDs.insert(id)
            }
            anchorID = id
            return
        }

        highlightedIDs = [id]
        anchorID = id
    }

    public mutating func moveFocus(offset: Int, orderedIDs: [UUID], extendSelection: Bool) {
        guard !orderedIDs.isEmpty else { return }
        let currentIndex = focusedID.flatMap { orderedIDs.firstIndex(of: $0) } ?? 0
        let targetIndex = max(0, min(orderedIDs.count - 1, currentIndex + offset))
        let targetID = orderedIDs[targetIndex]
        let modifiers: EventModifiers = extendSelection ? [.shift] : []
        handleClick(id: targetID, modifiers: modifiers, orderedIDs: orderedIDs)
    }

    public mutating func toggleCheck(id: UUID) {
        if checkedIDs.contains(id) {
            checkedIDs.remove(id)
        } else {
            checkedIDs.insert(id)
        }
    }

    public mutating func toggleCheckedForHighlighted(items: [ScannedItem]) {
        let targets = items.filter { highlightedIDs.contains($0.id) && !$0.isRecommendedKeep }
        guard !targets.isEmpty else { return }
        let allCurrentlyChecked = targets.allSatisfy { checkedIDs.contains($0.id) }
        for item in targets {
            if allCurrentlyChecked {
                checkedIDs.remove(item.id)
            } else {
                checkedIDs.insert(item.id)
            }
        }
    }

    public mutating func selectAllEligible(in items: [ScannedItem]) {
        for item in items where !item.isRecommendedKeep {
            checkedIDs.insert(item.id)
        }
        highlightedIDs = Set(items.map(\.id))
    }

    public mutating func clearChecks(in items: [ScannedItem]) {
        let ids = Set(items.map(\.id))
        checkedIDs.subtract(ids)
    }

    public mutating func uncheck(ids: Set<UUID>) {
        checkedIDs.subtract(ids)
    }

    public mutating func pruneRemoved(validIDs: Set<UUID>) {
        checkedIDs = checkedIDs.intersection(validIDs)
        highlightedIDs = highlightedIDs.intersection(validIDs)
        if let focusedID, !validIDs.contains(focusedID) {
            self.focusedID = nil
        }
    }
}
