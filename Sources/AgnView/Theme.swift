import SwiftUI
import UIKit

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    /// A colour that follows the light or dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

/// Palette, radii and spacing. Surfaces and text follow the system semantic
/// colours, so light and dark, Increase Contrast and grouped lists look native.
/// The status colours are tuned to meet WCAG AA (4.5:1) on those surfaces in
/// both appearances.
enum Theme {
    static let page = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let raised = Color(uiColor: .tertiarySystemFill)
    static let border = Color(uiColor: .separator)
    static let textMain = Color.primary
    /// Secondary text. The system secondary label drops under 4.5:1 on the
    /// grouped background in light mode, so this keeps a fixed pair.
    static let textSecondary = Color(light: 0x526071, dark: 0xADB7C6)
    /// The fill behind white button text.
    static let action = Color(light: 0x1D4ED8, dark: 0x2563EB)
    /// Tint for links, menus and text buttons on the page background.
    static let link = Color(light: 0x1D4ED8, dark: 0x60A5FA)
    static let success = Color(light: 0x047857, dark: 0x6EE7B7)
    static let warning = Color(light: 0x92400E, dark: 0xFCD34D)
    static let error = Color(light: 0xB91C1C, dark: 0xFCA5A5)

    // MARK: Approved design v4 palette

    /// Opaque fallback behind glass surfaces, and the hero button ring.
    static let glassSolid = Color(light: 0xFBFBFD, dark: 0x2A2A2D)
    static let glassLine = Color(light: 0xFFFFFF, dark: 0x3A3A3F)
    /// The Console canvas and its user bubble.
    static let chatBackground = Color(light: 0xFAF8F3, dark: 0x1A1918)
    static let bubble = Color(light: 0xECE6DC, dark: 0x35322E)
    static let bubbleText = Color(light: 0x1F1B16, dark: 0xF3EFE8)
    static let codeBackground = Color(light: 0xF3EFE7, dark: 0x242220)
    static let codeHeader = Color(light: 0xE9E3D8, dark: 0x2E2B28)
    static let codeLine = Color(light: 0xDDD5C7, dark: 0x3B3733)
    static let codeText = Color(light: 0x2A2621, dark: 0xEDE8DF)
    /// Fill behind an active tab and behind chips.
    static let chipFill = Color(uiColor: .tertiarySystemFill)
    /// The fill behind white text on the send button and the hero tab.
    static let accentFill = Color(light: 0x1D4ED8, dark: 0x3B6CF0)
    /// Accent text and outlines that meet 4.5:1 on the page and glass.
    static let accentText = Color(light: 0x1D4ED8, dark: 0x7EA6FF)

    static func agentColor(_ agent: String) -> Color {
        switch agent {
        case "claude_code": return Color(light: 0xC15F3C, dark: 0xE07A55)
        case "codex": return Color(light: 0x0E9170, dark: 0x2CC49A)
        case "antigravity": return Color(light: 0x1A73E8, dark: 0x5B9BFF)
        case "deepseek": return Color(light: 0x5B5BD6, dark: 0x8B8BFF)
        default: return textSecondary
        }
    }

    static func routeColor(_ route: Route) -> Color {
        switch route {
        case .lan: return Color(light: 0x16A34A, dark: 0x34D399)
        case .direct: return Color(light: 0x2563EB, dark: 0x60A5FA)
        case .relay: return Color(light: 0xC2570C, dark: 0xFB923C)
        case .offline: return Color(light: 0xDC2626, dark: 0xF87171)
        }
    }

    static let cardRadius: CGFloat = 12
    static let modalRadius: CGFloat = 16
    static let cardPadding: CGFloat = 16
    static let screenPadding: CGFloat = 16
    static let spacing: CGFloat = 12
    static let minTap: CGFloat = 44
}

/// The appearance choice stored in UserDefaults under the key "appearance".
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static func scheme(for stored: String) -> ColorScheme? {
        switch AppearanceChoice(rawValue: stored) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
