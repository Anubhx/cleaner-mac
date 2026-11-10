import Foundation
import CoreText

public enum InstrumentSerifFontRegistrar {
    private static let registerOnce: Void = {
        let fontNames = [
            "InstrumentSerif-Regular",
            "InstrumentSerif-Italic",
        ]

        for name in fontNames {
            if let mainURL = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(mainURL as CFURL, .process, nil)
                continue
            }
            if let moduleURL = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(moduleURL as CFURL, .process, nil)
            }
        }
    }()

    public static func registerBundledFonts() {
        _ = registerOnce
    }
}
