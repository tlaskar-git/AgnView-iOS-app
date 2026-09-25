import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case console
    case sessions
    case pipelines
    case usage
    case settings

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var identifier: String { "screen-" + rawValue }

    var symbol: String {
        switch self {
        case .console: return "terminal"
        case .sessions: return "rectangle.stack"
        case .pipelines: return "point.3.connected.trianglepath.dotted"
        case .usage: return "chart.bar"
        case .settings: return "gearshape"
        }
    }
}
