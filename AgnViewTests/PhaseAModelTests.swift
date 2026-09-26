import XCTest
@testable import AgnView

/// Decoding of the hub 0.1.12 answers behind the composer, the attach picker
/// and the Usage cards, from sanitised captures with placeholder values.
final class PhaseADecodeTests: XCTestCase {
    private static func fixture(_ name: String, file: StaticString = #filePath) throws -> Data {
        let folder = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hub-0.1.12")
        return try Data(contentsOf: folder.appendingPathComponent(name))
    }

    private func accounts() throws -> [UsageAccount] {
        try UsageAccount.decodeList(from: try Self.fixture("usage_accounts_windows.json"))
    }

    // MARK: Usage windows

    func testWindowedAccountsKeepTheHubOrder() throws {
        let list = try accounts()
        XCTAssertEqual(list.map { $0.provider }, ["antigravity", "chatgpt", "claude", "gemini"])
        XCTAssertEqual(list.map { $0.providerKind }, [.antigravity, .chatgpt, .claude, .gemini])
    }

    func testWindowsDecodeWithBreakdownCountdownAndBar() throws {
        let agy = try XCTUnwrap(try accounts().first)
        let usage = try XCTUnwrap(agy.usage)
        XCTAssertEqual(usage.sourceLabel, "AntiGravity usage panel")
        XCTAssertEqual(usage.ageSeconds, 180)
        XCTAssertFalse(usage.isStale)
        XCTAssertEqual(agy.displayPlan, "Pro")
        XCTAssertEqual(usage.windows.count, 2)
        let five = usage.windows[0]
        XCTAssertEqual(five.label, "Five Hour Limit")
        XCTAssertEqual(five.amountText, "91% used")
        XCTAssertEqual(five.percentUsed, 91)
        XCTAssertEqual(five.severity, "warning")
        XCTAssertTrue(five.isActive)
        XCTAssertEqual(five.countdownText, "Resets in 1h 12m")
        XCTAssertEqual(five.barFraction ?? 0, 0.91, accuracy: 0.0001)
        XCTAssertEqual(five.percentLeft, 9)
        XCTAssertEqual(five.breakdown.map { $0.label }, ["Gemini models", "Claude and GPT models"])
        XCTAssertEqual(five.breakdown[0].subLabel, "Example Flash, Example Pro")
        XCTAssertEqual(five.breakdown[1].amountText, "0% used")
        XCTAssertEqual(five.breakdown[1].barFraction, 0)
        XCTAssertNil(five.breakdown[1].countdownText)
    }

    func testStaleAndPlanLabelComeFromTheUsageBlock() throws {
        let chatgpt = try accounts()[1]
        XCTAssertEqual(chatgpt.usage?.isStale, true)
        XCTAssertEqual(chatgpt.displayPlan, "Plus (Codex and Agents)")
        XCTAssertEqual(chatgpt.usage?.sourceLabel, "ChatGPT account usage")
        let claude = try accounts()[2]
        XCTAssertEqual(claude.displayPlan, "Max (5x)")
    }

    func testTokensAndRequestsAppearOnlyWhenThePayloadHasThem() throws {
        let list = try accounts()
        XCTAssertFalse(list[1].hasTokens)
        XCTAssertFalse(list[1].hasRequests)
        XCTAssertTrue(list[2].hasTokens)
        XCTAssertEqual(list[2].tokensUsed, 370216)
        XCTAssertTrue(list[2].hasRequests)
        XCTAssertEqual(list[2].requestsCount, 96)
    }

    func testAWindowWithoutAFigureIsNotMeasuredButAZeroIs() throws {
        let gemini = try accounts()[3]
        let windows = try XCTUnwrap(gemini.usage?.windows)
        XCTAssertEqual(windows[0].amountText, "128 of 1,500 requests")
        XCTAssertEqual(windows[0].percentUsed, 8.5)
        XCTAssertTrue(windows[0].isMeasured)
        XCTAssertNil(windows[1].amountText)
        XCTAssertFalse(windows[1].isMeasured)
        XCTAssertNil(windows[1].barFraction, "no bar without a share")
        XCTAssertNil(windows[1].percentLeft)
        XCTAssertEqual(windows[1].subLabel, "Google publishes no weekly figure for this tier")

        let agy = try XCTUnwrap(try accounts().first?.usage?.windows[0].breakdown[1])
        XCTAssertTrue(agy.isMeasured, "0% used is a measured zero")
    }

    func testAWindowWithAUnitButNoShareDrawsNoBar() throws {
        let tokens = try XCTUnwrap(try accounts()[2].usage?.windows.last)
        XCTAssertEqual(tokens.unit, "tokens")
        XCTAssertEqual(tokens.amountText, "370,216 tokens")
        XCTAssertNil(tokens.percentUsed)
        XCTAssertFalse(tokens.hasBar)
        XCTAssertNil(tokens.barFraction)
    }

    func testAnOddWindowDoesNotFailTheAccount() throws {
        let json = """
        [{"id":"claude-1","provider":"claude","name":"Example","usage":{"windows":[
          {"label":"Session","amount_text":"5% used","percent_used":5,"has_bar":true},
          17,
          {"nothing":"useful"},
          {"label":"Weekly","amount_text":null,"percent_used":null,"has_bar":false,"breakdown":"bad"}]}}]
        """
        let list = try UsageAccount.decodeList(from: Data(json.utf8))
        let windows = try XCTUnwrap(list.first?.usage?.windows)
        XCTAssertEqual(windows.map { $0.label }, ["Session", "Weekly"])
        XCTAssertTrue(windows[1].breakdown.isEmpty)
    }

    func testAnAccountWithNoWindowsShowsTheHubReason() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hub-0.1.8/usage_accounts.json"))
        let list = try UsageAccount.decodeList(from: data)
        let first = try XCTUnwrap(list.first)
        XCTAssertFalse(first.hasWindows)
        XCTAssertNotNil(first.displayError)
        XCTAssertNil(first.usage?.windows.first)
    }

    func testWindowsRoundTrip() throws {
        let original = try XCTUnwrap(try accounts().first?.usage)
        let data = try JSONEncoder().encode(original)
        let back = try HubJSON.decoder().decode(UsageDetail.self, from: data)
        XCTAssertEqual(back.windows.first?.label, original.windows.first?.label)
    }

    func testReadingAgeAddsTheHubAgeToTheTimeSinceTheAnswer() {
        let taken = Date(timeIntervalSince1970: 1_800_000_000)
        let later = taken.addingTimeInterval(120)
        let seconds = Format.readingAge(hubAgeSeconds: 180, takenAt: taken, now: later)
        XCTAssertEqual(seconds, 300)
        XCTAssertEqual(Format.lastReading(seconds: seconds), "Last reading 5 min ago")
        XCTAssertEqual(Format.lastReading(seconds: Format.readingAge(hubAgeSeconds: nil, takenAt: taken, now: taken)),
                       "Last reading just now")
        XCTAssertEqual(Format.percent(8.5), "8.5%")
        XCTAssertEqual(Format.percent(9), "9%")
    }

    func testUpdatedText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Format.updated(from: nil, to: now), "Not updated yet")
        XCTAssertEqual(Format.updated(from: now, to: now), "Updated just now")
        XCTAssertEqual(Format.updated(from: now.addingTimeInterval(-300), to: now), "Updated 5 min ago")
    }

    // MARK: Catalogue and files

    private func catalogue() throws -> HubCatalogue {
        try HubJSON.decodePlain(HubCatalogue.self, from: try Self.fixture("system_capabilities.json"))
    }

    func testCatalogueKeepsAgentIdsAndAddsDefault() throws {
        let catalogue = try catalogue()
        let claude = catalogue.modelOptions(for: "claude_code")
        XCTAssertEqual(claude.map { $0.id }, ["", "example-large-2", "example-large-1", "example-small"])
        XCTAssertEqual(claude.first?.name, "Default")
        XCTAssertEqual(catalogue.modelOptions(for: "codex").count, 3)
        XCTAssertEqual(catalogue.modelOptions(for: "all").map { $0.name }, ["Auto"],
                       "the hub's auto entry stands in for Default")
    }

    func testAnAgentWithoutAListGetsDefaultOnlyForModels() throws {
        let catalogue = try catalogue()
        XCTAssertEqual(catalogue.modelOptions(for: "deepseek"), [ChoiceOption.hubDefault])
        XCTAssertFalse(catalogue.hasNamedModels(for: "deepseek"))
    }

    // MARK: Catalogue from hub 0.1.14

    /// The answer of GET /api/system/capabilities built from the hub 0.1.14
    /// model and effort lists, with placeholder paths.
    private static func catalogue014(_ name: String = "system_capabilities.json",
                                     file: StaticString = #filePath) throws -> HubCatalogue {
        let folder = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hub-0.1.14")
        return try HubJSON.decodePlain(HubCatalogue.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
    }

    func testHub014ListsNamedModelsForEveryAgentTheConsoleOffers() throws {
        let catalogue = try Self.catalogue014()
        let claude = catalogue.modelOptions(for: "claude_code")
        XCTAssertEqual(claude.count, 13, "Default and twelve models")
        XCTAssertEqual(claude.first, ChoiceOption.hubDefault)
        XCTAssertTrue(claude.contains(ChoiceOption(id: "claude-opus-5", name: "Opus 5")))
        let codex = catalogue.modelOptions(for: "codex")
        XCTAssertEqual(codex.count, 11)
        XCTAssertTrue(codex.contains(ChoiceOption(id: "gpt-5-codex", name: "GPT-5 Codex")))
        let agy = catalogue.modelOptions(for: "antigravity")
        XCTAssertEqual(agy.count, 10)
        XCTAssertTrue(agy.contains(ChoiceOption(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro")))
        for agent in ["claude_code", "codex", "antigravity"] {
            XCTAssertTrue(catalogue.hasNamedModels(for: agent), agent)
            XCTAssertGreaterThan(catalogue.effortOptions(for: agent).count, 3, agent)
        }
        XCTAssertEqual(catalogue.effortOptions(for: "claude_code").map { $0.id },
                       ["", "low", "medium", "high", "xhigh", "max"])
        XCTAssertTrue(catalogue.hasNamedModels)
    }

    func testChangingAgentKeepsOnlyAModelTheNewAgentOffers() throws {
        let catalogue = try Self.catalogue014()
        var selection = ComposerSelection()
        selection.modelId = "claude-opus-5"
        selection.select(agent: "antigravity", catalogue: catalogue)
        XCTAssertEqual(selection.modelId, "", "Opus 5 is not on the AntiGravity list")
        selection.modelId = "claude-sonnet-4-6"
        selection.select(agent: "claude_code", catalogue: catalogue)
        XCTAssertEqual(selection.modelId, "claude-sonnet-4-6", "both agents list this id")
        XCTAssertEqual(selection.modelValue, "claude-sonnet-4-6")
    }

    /// A hub whose lists hold only a default entry: the menu shows Default
    /// alone, and the catalogue says it has no named models, which the screen
    /// explains instead of looking empty.
    func testDefaultOnlyListIsAValidState() throws {
        let catalogue = try Self.catalogue014("system_capabilities_default_only.json")
        XCTAssertEqual(catalogue.modelOptions(for: "claude_code"), [ChoiceOption.hubDefault])
        XCTAssertEqual(catalogue.modelOptions(for: "codex"), [ChoiceOption.hubDefault])
        XCTAssertFalse(catalogue.hasNamedModels(for: "claude_code"))
        XCTAssertFalse(catalogue.hasNamedModels)
        XCTAssertEqual(catalogue.effortOptions(for: "claude_code").map { $0.id }, ["", "low", "medium", "high"])
        XCTAssertEqual(ComposerSelection.chipText(catalogue.modelOptions(for: "claude_code"), selected: ""), "Default")
    }

    func testStoredCatalogueReadsBackTheSame() throws {
        let catalogue = try Self.catalogue014()
        let data = try JSONEncoder().encode(catalogue)
        var expected = catalogue
        expected.currentDirectory = nil
        XCTAssertEqual(try HubJSON.decodePlain(HubCatalogue.self, from: data), expected)
    }

    func testCatalogueCacheKeepsOneCopyPerHub() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalogue = try Self.catalogue014()
        let cache = CatalogueCache(directory: dir)
        XCTAssertNil(cache.catalogue(for: "hub-a"))
        cache.save(catalogue, for: "hub-a")
        let again = CatalogueCache(directory: dir)
        XCTAssertEqual(again.catalogue(for: "hub-a")?.modelOptions(for: "codex"), catalogue.modelOptions(for: "codex"))
        XCTAssertNil(again.catalogue(for: "hub-a")?.currentDirectory, "the working folder is not kept")
        XCTAssertNil(again.catalogue(for: "hub-b"))
        again.remove(hubId: "hub-a")
        XCTAssertNil(CatalogueCache(directory: dir).catalogue(for: "hub-a"))
    }

    func testEffortOptionsUseTheAgentListThenThePlainList() throws {
        let catalogue = try catalogue()
        XCTAssertEqual(catalogue.effortOptions(for: "claude_code").map { $0.id },
                       ["", "low", "medium", "high", "max"])
        XCTAssertEqual(catalogue.effortOptions(for: "antigravity").map { $0.id },
                       ["", "low", "medium", "high"], "plain list from the hub")
        XCTAssertEqual(HubCatalogue.empty.effortOptions(for: "claude_code").map { $0.id },
                       ["", "low", "medium", "high"], "documented values when the hub sent no list")
        XCTAssertEqual(HubCatalogue.empty.modelOptions(for: "claude_code"), [ChoiceOption.hubDefault])
    }

    func testInstalledAgentsAreRead() throws {
        let catalogue = try catalogue()
        XCTAssertEqual(catalogue.availableAgents, ["claude_code", "codex"])
        XCTAssertEqual(catalogue.currentDirectory, "/home/example/project")
        XCTAssertTrue(HubCatalogue.empty.isAvailable("claude_code"), "unknown means available")
    }

    func testCatalogueToleratesMissingParts() throws {
        let sparse = try HubJSON.decodePlain(HubCatalogue.self, from: Data(#"{"models":{"codex":[{"id":"x"},{"name":"no id"}]}}"#.utf8))
        XCTAssertEqual(sparse.modelOptions(for: "codex").map { $0.id }, ["", "x"])
        XCTAssertNil(sparse.availableAgents)
    }

    func testWorkspaceFilesDecode() throws {
        let files = try HubJSON.decodePlain(WorkspaceFiles.self, from: try Self.fixture("system_files.json"))
        XCTAssertEqual(files.files, ["README.md", "docs/example-notes.md", "src/example.py"])
        XCTAssertEqual(files.directory, "/home/example/project")
        let bare = try HubJSON.decodePlain(WorkspaceFiles.self, from: Data(#"["a.txt",{"path":"b.txt"},4]"#.utf8))
        XCTAssertEqual(bare.files, ["a.txt", "b.txt"])
        let empty = try HubJSON.decodePlain(WorkspaceFiles.self, from: Data(#"{"files":[]}"#.utf8))
        XCTAssertTrue(empty.files.isEmpty)
    }

    func testCreatedJobDecodes() throws {
        let job = try HubJSON.decode(Job.self, from: try Self.fixture("job_created.json"))
        XCTAssertEqual(job.id, "job-example")
        XCTAssertEqual(job.tasks.first?.description, "Build it\n[Context Files: README.md]")
    }
}

/// The attachments model, the composer selection and the capability flags.
final class ComposerModelTests: XCTestCase {
    // MARK: Attachments

    func testHubFileIsNamedAfterItsLastPathPart() {
        let item = AttachmentItem.forHubPath("docs/example-notes.md")
        XCTAssertEqual(item.displayName, "example-notes.md")
        XCTAssertEqual(item.hubPath, "docs/example-notes.md")
        XCTAssertTrue(item.isHubFile)
        XCTAssertEqual(item.id, "hub:docs/example-notes.md")
    }

    func testContextLineListsHubFilesInOrderWithoutRepeats() {
        let items: [AttachmentItem] = [.forHubPath("b.txt"), .forHubPath("a.txt"), .forHubPath("b.txt")]
        XCTAssertEqual(Attachments.hubPaths(items), ["b.txt", "a.txt"])
        XCTAssertEqual(Attachments.contextLine(items), "[Context Files: b.txt, a.txt]")
        XCTAssertNil(Attachments.contextLine([]))
    }

    func testEmbedAppendsTheLineOnItsOwnLine() {
        let items = [AttachmentItem.forHubPath("a.txt"), .forHubPath("dir/b.txt")]
        XCTAssertEqual(Attachments.embed(items, in: "Do the work"),
                       "Do the work\n[Context Files: a.txt, dir/b.txt]")
        XCTAssertEqual(Attachments.embed(items, in: "  \n"), "[Context Files: a.txt, dir/b.txt]")
        XCTAssertEqual(Attachments.embed([], in: "Do the work"), "Do the work")
    }

    func testLocalFilesAreHeldButNeverSentInPhaseA() {
        let local = AttachmentItem.localFile(url: URL(fileURLWithPath: "/tmp/example.pdf"), name: "example.pdf",
                                             size: 1234, mime: "application/pdf", source: .files)
        XCTAssertFalse(local.isHubFile)
        XCTAssertNil(local.hubPath)
        XCTAssertEqual(local.displayName, "example.pdf")
        XCTAssertTrue(local.id.hasPrefix("local:"))
        XCTAssertNil(Attachments.contextLine([local]))
        XCTAssertEqual(Attachments.embed([local], in: "text"), "text")
        let photo = AttachmentItem.localFile(url: URL(fileURLWithPath: "/tmp/p.jpg"), name: "p.jpg", size: 9,
                                             mime: "image/jpeg", source: .photos)
        XCTAssertNotEqual(local, photo)
    }

    func testAddingSkipsADuplicate() {
        let a = AttachmentItem.forHubPath("a.txt")
        XCTAssertEqual(Attachments.adding(a, to: [a]).count, 1)
        XCTAssertEqual(Attachments.adding(.forHubPath("b.txt"), to: [a]).count, 2)
    }

    // MARK: Selection and keyboard toolbar state

    func testSelectionSendsNilForDefaultAndAuto() {
        var selection = ComposerSelection()
        XCTAssertNil(selection.modelValue)
        XCTAssertNil(selection.effortValue)
        selection.modelId = "auto"
        selection.effortId = "default"
        XCTAssertNil(selection.modelValue)
        XCTAssertNil(selection.effortValue)
        selection.modelId = "example-large-2"
        selection.effortId = "low"
        XCTAssertEqual(selection.modelValue, "example-large-2")
        XCTAssertEqual(selection.effortValue, "low")
    }

    func testChangingTheAgentDropsChoicesItDoesNotHave() throws {
        let data = Data(#"{"models":{"claude_code":[{"id":"m1","name":"M One"}],"codex":[{"id":"m2","name":"M Two"}]},"efforts_by_provider":{"claude_code":[{"id":"max","name":"Maximum Effort"}],"codex":[{"id":"low","name":"Low Reasoning"}]}}"#.utf8)
        let catalogue = try HubJSON.decodePlain(HubCatalogue.self, from: data)
        var selection = ComposerSelection()
        selection.modelId = "m1"
        selection.effortId = "max"
        selection.select(agent: "codex", catalogue: catalogue)
        XCTAssertEqual(selection.agent, "codex")
        XCTAssertEqual(selection.modelId, "", "m1 is a claude_code model")
        XCTAssertEqual(selection.effortId, "")
        selection.modelId = "m2"
        selection.select(agent: "codex", catalogue: catalogue)
        XCTAssertEqual(selection.modelId, "m2", "choosing the same agent keeps the choices")
    }

    func testChipTextShortensEffortNamesAndFallsBackToDefault() {
        let options = [ChoiceOption.hubDefault,
                       ChoiceOption(id: "low", name: "Low Effort"),
                       ChoiceOption(id: "high", name: "High Reasoning"),
                       ChoiceOption(id: "x", name: "Example Large 2")]
        XCTAssertEqual(ComposerSelection.chipText(options, selected: ""), "Default")
        XCTAssertEqual(ComposerSelection.chipText(options, selected: "low"), "Low")
        XCTAssertEqual(ComposerSelection.chipText(options, selected: "high"), "High")
        XCTAssertEqual(ComposerSelection.chipText(options, selected: "x"), "Example Large 2")
        XCTAssertEqual(ComposerSelection.chipText(options, selected: "gone"), "Default")
        XCTAssertEqual(ComposerSelection.chipText([], selected: ""), "Default")
    }

    // MARK: Flags

    func testPhaseAFlagsAreOffAndSayWhy() {
        let features = HubFeatures.phaseA
        XCTAssertFalse(features.supportsPhoneUploads)
        XCTAssertFalse(features.supportsTaskModelEffort)
        XCTAssertEqual(HubFeatures.uploadsNeedsUpdateText, "Needs AgnView 0.1.13 on your computer")
    }

    func testCapabilitySetsSplitLANFromIroh() {
        XCTAssertTrue(Capability.lanOnly.isSubset(of: Set<Capability>.lan))
        XCTAssertTrue(Set<Capability>.irohAPI.isDisjoint(with: Capability.lanOnly))
        XCTAssertTrue(Set<Capability>.irohAPI.isSuperset(of: [.dispatch, .usage, .jobs, .sessions]))
    }

    // MARK: Version line

    func testVersionLineHasNoBuildNumber() {
        XCTAssertEqual(AppVersion.text(from: ["CFBundleShortVersionString": "1.0.1", "CFBundleVersion": "57"]),
                       "Version 1.0.1")
        XCTAssertEqual(AppVersion.text(from: ["CFBundleVersion": "57"]), "Unknown")
        XCTAssertEqual(AppVersion.text(from: nil), "Unknown")
    }

    // MARK: Dispatch body

    func testDispatchBodyCarriesModelEffortAndFilesOnlyWhenSet() throws {
        let plain = try JSONEncoder().encode(DispatchRequest(targetAgent: "codex", prompt: "p"))
        let plainObject = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNil(plainObject["model"])
        XCTAssertNil(plainObject["effort"])
        XCTAssertNil(plainObject["files"])

        let full = try JSONEncoder().encode(DispatchRequest(targetAgent: "codex", prompt: "p", model: "example-codex",
                                                            effort: "low", files: ["a.txt", "b/c.txt"]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: full) as? [String: Any])
        XCTAssertEqual(object["agent"] as? String, "codex")
        XCTAssertEqual(object["model"] as? String, "example-codex")
        XCTAssertEqual(object["effort"] as? String, "low")
        XCTAssertEqual(object["files"] as? [String], ["a.txt", "b/c.txt"])

        let noFiles = try JSONEncoder().encode(DispatchRequest(targetAgent: "codex", prompt: "p", files: []))
        XCTAssertNil((try XCTUnwrap(JSONSerialization.jsonObject(with: noFiles) as? [String: Any]))["files"])
    }
}

/// The New pipeline form as data.
final class PipelineDraftTests: XCTestCase {
    private func filled(seed: String = "ab12") -> PipelineDraft {
        var draft = PipelineDraft(idSeed: seed)
        draft.title = "Example pipeline"
        draft.tasks[0].title = "Build"
        return draft
    }

    func testANewDraftHasOneTaskAndNeedsATitle() {
        let draft = PipelineDraft(idSeed: "ab12")
        XCTAssertEqual(draft.tasks.count, 1)
        XCTAssertEqual(draft.tasks[0].taskId, "task-ab12-1")
        XCTAssertFalse(draft.isValid)
        XCTAssertTrue(draft.issues().contains(.titleRequired))
        XCTAssertTrue(draft.issues().contains(.taskTitleRequired(taskId: "task-ab12-1")))
        XCTAssertFalse(draft.isDirty)
    }

    func testTitleIsRequiredAndBlankDoesNotCount() {
        var draft = filled()
        XCTAssertTrue(draft.isValid)
        draft.title = "   \n"
        XCTAssertEqual(draft.issues(), [.titleRequired])
    }

    func testAtLeastOneTaskIsRequired() {
        var draft = filled()
        draft.tasks = []
        XCTAssertEqual(draft.issues(), [.noTasks])
    }

    func testEveryTaskNeedsATitle() {
        var draft = filled()
        draft.addTask()
        XCTAssertEqual(draft.issues(), [.taskTitleRequired(taskId: "task-ab12-2")])
    }

    func testDefaultTaskIdsDifferBetweenPipelines() {
        XCTAssertNotEqual(PipelineDraft(idSeed: "aaaa").tasks[0].taskId, PipelineDraft(idSeed: "bbbb").tasks[0].taskId)
        XCTAssertEqual(PipelineDraft.randomSeed().count, 4)
    }

    func testTaskIdsMustBeSafeAndUnique() {
        var draft = filled()
        draft.tasks[0].taskId = "bad id/../"
        XCTAssertEqual(draft.issues(), [.taskIdInvalid(taskId: "bad id/../")])
        draft.tasks[0].taskId = ""
        XCTAssertEqual(draft.issues(), [.taskIdInvalid(taskId: "")])
        draft.tasks[0].taskId = "same"
        draft.addTask()
        draft.tasks[1].taskId = "same"
        draft.tasks[1].title = "Two"
        XCTAssertEqual(draft.issues(), [.taskIdDuplicate(taskId: "same")])
        XCTAssertTrue(PipelineDraft.isSafeId("task-1.a_b"))
        XCTAssertFalse(PipelineDraft.isSafeId("a/b"))
        XCTAssertFalse(PipelineDraft.isSafeId(".hidden"))
    }

    func testPipelineIdIsOptionalButMustBeSafe() {
        var draft = filled()
        draft.jobId = "release-1"
        XCTAssertTrue(draft.isValid)
        draft.jobId = "not/safe"
        XCTAssertEqual(draft.issues(), [.pipelineIdInvalid])
    }

    func testDependencyCycleIsFound() {
        var draft = filled()
        draft.addTask()
        draft.tasks[1].title = "Two"
        draft.addTask()
        draft.tasks[2].title = "Three"
        let (a, b, c) = (draft.tasks[0].id, draft.tasks[1].id, draft.tasks[2].id)
        draft.tasks[1].prerequisites = [a]
        draft.tasks[2].prerequisites = [b]
        XCTAssertNil(draft.dependencyCycle())
        XCTAssertTrue(draft.isValid)
        draft.tasks[0].prerequisites = [c]
        let cycle = draft.dependencyCycle()
        XCTAssertNotNil(cycle)
        XCTAssertEqual(Set(cycle ?? []), Set(draft.tasks.map { $0.taskId }))
        XCTAssertTrue(draft.issues().contains { if case .dependencyCycle = $0 { return true } else { return false } })
    }

    func testASelfDependencyIsACycle() {
        var draft = filled()
        draft.tasks[0].prerequisites = [draft.tasks[0].id]
        XCTAssertEqual(draft.dependencyCycle(), [draft.tasks[0].taskId])
    }

    func testDependencyGraphHelper() {
        XCTAssertNil(DependencyGraph.cycle(in: [:]))
        XCTAssertNil(DependencyGraph.cycle(in: ["a": [], "b": ["a"], "c": ["a", "b"]]))
        XCTAssertNotNil(DependencyGraph.cycle(in: ["a": ["b"], "b": ["a"]]))
        XCTAssertNil(DependencyGraph.cycle(in: ["a": ["missing"]]), "unknown ids are ignored")
    }

    func testRemovingATaskDropsItsLinks() {
        var draft = filled()
        draft.addTask()
        draft.tasks[1].title = "Two"
        draft.tasks[1].prerequisites = [draft.tasks[0].id]
        let removed = draft.tasks[0].id
        draft.removeTask(removed)
        XCTAssertEqual(draft.tasks.count, 1)
        XCTAssertTrue(draft.tasks[0].prerequisites.isEmpty)
    }

    func testAddTaskNeverReusesAnId() {
        var draft = filled()
        draft.addTask()
        draft.addTask()
        draft.removeTask(draft.tasks[1].id)
        draft.addTask()
        XCTAssertEqual(Set(draft.tasks.map { $0.taskId }).count, draft.tasks.count)
    }

    func testDirtyTracksEdits() {
        var draft = PipelineDraft(idSeed: "ab12")
        XCTAssertFalse(draft.isDirty)
        draft.description = "x"
        XCTAssertTrue(draft.isDirty)
    }

    // MARK: Request body

    private func json(_ body: CreateJobBody) throws -> [String: Any] {
        let encoder = JSONEncoder()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(body)) as? [String: Any])
    }

    func testBodyHasTheKeysTheHubReads() throws {
        var draft = filled()
        draft.jobId = "release-1"
        draft.description = "  Ship it  "
        draft.tasks[0].taskId = "build"
        draft.tasks[0].description = "Compile"
        draft.tasks[0].agent = "codex"
        draft.addTask()
        draft.tasks[1].taskId = "review"
        draft.tasks[1].title = "Review"
        draft.tasks[1].prerequisites = [draft.tasks[0].id]

        let object = try json(draft.requestBody())
        XCTAssertEqual(object["id"] as? String, "release-1")
        XCTAssertEqual(object["title"] as? String, "Example pipeline")
        XCTAssertEqual(object["description"] as? String, "Ship it")
        let tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(Set(tasks[0].keys), ["id", "title", "description", "assigned_agent", "dependencies"])
        XCTAssertEqual(tasks[0]["id"] as? String, "build")
        XCTAssertEqual(tasks[0]["assigned_agent"] as? String, "codex")
        XCTAssertEqual(tasks[0]["dependencies"] as? [String], [])
        XCTAssertEqual(tasks[1]["dependencies"] as? [String], ["build"])
        XCTAssertNil(tasks[0]["model"], "per-task model is not sent in phase A")
        XCTAssertNil(tasks[0]["effort"], "per-task effort is not sent in phase A")
    }

    func testEmptyPipelineIdIsLeftOut() throws {
        let object = try json(filled().requestBody())
        XCTAssertNil(object["id"])
        XCTAssertEqual(object["description"] as? String, "")
    }

    func testHubFilesAreEmbeddedInEveryTaskDescription() throws {
        var draft = filled()
        draft.tasks[0].description = "Compile"
        draft.addTask()
        draft.tasks[1].title = "Review"
        draft.attachments = [.forHubPath("README.md"), .forHubPath("src/example.py")]
        let tasks = try XCTUnwrap(try json(draft.requestBody())["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks[0]["description"] as? String, "Compile\n[Context Files: README.md, src/example.py]")
        XCTAssertEqual(tasks[1]["description"] as? String, "[Context Files: README.md, src/example.py]")
    }

    func testPhoneFilesAreNotEmbedded() throws {
        var draft = filled()
        draft.tasks[0].description = "Compile"
        draft.attachments = [.localFile(url: URL(fileURLWithPath: "/tmp/x.pdf"), name: "x.pdf", size: 1,
                                        mime: "application/pdf", source: .files)]
        let tasks = try XCTUnwrap(try json(draft.requestBody())["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks[0]["description"] as? String, "Compile")
    }

    func testIssueMessagesArePlainText() {
        XCTAssertEqual(PipelineIssue.titleRequired.message, "Title is required.")
        XCTAssertEqual(PipelineIssue.noTasks.message, "Add at least one task.")
        XCTAssertTrue(PipelineIssue.dependencyCycle(taskIds: ["a", "b"]).message.contains("a, b"))
        XCTAssertFalse(PipelineIssue.taskIdInvalid(taskId: "x").message.contains("\u{2014}"))
    }
}
