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

/// Palette, radii and spacing taken from the approved mockup.
enum Theme {
    static let page = Color(light: 0xF6F7F9, dark: 0x101216)
    static let surface = Color(light: 0xFFFFFF, dark: 0x191D24)
    static let raised = Color(light: 0xEEF1F5, dark: 0x242A34)
    static let border = Color(light: 0xD8DEE7, dark: 0x344050)
    static let textMain = Color(light: 0x18212F, dark: 0xF3F4F6)
    static let textSecondary = Color(light: 0x526071, dark: 0xADB7C6)
    static let action = Color(light: 0x1D4ED8, dark: 0x2563EB)
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
