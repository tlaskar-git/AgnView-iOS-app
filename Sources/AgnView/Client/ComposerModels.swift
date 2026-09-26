import Foundation

/// What this app build can do with the hub it is paired to. Phase A works with
/// hub 0.1.12. The two flags below turn on when a hub release adds the calls
/// they need, so the screens can be drawn now and switched on later without a
/// redesign.
struct HubFeatures: Equatable {
    /// Phone files, photos and camera uploads. Needs a hub call that accepts a
    /// file from the phone (planned for hub 0.1.13).
    var supportsPhoneUploads: Bool
    /// A model and effort per pipeline task. Needs hub task fields that do not
    /// exist in 0.1.12.
    var supportsTaskModelEffort: Bool

    /// The hub release that adds phone uploads. Shown next to the disabled entries.
    static let uploadsRelease = "0.1.13"

    static let phaseA = HubFeatures(supportsPhoneUploads: false, supportsTaskModelEffort: false)

    /// "Needs AgnView 0.1.13 on your computer".
    static var uploadsNeedsUpdateText: String {
        "Needs AgnView \(uploadsRelease) on your computer"
    }
}

/// One entry in a model or effort menu.
struct ChoiceOption: Equatable, Hashable, Identifiable {
    let id: String
    let name: String

    /// Ids that mean "let the hub pick". They are never sent in a dispatch.
    static let unsetIds: Set<String> = ["", "default", "auto", "none"]

    var isDefault: Bool { ChoiceOption.unsetIds.contains(id) }

    static let hubDefault = ChoiceOption(id: "", name: "Default")
}

/// The lists behind the Model and Effort menus, read from
/// GET /api/system/capabilities. The hub keys both lists by agent id.
struct HubCatalogue: Equatable {
    var models: [String: [ChoiceOption]] = [:]
    var efforts: [String: [ChoiceOption]] = [:]
    /// The hub's plain effort list (low, medium, high), used when an agent has no list of its own.
    var plainEfforts: [String] = []
    /// Agents the hub found installed. Nil when the hub did not say.
    var availableAgents: Set<String>?
    var currentDirectory: String?

    static let empty = HubCatalogue()

    /// The menu for an agent: Default first, then the hub's list. An agent the
    /// hub lists nothing for gets Default only, never an invented model.
    func modelOptions(for agent: String) -> [ChoiceOption] {
        HubCatalogue.withDefault(models[agent] ?? [])
    }

    /// The effort menu for an agent. Falls back to the hub's plain effort list,
    /// then to low, medium and high, which the dispatch call documents.
    func effortOptions(for agent: String) -> [ChoiceOption] {
        if let own = efforts[agent], !own.isEmpty { return HubCatalogue.withDefault(own) }
        let names = plainEfforts.isEmpty ? HubCatalogue.documentedEfforts : plainEfforts
        return HubCatalogue.withDefault(names.map { ChoiceOption(id: $0, name: $0.capitalized) })
    }

    static let documentedEfforts = ["low", "medium", "high"]

    private static func withDefault(_ list: [ChoiceOption]) -> [ChoiceOption] {
        let rest = list.filter { !$0.isDefault }
        let named = list.first { $0.isDefault && !$0.id.isEmpty }
        return [ChoiceOption(id: "", name: named?.name ?? ChoiceOption.hubDefault.name)] + rest
    }

    func isAvailable(_ agent: String) -> Bool {
        availableAgents?.contains(agent) ?? true
    }
}

extension HubCatalogue: Decodable {
    private enum CodingKeys: String, CodingKey {
        case models
        case efforts
        case effortsByProvider = "efforts_by_provider"
        case installedClis = "installed_clis"
        case currentCwd = "current_cwd"
    }

    private struct Item: Decodable {
        let id: String
        let name: String

        private enum Keys: String, CodingKey { case id, name }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            guard let id = c.lenientString(forKey: .id), !id.isEmpty else {
                throw DecodingError.keyNotFound(Keys.id, .init(codingPath: c.codingPath,
                                                               debugDescription: "option id"))
            }
            self.id = id
            name = c.lenientString(forKey: .name) ?? id
        }
    }

    private struct InstalledItem: Decodable {
        let id: String
        let available: Bool

        private enum Keys: String, CodingKey { case id, available }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            guard let id = c.lenientString(forKey: .id) else {
                throw DecodingError.keyNotFound(Keys.id, .init(codingPath: c.codingPath,
                                                               debugDescription: "cli id"))
            }
            self.id = id
            available = c.lenientBool(forKey: .available) ?? false
        }
    }

    private static func options(_ raw: [String: LenientList<Item>]?) -> [String: [ChoiceOption]] {
        var out: [String: [ChoiceOption]] = [:]
        for (agent, list) in raw ?? [:] {
            out[agent] = list.items.map { ChoiceOption(id: $0.id, name: $0.name) }
        }
        return out
    }

    /// Decode with a plain JSONDecoder: the agent ids are dictionary keys, and
    /// the snake case key strategy would rewrite claude_code to claudeCode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = HubCatalogue.options(try? c.decodeIfPresent([String: LenientList<Item>].self, forKey: .models))
        efforts = HubCatalogue.options(try? c.decodeIfPresent([String: LenientList<Item>].self,
                                                              forKey: .effortsByProvider))
        plainEfforts = ((try? c.decodeIfPresent([String].self, forKey: .efforts)) ?? nil) ?? []
        if let installed = (try? c.decodeIfPresent(LenientList<InstalledItem>.self, forKey: .installedClis)) ?? nil {
            availableAgents = Set(installed.items.filter { $0.available }.map { $0.id })
        } else {
            availableAgents = nil
        }
        currentDirectory = (try? c.decodeIfPresent(String.self, forKey: .currentCwd)) ?? nil
    }
}

/// The answer of GET /api/system/files: paths relative to the folder the hub scanned.
struct WorkspaceFiles: Equatable, Decodable {
    let files: [String]
    let directory: String?

    init(files: [String], directory: String? = nil) {
        self.files = files
        self.directory = directory
    }

    private enum CodingKeys: String, CodingKey { case files, cwd }

    private struct Entry: Decodable {
        let path: String

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                path = text
                return
            }
            let c = try decoder.container(keyedBy: Keys.self)
            guard let value = c.lenientString(forKey: .path), !value.isEmpty else {
                throw DecodingError.keyNotFound(Keys.path, .init(codingPath: c.codingPath,
                                                                 debugDescription: "file path"))
            }
            path = value
        }

        private enum Keys: String, CodingKey { case path }
    }

    /// The hub sends {"files": [...], "cwd": "..."}. A bare list is read as well.
    init(from decoder: Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode(LenientList<Entry>.self) {
            files = bare.items.map { $0.path }
            directory = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = (try? c.decodeIfPresent(LenientList<Entry>.self, forKey: .files)) ?? nil
        files = list?.items.map { $0.path } ?? []
        directory = (try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? nil
    }
}

// MARK: - Attachments

/// Where a phone-side attachment comes from. Reserved for phase B.
enum AttachmentSource: String, Equatable {
    case files
    case photos
    case camera
}

/// One thing attached to a prompt or a pipeline. Phase A produces hub files
/// only. The local file case holds what phase B needs to upload a file from the
/// phone and is never created yet.
enum AttachmentItem: Equatable, Identifiable {
    /// A file that already exists on the hub computer, by the path the hub listed.
    case hubFile(path: String, name: String)
    /// A file on the phone (phase B).
    case localFile(url: URL, name: String, size: Int64, mime: String, source: AttachmentSource)

    var id: String {
        switch self {
        case .hubFile(let path, _): return "hub:" + path
        case .localFile(let url, _, _, _, _): return "local:" + url.absoluteString
        }
    }

    var displayName: String {
        switch self {
        case .hubFile(_, let name), .localFile(_, let name, _, _, _): return name
        }
    }

    var hubPath: String? {
        if case .hubFile(let path, _) = self { return path }
        return nil
    }

    var isHubFile: Bool { hubPath != nil }

    /// A hub file named after the last part of its path.
    static func forHubPath(_ path: String) -> AttachmentItem {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return .hubFile(path: path, name: name)
    }
}

enum Attachments {
    /// The hub paths in the list, in order, without repeats. Phone-side files
    /// carry no hub path yet, so they are left out.
    static func hubPaths(_ items: [AttachmentItem]) -> [String] {
        var seen = Set<String>()
        return items.compactMap { $0.hubPath }.filter { seen.insert($0).inserted }
    }

    /// "[Context Files: a, b]", the line the hub adds to a prompt. Nil when
    /// there is no hub file.
    static func contextLine(_ items: [AttachmentItem]) -> String? {
        let paths = hubPaths(items)
        return paths.isEmpty ? nil : "[Context Files: " + paths.joined(separator: ", ") + "]"
    }

    /// Text with the context line on its own last line, as the hub does for a
    /// dispatch. The text stays untouched when nothing is attached.
    static func embed(_ items: [AttachmentItem], in text: String) -> String {
        guard let line = contextLine(items) else { return text }
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? line : base + "\n" + line
    }

    /// Adds an item unless the list already holds it.
    static func adding(_ item: AttachmentItem, to items: [AttachmentItem]) -> [AttachmentItem] {
        items.contains { $0.id == item.id } ? items : items + [item]
    }
}

// MARK: - Composer selection

/// The agent, model and effort chosen in the console composer. The keyboard
/// toolbar and the composer both read this, so they always agree.
struct ComposerSelection: Equatable {
    var agent = "claude_code"
    var modelId = ""
    var effortId = ""

    /// Changing the agent drops a model or effort the new agent may not have.
    mutating func select(agent newAgent: String, catalogue: HubCatalogue) {
        guard newAgent != agent else { return }
        agent = newAgent
        if !catalogue.modelOptions(for: newAgent).contains(where: { $0.id == modelId }) { modelId = "" }
        if !catalogue.effortOptions(for: newAgent).contains(where: { $0.id == effortId }) { effortId = "" }
    }

    /// The value the hub receives: nil for Default.
    var modelValue: String? { ComposerSelection.value(modelId) }
    var effortValue: String? { ComposerSelection.value(effortId) }

    private static func value(_ id: String) -> String? {
        ChoiceOption.unsetIds.contains(id) ? nil : id
    }

    /// The short text on a chip: the option's name, or Default.
    static func chipText(_ options: [ChoiceOption], selected id: String) -> String {
        let match = options.first { $0.id == id } ?? options.first
        let name = match?.name ?? ChoiceOption.hubDefault.name
        return name.replacingOccurrences(of: " Effort", with: "")
            .replacingOccurrences(of: " Reasoning", with: "")
    }
}
