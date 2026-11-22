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
            return NSColor(calibratedWhite: 0.94, alpha: 1.0)
        case .sepia:
            return NSColor(calibratedRed: 0.93, green: 0.89, blue: 0.80, alpha: 1.0)
        case .softDark:
            return NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.12, alpha: 1.0)
        }
    }

    /// Unified Zen chrome surface (sidebar, inspector header, compact bars)
    public var chromeBackground: Color {
        switch self {
        case .original:
            return Color(nsColor: .windowBackgroundColor)
        case .sepia:
            return Color(red: 0.93, green: 0.89, blue: 0.81)
        case .softDark:
            return Color(red: 0.10, green: 0.105, blue: 0.115)
        }
    }

    /// Unified Zen reading/writing paper surface
    public var surfaceBackground: Color {
        switch self {
        case .original:
            return Color(nsColor: .textBackgroundColor)
        case .sepia:
            return Color(red: 0.96, green: 0.92, blue: 0.84)
        case .softDark:
            return Color(red: 0.115, green: 0.12, blue: 0.13)
        }
    }

    public var subtleBorder: Color {
        switch self {
        case .original:
            return Color.primary.opacity(0.08)
        case .sepia:
            return Color(red: 0.42, green: 0.33, blue: 0.22).opacity(0.14)
        case .softDark:
            return Color.white.opacity(0.07)
        }
    }

    public var primaryInk: Color {
        switch self {
        case .original:
            return .primary
        case .sepia:
            return Color(red: 0.21, green: 0.16, blue: 0.11)
        case .softDark:
            return Color(red: 0.89, green: 0.90, blue: 0.92)
        }
    }

    public var secondaryInk: Color {
        switch self {
        case .original:
            return .secondary
        case .sepia:
            return Color(red: 0.44, green: 0.36, blue: 0.27)
        case .softDark:
            return Color(red: 0.56, green: 0.58, blue: 0.62)
        }
    }
}
