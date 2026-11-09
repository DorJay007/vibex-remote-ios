/// Device scopes from ADR-0054 (`companion` + `workstation` presets).
/// Host administration (`host.admin`, `device.pair`) is never accepted on mobile.
public enum CompanionScopes {
    public static let allowed: Set<String> = [
        "conversation.read",
        "conversation.write",
        "conversation.attach",
        "conversation.permission",
        "conversation.question",
        "conversation.cancel",
        "conversation.steer",
        "application.call",
        "plugin.read",
        "plugin.write",
        "plugin.surface",
        "artifact.read",
        "artifact.preview",
        "workflow.read",
        "workflow.write",
        "workflow.run",
        "workflow.approve",
        "automation.read",
        "automation.write",
        "delegation.read",
        "delegation.cancel",
        "notification.summary",
        "offline.read",
        "workspace.terminal",
    ]

    public static func extras(_ scopes: [String]) -> Set<String> {
        Set(scopes).subtracting(allowed)
    }
}
