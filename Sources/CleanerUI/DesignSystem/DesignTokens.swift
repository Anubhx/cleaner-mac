import SwiftUI
import AppKit
import CleanerCore

public enum CleanerSpacing {
    public static let xxs: CGFloat = 4
    public static let xs: CGFloat = 8
    public static let sm: CGFloat = 12
    public static let md: CGFloat = 16
    public static let lg: CGFloat = 24
    public static let xl: CGFloat = 32
    public static let xxl: CGFloat = 40
}

public enum CleanerRadii {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let pill: CGFloat = 999
}

public enum CleanerTypography {
    public static func displayHero() -> Font {
        InstrumentSerifFontRegistrar.registerBundledFonts()
        return .custom("InstrumentSerif-Regular", size: 36, relativeTo: .largeTitle)
    }

    public static func titleLarge() -> Font {
        InstrumentSerifFontRegistrar.registerBundledFonts()
        return .custom("InstrumentSerif-Regular", size: 28, relativeTo: .title)
    }

    public static func titleSection() -> Font {
        InstrumentSerifFontRegistrar.registerBundledFonts()
        return .custom("InstrumentSerif-Regular", size: 21, relativeTo: .title2)
    }

    public static func titleItalic() -> Font {
        InstrumentSerifFontRegistrar.registerBundledFonts()
        return .custom("InstrumentSerif-Italic", size: 21, relativeTo: .title2)
    }

    public static let headline: Font = .system(.headline)
    public static let body: Font = .system(.body)
    public static let callout: Font = .system(.callout, weight: .medium)
    public static let caption: Font = .system(.caption)
    public static let monoMetric: Font = .system(.callout, design: .monospaced).monospacedDigit()
    public static let monoPath: Font = .system(.caption, design: .monospaced)
}

public enum CleanerColors {
    public static let cardFill = Color.primary.opacity(0.045)
    public static let hairline = Color.primary.opacity(0.11)

    public static let safe = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.28, green: 0.78, blue: 0.56, alpha: 1.0)
            : NSColor(red: 0.12, green: 0.50, blue: 0.36, alpha: 1.0)
    })

    public static let caution = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1.0)
            : NSColor(red: 0.70, green: 0.37, blue: 0.04, alpha: 1.0)
    })

    public static let danger = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1.0)
            : NSColor(red: 0.78, green: 0.16, blue: 0.16, alpha: 1.0)
    })

    public static func color(for risk: RiskLevel) -> Color {
        switch risk {
        case .low: safe
        case .moderate: caution
        case .high: danger
        }
    }
}

public enum CleanerMotion {
    public static func standard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)
    }

    public static func subtleFade(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.18)
    }
}

public struct WrappingFlowLayout: Layout {
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat

    public init(horizontalSpacing: CGFloat = CleanerSpacing.xs, verticalSpacing: CGFloat = CleanerSpacing.xs) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = arrangeRows(maxWidth: maxWidth, subviews: subviews)
        let totalHeight = rows.reduce(CGFloat.zero) { partial, row in
            partial + row.height
        } + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        let totalWidth = proposal.width ?? rows.map(\.width).max() ?? 0
        return CGSize(width: totalWidth, height: totalHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let yOffset = y + (row.height - item.size.height) / 2
                item.subview.place(
                    at: CGPoint(x: x, y: yOffset),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrangeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let neededWidth = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if !current.items.isEmpty && neededWidth > maxWidth {
                rows.append(current)
                current = Row(
                    items: [RowItem(subview: subview, size: size)],
                    width: size.width,
                    height: size.height
                )
            } else {
                current.items.append(RowItem(subview: subview, size: size))
                current.width = neededWidth
                current.height = max(current.height, size.height)
            }
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

public struct AdaptiveRowLayout: Layout {
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat
    public var stackedTrailingAlignment: HorizontalAlignment

    public init(
        horizontalSpacing: CGFloat = CleanerSpacing.sm,
        verticalSpacing: CGFloat = CleanerSpacing.xs,
        stackedTrailingAlignment: HorizontalAlignment = .trailing
    ) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.stackedTrailingAlignment = stackedTrailingAlignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        if subviews.count == 1 {
            return subviews[0].sizeThatFits(proposal)
        }

        let leading = subviews[0]
        let trailing = subviews[1]
        let trailingIdeal = trailing.sizeThatFits(.unspecified)

        guard let availableWidth = proposal.width else {
            let leadingIdeal = leading.sizeThatFits(.unspecified)
            return CGSize(
                width: leadingIdeal.width + horizontalSpacing + trailingIdeal.width,
                height: max(leadingIdeal.height, trailingIdeal.height)
            )
        }

        if availableWidth.isFinite {
            let leadingIdeal = leading.sizeThatFits(.unspecified)
            if leadingIdeal.width + horizontalSpacing + trailingIdeal.width <= availableWidth {
                let leadingWidth = max(0, availableWidth - horizontalSpacing - trailingIdeal.width)
                let leadingSize = leading.sizeThatFits(ProposedViewSize(width: leadingWidth, height: nil))
                return CGSize(
                    width: availableWidth,
                    height: max(leadingSize.height, trailingIdeal.height)
                )
            } else {
                let leadingSize = leading.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
                let trailingSize = trailing.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
                let width = max(availableWidth, max(leadingSize.width, trailingSize.width))
                return CGSize(
                    width: width,
                    height: leadingSize.height + verticalSpacing + trailingSize.height
                )
            }
        } else {
            let leadingIdeal = leading.sizeThatFits(.unspecified)
            return CGSize(
                width: leadingIdeal.width + horizontalSpacing + trailingIdeal.width,
                height: max(leadingIdeal.height, trailingIdeal.height)
            )
        }
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        if subviews.count == 1 {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
            return
        }

        let leading = subviews[0]
        let trailing = subviews[1]
        let leadingIdeal = leading.sizeThatFits(.unspecified)
        let trailingIdeal = trailing.sizeThatFits(.unspecified)

        if leadingIdeal.width + horizontalSpacing + trailingIdeal.width <= bounds.width {
            let leadingWidth = max(0, bounds.width - horizontalSpacing - trailingIdeal.width)
            let leadingSize = leading.sizeThatFits(ProposedViewSize(width: leadingWidth, height: nil))
            let rowHeight = max(leadingSize.height, trailingIdeal.height)

            leading.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + (rowHeight - leadingSize.height) / 2),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: leadingWidth, height: leadingSize.height)
            )
            trailing.place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + (rowHeight - trailingIdeal.height) / 2),
                anchor: .topTrailing,
                proposal: ProposedViewSize(trailingIdeal)
            )
        } else {
            let leadingSize = leading.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            let trailingSize = trailing.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))

            leading.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: leadingSize.height)
            )

            let trailingY = bounds.minY + leadingSize.height + verticalSpacing
            if stackedTrailingAlignment == .leading {
                trailing.place(
                    at: CGPoint(x: bounds.minX, y: trailingY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: trailingSize.height)
                )
            } else {
                trailing.place(
                    at: CGPoint(x: bounds.maxX, y: trailingY),
                    anchor: .topTrailing,
                    proposal: ProposedViewSize(width: min(bounds.width, trailingSize.width), height: trailingSize.height)
                )
            }
        }
    }
}
