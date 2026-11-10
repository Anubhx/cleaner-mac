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

private struct ReduceTransparencyOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    var cleanerReduceTransparencyOverride: Bool? {
        get { self[ReduceTransparencyOverrideKey.self] }
        set { self[ReduceTransparencyOverrideKey.self] = newValue }
    }
}

private struct CleanerMaterialSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.cleanerReduceTransparencyOverride) private var overrideReduceTransparency
    let material: Material
    let fallback: Color

    func body(content: Content) -> some View {
        if overrideReduceTransparency ?? systemReduceTransparency {
            content.background(fallback)
        } else {
            content.background(material)
        }
    }
}

private struct CleanerMaterialShapeModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.cleanerReduceTransparencyOverride) private var overrideReduceTransparency
    let material: Material
    let shape: S
    let fallback: Color

    func body(content: Content) -> some View {
        if overrideReduceTransparency ?? systemReduceTransparency {
            content.background(fallback, in: shape)
        } else {
            content.background(material, in: shape)
        }
    }
}

public extension View {
    func cleanerMaterial(
        _ material: Material,
        fallback: Color = Color(nsColor: .windowBackgroundColor)
    ) -> some View {
        modifier(CleanerMaterialSurfaceModifier(material: material, fallback: fallback))
    }

    func cleanerMaterial<S: Shape>(
        _ material: Material,
        in shape: S,
        fallback: Color = Color(nsColor: .controlBackgroundColor)
    ) -> some View {
        modifier(CleanerMaterialShapeModifier(material: material, shape: shape, fallback: fallback))
    }
}
