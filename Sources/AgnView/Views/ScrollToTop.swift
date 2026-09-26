import SwiftUI
import UIKit

extension Notification.Name {
    /// Posted when the tab of the shown screen is tapped again. The user info
    /// carries the screen's raw value under "screen".
    static let agnViewScrollToTop = Notification.Name("agnview.scrollToTop")
}

enum ScrollToTop {
    static let screenKey = "screen"

    /// Asks the given screen to scroll back to its top.
    static func post(_ screen: Screen) {
        NotificationCenter.default.post(name: .agnViewScrollToTop, object: nil,
                                        userInfo: [screenKey: screen.rawValue])
    }

    /// True when the notification is meant for the screen.
    static func matches(_ note: Notification, screen: Screen) -> Bool {
        (note.userInfo?[screenKey] as? String) == screen.rawValue
    }
}

/// Finds the scroll view under a helper view and moves it to its top. A List, a
/// Form and a ScrollView are all scroll views underneath, so one helper serves
/// every screen. Text views are skipped: they scroll their own text.
struct ScrollToTopHelper: UIViewRepresentable {
    let token: Int

    final class Coordinator {
        var lastToken = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard token != context.coordinator.lastToken else { return }
        context.coordinator.lastToken = token
        DispatchQueue.main.async { Self.scrollToTop(near: uiView) }
    }

    private static func scrollToTop(near helper: UIView) {
        guard let window = helper.window else { return }
        let point = helper.convert(CGPoint(x: helper.bounds.midX, y: helper.bounds.midY), to: nil)
        var found: [UIScrollView] = []
        collect(in: window, into: &found)
        let candidates = found.filter { scroll in
            !(scroll is UITextView)
                && scroll.window != nil
                && scroll.convert(scroll.bounds, to: nil).contains(point)
        }
        let best = candidates.max { lhs, rhs in
            lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
        guard let scroll = best else { return }
        let top = -scroll.adjustedContentInset.top
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: top), animated: true)
    }

    private static func collect(in view: UIView, into result: inout [UIScrollView]) {
        if let scroll = view as? UIScrollView, !scroll.isHidden { result.append(scroll) }
        for sub in view.subviews where !sub.isHidden {
            collect(in: sub, into: &result)
        }
    }
}

private struct ScrollsToTopOnTabTap: ViewModifier {
    let screen: Screen
    @State private var token = 0

    func body(content: Content) -> some View {
        content
            .background(ScrollToTopHelper(token: token))
            .onReceive(NotificationCenter.default.publisher(for: .agnViewScrollToTop)) { note in
                if ScrollToTop.matches(note, screen: screen) { token += 1 }
            }
    }
}

extension View {
    /// Scrolls this screen's list to the top when its tab is tapped again.
    func scrollsToTopOnTabTap(_ screen: Screen) -> some View {
        modifier(ScrollsToTopOnTabTap(screen: screen))
    }
}
