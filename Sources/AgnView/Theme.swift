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
