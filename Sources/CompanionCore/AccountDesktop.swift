import Foundation

/// A desktop signed into the user's VibeX account, as listed by the account host directory.
public struct AccountDesktop: Identifiable, Equatable, Sendable {
    public let hostId: String
    public let name: String
    public let osType: String?
    public let osArch: String?
    public let lastSeenAt: String?

    public var id: String { hostId }

    public init(hostId: String, name: String, osType: String?, osArch: String?, lastSeenAt: String?) {
        self.hostId = hostId
        self.name = name
        self.osType = osType
        self.osArch = osArch
        self.lastSeenAt = lastSeenAt
    }

    public var displayName: String {
        let cleaned = name.replacingOccurrences(of: ".local", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "VibeX 桌面端" : cleaned
    }

    public var osBadge: String? {
        let os = (osType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch os.lowercased() {
        case "": return nil
        case "macos", "darwin": return "macOS"
        case "windows": return "Windows"
        case "linux": return "Linux"
        default: return os
        }
    }

    /// Relay tenant origin through which the cloud service reaches this desktop.
    public func cloudOrigin(relayBase: String) -> String {
        var base = relayBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/t/\(hostId)"
    }

    /// The account directory prefixes host ids with `host:`; Host APIs and LAN health use the bare id.
    public static func rawHostId(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("host:") else { return trimmed }
        return String(trimmed.dropFirst("host:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Desktops in a `GET /api/account/desktop/host-configs` response: `hosts` ∪ `records`, local kind only,
    /// deduplicated by raw host id, most recently seen first.
    public static func parseDirectory(_ data: Data) -> [AccountDesktop] {
        struct Entry: Decodable {
            let hostId: String?
            let hostName: String?
            let kind: String?
            let osType: String?
            let osArch: String?
            let updatedAt: String?
            let lastSeenAt: String?
        }
        struct Directory: Decodable {
            let hosts: [Entry]?
            let records: [Entry]?
        }
        guard let directory = try? JSONDecoder().decode(Directory.self, from: data) else { return [] }

        var order: [String] = []
        var byId: [String: AccountDesktop] = [:]
        for entry in (directory.hosts ?? []) + (directory.records ?? []) {
            // Records without a kind come from desktops that predate host kinds, which were all local.
            guard (entry.kind ?? "local") == "local" else { continue }
            let hostId = rawHostId(entry.hostId ?? "")
     // `session:<id>` is the site's placeholder for a device login without a host
     // (phones included); there is no computer behind it to connect to.
     guard !hostId.isEmpty, !hostId.hasPrefix("session:") else { continue }
            let seenAt = [entry.lastSeenAt, entry.updatedAt].compactMap { $0 }.filter { !$0.isEmpty }.max()
            let name = (entry.hostName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let existing = byId[hostId] else {
                order.append(hostId)
                byId[hostId] = AccountDesktop(hostId: hostId, name: name, osType: entry.osType, osArch: entry.osArch, lastSeenAt: seenAt)
                continue
            }
            byId[hostId] = AccountDesktop(
                hostId: hostId,
                name: existing.name.isEmpty ? name : existing.name,
                osType: existing.osType ?? entry.osType,
                osArch: existing.osArch ?? entry.osArch,
                lastSeenAt: [existing.lastSeenAt, seenAt].compactMap { $0 }.max()
            )
        }
        let desktops = order.compactMap { byId[$0] }
        return desktops.enumerated().sorted { lhs, rhs in
            let left = lhs.element.lastSeenAt ?? ""
            let right = rhs.element.lastSeenAt ?? ""
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }
}
