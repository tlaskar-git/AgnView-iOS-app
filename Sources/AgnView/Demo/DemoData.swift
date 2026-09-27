import Foundation

/// The built-in sample content for demo mode. Every name, path, figure and
/// line of output here is invented. Nothing in it comes from a real computer,
/// account or agent.
enum DemoData {
    static let claudeSession = "3f9a1c72"
    static let codexSession = "8be04d15"
    static let antigravitySession = "d17c6a90"
    static let workingDirectory = "~/demo-project"

    /// One console line: who wrote it, what kind it is, the text and the session.
    struct Line {
        let agent: String
        let source: String
        let content: String
        let session: String?
    }

    /// The conversation that is already in the console when the demo starts.
    static let backlog: [Line] = [
        Line(agent: "system", source: "system_notice",
             content: "Demo mode. These lines are sample data.", session: nil),
        Line(agent: "user", source: "user_input",
             content: "Add input validation to the signup form.", session: claudeSession),
        Line(agent: "claude_code", source: "agent_stdout",
             content: "Reading src/signup.example and the tests next to it.", session: claudeSession),
        Line(agent: "claude_code", source: "agent_stdout",
             content: "Two fields have no checks: email and display name.", session: claudeSession),
        Line(agent: "claude_code", source: "agent_stdout",
             content: "Editing src/signup.example to check both fields before submit.", session: claudeSession),
        Line(agent: "claude_code", source: "agent_stdout",
             content: "Running the tests: 14 passed, 0 failed.", session: claudeSession),
        Line(agent: "claude_code", source: "agent_stdout",
             content: "Done. The form now rejects empty and malformed input.", session: claudeSession),
        Line(agent: "system", source: "system_notice", content: "Finished", session: claudeSession),
        Line(agent: "user", source: "user_input",
             content: "Review that change and list any edge cases.", session: codexSession),
        Line(agent: "codex", source: "agent_stdout",
             content: "Comparing the change with the test cases.", session: codexSession),
        Line(agent: "codex", source: "agent_stdout",
             content: "Edge case: an email with a trailing space is accepted. Trim it first.", session: codexSession),
        Line(agent: "user", source: "user_input",
             content: "Summarise the open tasks in the demo project.", session: antigravitySession),
        Line(agent: "antigravity", source: "agent_stdout",
             content: "Two tasks are open: trim the email input and update the sample docs.",
             session: antigravitySession),
    ]

    /// Lines that arrive one by one after the demo starts.
    static let live: [Line] = [
        Line(agent: "claude_code", source: "agent_stdout",
             content: "Trimming spaces before the email check.", session: claudeSession),
        Line(agent: "claude_code", source: "agent_stdout",
             content: "Adding a test for the trailing space case.", session: claudeSession),
        Line(agent: "codex", source: "agent_stdout",
             content: "Checking the updated code again.", session: codexSession),
        Line(agent: "codex", source: "agent_stdout",
             content: "No further edge cases found.", session: codexSession),
        Line(agent: "antigravity", source: "agent_stdout",
             content: "Updating the sample docs to describe the new checks.", session: antigravitySession),
        Line(agent: "antigravity", source: "agent_stdout",
             content: "Docs updated.", session: antigravitySession),
        Line(agent: "claude_code", source: "agent_stdout",
             content: "Running the tests: 15 passed, 0 failed.", session: claudeSession),
        Line(agent: "system", source: "system_notice", content: "Finished", session: claudeSession),
    ]

    /// The files a prompt or pipeline can attach.
    static let files = [
        "README.md",
        "docs/notes.md",
        "docs/usage.md",
        "src/signup.example",
        "tests/signup.example",
    ]

    /// Model lists per agent. The names are generic on purpose.
    static let models: [String: [(id: String, name: String)]] = [
        "claude_code": [("demo-large", "Large"), ("demo-medium", "Medium"), ("demo-small", "Small")],
        "codex": [("demo-standard", "Standard"), ("demo-fast", "Fast"), ("demo-deep", "Deep")],
        "antigravity": [("demo-pro", "Pro"), ("demo-flash", "Flash")],
    ]

    /// Effort lists per agent.
    static let efforts: [String: [(id: String, name: String)]] = [
        "claude_code": [("default", "Default"), ("low", "Low Effort"), ("medium", "Medium Effort"),
                        ("high", "High Effort"), ("max", "Maximum Effort")],
        "codex": [("default", "Default"), ("low", "Low Reasoning"), ("medium", "Medium Reasoning"),
                  ("high", "High Reasoning")],
        "antigravity": [("default", "Default"), ("low", "Low Reasoning"), ("medium", "Medium Reasoning"),
                        ("high", "High Reasoning")],
    ]

    /// The session id a prompt to this agent goes to.
    static func session(for agent: String) -> String {
        switch agent {
        case "claude_code": return claudeSession
        case "codex": return codexSession
        case "antigravity": return antigravitySession
        default: return "9c4e2b60"
        }
    }
}
