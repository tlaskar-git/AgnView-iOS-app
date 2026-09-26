import Foundation

/// The public links the app shows: onboarding, Settings and About. Each
/// address lives here once. The listing text in AppStore/listing.json uses the
/// same addresses and a unit test keeps the two in step.
enum AppLinks {
    /// The free AgnView app for Windows and Mac.
    static let getDesktop = link("https://github.com/tlaskar-git/AgnView/releases/latest")
    static let privacyPolicy = link("https://github.com/tlaskar-git/AgnView-iOS-app/blob/main/PRIVACY.md")
    static let support = link("https://github.com/tlaskar-git/AgnView-iOS-app/issues")

    static func link(_ text: String) -> URL {
        guard let value = URL(string: text) else { preconditionFailure("bad link") }
        return value
    }
}

/// One third-party component the app ships with, for the Acknowledgements list.
struct Acknowledgement: Identifiable, Equatable {
    let name: String
    let licence: String
    let holder: String
    let source: URL
    var id: String { name }

    /// Components inside the app. Build tools are not listed.
    static let all: [Acknowledgement] = [
        Acknowledgement(name: "iroh", licence: "Apache License 2.0 or MIT License",
                        holder: "N0, Inc.",
                        source: AppLinks.link("https://github.com/n0-computer/iroh")),
        Acknowledgement(name: "iroh-ffi (IrohLib)", licence: "Apache License 2.0 or MIT License",
                        holder: "N0, Inc.",
                        source: AppLinks.link("https://github.com/n0-computer/iroh-ffi")),
    ]
}
