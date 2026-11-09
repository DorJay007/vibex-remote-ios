import CompanionCore
import Foundation
import Observation

/// Reader-facing text for a failed Host call: unreachable and revoked need different actions.
func describeHostFailure(_ error: Error) -> String {
    if error is URLError {
        return "无法连接电脑。请确认电脑上的 VibeX 正在运行并已开启远程连接"
    }
    if case HostError.server(let status, _) = error {
        if status == 401 {
            return "配对已失效，请在设置里重新配对"
        }
        if status == 502 || status == 503 || status == 504 {
            return "电脑当前离线或未开启云服务连接"
        }
    }
    return ServerStore.sanitizeError(error)
}

@MainActor
@Observable
final class RemoteList<Item> {
    private(set) var items: [Item]?
    private(set) var errorMessage: String?

    func load(_ fetch: () async throws -> [Item]) async {
        do {
            items = try await fetch()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = describeHostFailure(error)
        }
    }
}
