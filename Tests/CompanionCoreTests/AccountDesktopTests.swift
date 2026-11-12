import Foundation
import Testing
@testable import CompanionCore

@Test func accountDirectoryListsLocalDesktopsOnce() {
    let json = """
{
"hosts": [
{"hostId":"host:abc","hostName":"MacBook-Pro.local","kind":"local","osType":"macos","osArch":"arm64","agents":[],"updatedAt":"2026-11-01T08:00:00Z"},
{"hostId":"host:ssh1","hostName":"build-box","kind":"ssh","osType":"linux","osArch":"x86_64","agents":[],"updatedAt":"2026-11-10T08:00:00Z"},
{"hostId":"host:web1","hostName":"Browser","kind":"web","osType":"","osArch":"","agents":[],"updatedAt":"2026-11-10T08:00:00Z"}
],
"records": [
{"hostId":"host:abc","hostName":"MacBook-Pro","kind":"local","osType":"macos","osArch":"arm64","lastSeenAt":"2026-11-11T09:00:00Z","configSynced":true},
{"hostId":"host:win","hostName":"Office-PC","kind":"local","osType":"windows","osArch":"x86_64","lastSeenAt":"2026-11-05T09:00:00Z","configSynced":false},
{"hostId":"host:old","hostName":"Legacy","osType":"linux","osArch":"x86_64","lastSeenAt":"2026-10-01T09:00:00Z","configSynced":false},
{"hostId":"host:","hostName":"Empty","kind":"local","lastSeenAt":"2026-11-12T09:00:00Z","configSynced":false}
]
}
"""
    let desktops = AccountDesktop.parseDirectory(Data(json.utf8))
    #expect(desktops.map(\.hostId) == ["abc", "win", "old"])
    #expect(desktops[0].displayName == "MacBook-Pro")
    #expect(desktops[0].lastSeenAt == "2026-11-11T09:00:00Z")
    #expect(desktops[0].osBadge == "macOS")
    #expect(desktops[1].osBadge == "Windows")
}

@Test func accountDirectorySkipsDeviceLoginsWithoutAHost() {
    let json = """
{"records":[
{"hostId":"session:42","hostName":"iPhone","kind":"local","lastSeenAt":"2026-11-12T11:00:00Z","configSynced":false},
{"hostId":"host:mac","hostName":"Mac","kind":"local","lastSeenAt":"2026-11-12T10:00:00Z","configSynced":true}
]}
"""
    #expect(AccountDesktop.parseDirectory(Data(json.utf8)).map(\.hostId) == ["mac"])
}

@Test func accountDirectoryToleratesMissingLists() {
    #expect(AccountDesktop.parseDirectory(Data("{}".utf8)).isEmpty)
    #expect(AccountDesktop.parseDirectory(Data("not json".utf8)).isEmpty)
}

@Test func accountDesktopBuildsRelayTenantOrigin() {
    #expect(AccountDesktop.rawHostId(" host:abc ") == "abc")
    #expect(AccountDesktop.rawHostId("abc") == "abc")
    let desktop = AccountDesktop(hostId: "abc", name: "Mac", osType: nil, osArch: nil, lastSeenAt: nil)
    #expect(desktop.cloudOrigin(relayBase: "https://relay.example.com/") == "https://relay.example.com/t/abc")
}
