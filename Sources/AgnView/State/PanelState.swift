import Foundation

/// The state of one panel (Usage, Pipelines, Sessions, the console send
/// result). A failure belongs to its panel. It never changes ConnectionState.
enum PanelState<T: Equatable>: Equatable {
    case loading
    case loaded(T)
    case failed(String)
    /// A reading kept from `since` while no fresh one can be taken.
    case stale(T, since: Date)

    /// The reading the panel holds, fresh or stale.
    var value: T? {
        switch self {
        case .loaded(let value), .stale(let value, _): return value
        case .loading, .failed: return nil
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// A loaded reading becomes stale. Any other state stays as it is.
    func markedStale(since: Date) -> PanelState {
        if case .loaded(let value) = self { return .stale(value, since: since) }
        return self
    }

    /// A failed panel goes back to loading for a retry. Other states stay.
    func retrying() -> PanelState {
        if case .failed = self { return .loading }
        return self
    }

    static func failure(panel: String) -> PanelState {
        .failed(PanelMessages.couldNotRead(panel))
    }
}

enum PanelMessages {
    static func couldNotRead(_ panel: String) -> String {
        "\(panel) could not be read. Tap Retry."
    }

    static let notMeasured = "Not measured yet"
}
