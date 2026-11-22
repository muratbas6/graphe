import AppKit
import SwiftUI

public enum ReadingTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case original = "original"
    case sepia = "sepia"
    case softDark = "softDark"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .original: return "Orijinal"
        case .sepia: return "Sepya"
        case .softDark: return "Gece"
        }
    }

    public var systemImage: String {
        switch self {
        case .original: return "sun.max"
        case .sepia: return "book"
        case .softDark: return "moon.stars"
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .original: return nil
        case .sepia: return .light
        case .softDark: return .dark
        }
    }

    public var canvasBackgroundColor: NSColor {
        switch self {
        case .original:
            return NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(calibratedRed: 0.11, green: 0.115, blue: 0.13, alpha: 1.0)
                    : NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.969, alpha: 1.0)
            }
        case .sepia:
            return NSColor(calibratedRed: 0.937, green: 0.906, blue: 0.839, alpha: 1.0)
        case .softDark:
            return NSColor(calibratedRed: 0.098, green: 0.102, blue: 0.122, alpha: 1.0)
        }
    }

    /// Main workspace / window backdrop (Konsept A: #F6F6F7 / #EFE7D6 / #191A1F)
    public var windowBackground: Color {
        switch self {
        case .original:
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(calibratedRed: 0.11, green: 0.115, blue: 0.13, alpha: 1.0)
                    : NSColor(calibratedRed: 0.965, green: 0.965, blue: 0.969, alpha: 1.0)
            })
        case .sepia:
            return Color(red: 0.937, green: 0.906, blue: 0.839)
        case .softDark:
            return Color(red: 0.098, green: 0.102, blue: 0.122)
        }
    }

    /// Unified Warm Editorial chrome surface — sidebar, top bar, inspector header (#EFEFF1 / #E7DEC9 / #141519)
    public var chromeBackground: Color {
        switch self {
        case .original:
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(calibratedRed: 0.09, green: 0.095, blue: 0.11, alpha: 1.0)
                    : NSColor(calibratedRed: 0.937, green: 0.937, blue: 0.945, alpha: 1.0)
            })
        case .sepia:
            return Color(red: 0.906, green: 0.871, blue: 0.788)
        case .softDark:
            return Color(red: 0.078, green: 0.082, blue: 0.098)
        }
    }

    /// Elevated card / active tab / selected row surface (#FFFFFF / #F7F1E3 / #21232A)
    public var cardBackground: Color {
        switch self {
        case .original:
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(calibratedRed: 0.145, green: 0.153, blue: 0.18, alpha: 1.0)
                    : NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            })
        case .sepia:
            return Color(red: 0.969, green: 0.945, blue: 0.890)
        case .softDark:
            return Color(red: 0.129, green: 0.137, blue: 0.165)
        }
    }

    /// Warm reading/writing paper surface (#FCFCFD / #F5EEDB / #1D1F25)
    public var surfaceBackground: Color {
        switch self {
        case .original:
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(calibratedRed: 0.125, green: 0.132, blue: 0.155, alpha: 1.0)
                    : NSColor(calibratedRed: 0.988, green: 0.988, blue: 0.992, alpha: 1.0)
            })
        case .sepia:
            return Color(red: 0.961, green: 0.933, blue: 0.859)
        case .softDark:
            return Color(red: 0.114, green: 0.122, blue: 0.145)
        }
    }

    public var subtleBorder: Color {
        switch self {
        case .original:
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor.white.withAlphaComponent(0.09)
                    : NSColor(calibratedRed: 0.059, green: 0.090, blue: 0.165, alpha: 0.09)
            })
        case .sepia:
            return Color(red: 0.290, green: 0.224, blue: 0.141).opacity(0.13)
        case .softDark:
            return Color.white.opacity(0.09)
        }
    }

    public var primaryInk: Color {
        switch self {
        case .original:
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(calibratedRed: 0.918, green: 0.925, blue: 0.937, alpha: 1.0)
                    : NSColor(calibratedRed: 0.094, green: 0.094, blue: 0.106, alpha: 1.0)
            })
        case .sepia:
            return Color(red: 0.180, green: 0.145, blue: 0.102)
        case .softDark:
            return Color(red: 0.918, green: 0.925, blue: 0.937)
        }
    }

    public var secondaryInk: Color {
        switch self {
        case .original:
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(calibratedRed: 0.557, green: 0.584, blue: 0.647, alpha: 1.0)
                    : NSColor(calibratedRed: 0.392, green: 0.455, blue: 0.545, alpha: 1.0)
            })
        case .sepia:
            return Color(red: 0.471, green: 0.404, blue: 0.322)
        case .softDark:
            return Color(red: 0.557, green: 0.584, blue: 0.647)
        }
    }

    /// Theme-harmonized editorial accent (#2563EB / #A16207 / #60A5FA)
    public var accentColor: Color {
        switch self {
        case .original:
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(calibratedRed: 0.376, green: 0.647, blue: 0.980, alpha: 1.0)
                    : NSColor(calibratedRed: 0.145, green: 0.388, blue: 0.922, alpha: 1.0)
            })
        case .sepia:
            return Color(red: 0.631, green: 0.384, blue: 0.027)
        case .softDark:
            return Color(red: 0.376, green: 0.647, blue: 0.980)
        }
    }

    public var accentSoftBackground: Color {
        switch self {
        case .original:
            return accentColor.opacity(0.12)
        case .sepia:
            return accentColor.opacity(0.14)
        case .softDark:
            return accentColor.opacity(0.16)
        }
    }

    public var quoteAccentColor: Color {
        switch self {
        case .original:
            return Color(red: 0.851, green: 0.467, blue: 0.024)
        case .sepia:
            return Color(red: 0.706, green: 0.325, blue: 0.035)
        case .softDark:
            return Color(red: 0.961, green: 0.620, blue: 0.043)
        }
    }

    public var hoverFill: Color {
        switch self {
        case .original:
            return primaryInk.opacity(0.05)
        case .sepia:
            return Color(red: 0.290, green: 0.224, blue: 0.141).opacity(0.065)
        case .softDark:
            return Color.white.opacity(0.055)
        }
    }

    public var cardShadowColor: Color {
        switch self {
        case .original:
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor.black.withAlphaComponent(0.32)
                    : NSColor(calibratedRed: 0.059, green: 0.090, blue: 0.165, alpha: 0.06)
            })
        case .sepia:
            return Color(red: 0.267, green: 0.192, blue: 0.094).opacity(0.08)
        case .softDark:
            return Color.black.opacity(0.34)
        }
    }

    public var cardShadowRadius: CGFloat {
        switch self {
        case .original: return 6
        case .sepia: return 7
        case .softDark: return 10
        }
    }

    public var cardShadowY: CGFloat {
        switch self {
        case .original: return 2
        case .sepia: return 2
        case .softDark: return 3
        }
    }
}
