import SwiftUI
import UIKit

/// The sizes of the approved floating tab bar. Points.
enum TabBarMetrics {
    static let barHeight: CGFloat = 62
    static let sideMargin: CGFloat = 20
    static let heroDiameter: CGFloat = 58
    /// How far the top of the hero circle sits above the top of the bar.
    static let heroRise: CGFloat = 16
    static let heroRing: CGFloat = 4
    static let heroBorder: CGFloat = 2

    /// The gap between the bar and the bottom edge of the screen. On a phone
    /// with a home indicator the bar sits close to the indicator.
    static func bottomGap(safeBottom: CGFloat) -> CGFloat {
        safeBottom > 20 ? max(safeBottom - 16, 12) : 12
    }

    /// The room content leaves at the bottom of the screen, counted from the
    /// screen edge: the gap, the bar, the raised hero and a little air.
    static func reserve(safeBottom: CGFloat) -> CGFloat {
        bottomGap(safeBottom: safeBottom) + barHeight + heroRise + heroRing + 6
    }

    /// The height of the inset a screen adds above its own bottom safe area.
    static func contentInset(safeBottom: CGFloat) -> CGFloat {
        max(0, reserve(safeBottom: safeBottom) - safeBottom)
    }
}

/// One tab as the bar and VoiceOver see it.
struct TabBarItem: Equatable, Identifiable {
    let screen: Screen
    /// One-based place from the left.
    let position: Int
    let count: Int

    var id: String { screen.rawValue }
    var identifier: String { "tab-" + screen.rawValue }
    var accessibilityLabel: String { screen.title }
    /// Spoken after the label: "tab 3 of 5".
    var accessibilityValue: String { "tab \(position) of \(count)" }
    var accessibilityHint: String { "Shows " + screen.title }
    var isHero: Bool { screen == .console }

    static func items(for order: [Screen] = Screen.phoneOrder) -> [TabBarItem] {
        order.enumerated().map { TabBarItem(screen: $1, position: $0 + 1, count: order.count) }
    }
}

/// The floating glass tab bar with the raised Console button in the centre.
/// The native TabView keeps each tab's stack and scroll position and its own
/// bar stays hidden. This bar replaces it and rebuilds what it gave: buttons
/// with labels, the selected trait, "tab N of 5", scroll to top on a second
/// tap and a solid look when Reduce Transparency is on.
struct FloatingTabBar: View {
    @Binding var selection: Screen
    let onReselect: (Screen) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 24
    @ScaledMetric(relativeTo: .caption) private var heroIconSize: CGFloat = 28

    private let items = TabBarItem.items()

    private var showLabels: Bool { !typeSize.isAccessibilitySize }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                if item.isHero {
                    heroButton(item)
                } else {
                    tabButton(item)
                }
            }
        }
        .frame(height: TabBarMetrics.barHeight)
        .glassSurface(Capsule())
        .padding(.horizontal, TabBarMetrics.sideMargin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab bar")
    }

    private func choose(_ item: TabBarItem) {
        if selection == item.screen {
            onReselect(item.screen)
        } else {
            selection = item.screen
        }
    }

    private func tabButton(_ item: TabBarItem) -> some View {
        let selected = selection == item.screen
        return Button {
            choose(item)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.screen.symbol)
                    .font(.system(size: iconSize, weight: .medium))
                    .frame(height: iconSize + 2)
                if showLabels {
                    Text(item.screen.title)
                        .font(.caption2.weight(selected ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .foregroundStyle(selected ? Theme.accentText : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(selected ? Theme.chipFill : Color.clear))
            .padding(.vertical, 5)
            .padding(.horizontal, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(TabAccessibility(item: item, selected: selected))
    }

    private func heroButton(_ item: TabBarItem) -> some View {
        let selected = selection == item.screen
        let hero = TabBarMetrics.heroDiameter
        return Button {
            choose(item)
        } label: {
            ZStack(alignment: .top) {
                ZStack {
                    Circle()
                        .fill(selected ? Theme.accentFill : Theme.glassSolid)
                    Circle()
                        .strokeBorder(selected ? Theme.accentFill : Theme.accentText,
                                      lineWidth: TabBarMetrics.heroBorder)
                    Image(systemName: item.screen.symbol)
                        .font(.system(size: heroIconSize, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Theme.accentText)
                }
                .frame(width: hero, height: hero)
                .padding(TabBarMetrics.heroRing)
                .background(Circle().fill(Theme.glassSolid))
                .shadow(color: Color.black.opacity(selected ? 0.28 : 0.18), radius: 8, x: 0, y: 5)
                .offset(y: -(TabBarMetrics.heroRise + TabBarMetrics.heroRing))
                if showLabels {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Text(item.screen.title)
                            .font(.caption2.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.accentText : Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.bottom, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(TabAccessibility(item: item, selected: selected))
    }
}

/// The accessibility of one tab: a button with a label, the position as its
/// value, a hint and the selected trait. Reading runs left to right.
private struct TabAccessibility: ViewModifier {
    let item: TabBarItem
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(item.accessibilityLabel)
            .accessibilityValue(item.accessibilityValue)
            .accessibilityHint(item.accessibilityHint)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
            .accessibilitySortPriority(Double(item.count - item.position))
            .accessibilityIdentifier(item.identifier)
    }
}

/// The bottom edge of the key window's safe area: the home indicator room.
enum SafeArea {
    static var bottom: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return window?.safeAreaInsets.bottom ?? 0
    }
}
