import AppKit
import CoreText
import Foundation
import SwiftUI

public enum NotebookFontCatalog {
    public static let systemKey = "System"

    public static let curatedBaseFamilies: [String] = [
        systemKey,
        "Palatino",
        "Georgia",
        "Charter",
        "Iowan Old Style",
        "Menlo"
    ]

    public static func displayName(for family: String) -> String {
        family == systemKey ? "Sistem (SF Pro)" : family
    }

    /// Scans `~/Library/Fonts` via CoreText to surface user-downloaded fonts (e.g. Courier Prime) right at the top.
    public static func userInstalledFamilies() -> [String] {
        let fm = FileManager.default
        let userFontsURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Fonts", isDirectory: true)
        guard fm.fileExists(atPath: userFontsURL.path),
              let enumerator = fm.enumerator(
                at: userFontsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let fontExtensions: Set<String> = ["ttf", "otf", "ttc", "dfont"]
        var families: Set<String> = []

        for case let fileURL as URL in enumerator {
            guard fontExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            if let cfArray = CTFontManagerCreateFontDescriptorsFromURL(fileURL as CFURL) as? [CTFontDescriptor] {
                for desc in cfArray {
                    if let name = CTFontDescriptorCopyAttribute(desc, kCTFontFamilyNameAttribute) as? String,
                       !name.isEmpty,
                       !name.hasPrefix(".") {
                        families.insert(name)
                    }
                }
            }
        }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public static func availableCuratedFamilies() -> [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return curatedBaseFamilies.filter { $0 == systemKey || installed.contains($0) }
    }

    public static func otherSystemFamilies(excluding excluded: Set<String>) -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") && !excluded.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public static func nsFont(family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if family == systemKey || family.isEmpty {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        let traits: NSFontTraitMask = (weight.rawValue >= NSFont.Weight.semibold.rawValue) ? .boldFontMask : []
        let weightInt = (weight.rawValue >= NSFont.Weight.bold.rawValue) ? 9 : (weight.rawValue >= NSFont.Weight.semibold.rawValue ? 8 : 5)
        if let matched = NSFontManager.shared.font(withFamily: family, traits: traits, weight: weightInt, size: size) {
            return matched
        }
        if let direct = NSFont(name: family, size: size) {
            return direct
        }
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        if let fromDesc = NSFont(descriptor: descriptor, size: size) {
            return fromDesc
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    public static func swiftUIFont(family: String, size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if family == systemKey || family.isEmpty {
            return .system(size: size, weight: weight)
        }
        let nsWeight: NSFont.Weight
        switch weight {
        case .bold, .heavy, .black: nsWeight = .bold
        case .semibold, .medium: nsWeight = .semibold
        default: nsWeight = .regular
        }
        return Font(nsFont(family: family, size: size, weight: nsWeight))
    }
}
