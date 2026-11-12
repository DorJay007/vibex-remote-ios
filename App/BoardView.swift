import CompanionCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private struct CardChip: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct BoardView: View {
    let client: HostClient
    var onChromeHiddenChange: ((Bool) -> Void)? = nil

    @State private var viewMode: KanbanViewMode = .columns
    @State private var projects: [ProjectSummary] = []
    @State private var selectedProjectID: String? // nil = 全部项目
    @State private var sessions: [KanbanSessionSummary] = []
    @State private var workspaces: [KanbanWorkspaceRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var noticeMessage: String?
    @State private var usageRefreshTrigger = 0

    // Two-stage vertical pull gesture state (Half-pull = Refresh, Full-pull = Usage Dashboard)
    @State private var pullOffset: CGFloat = 0
    @State private var didTriggerFullPullHaptic = false
    @State private var isPullRefreshing = false

    // Sheets & Alerts
    @State private var path = NavigationPath()
    @State private var createSheetInitialStatus: KanbanSessionStatus?
    @State private var showCreateSheet = false
    @State private var renamingSession: KanbanSessionSummary?
    @State private var renameDraft = ""
    @State private var deletingSession: KanbanSessionSummary?

    private let refreshThreshold: CGFloat = 45
    private let usageThreshold: CGFloat = 100

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if let noticeMessage {
                    noticeBanner(noticeMessage)
                }

                switch viewMode {
                case .columns:
                    columnsBoardContent
                case .usage:
                    KanbanUsageDashboardView(
                        client: client,
                        projects: projects,
                        initialProjectID: selectedProjectID,
                        refreshTrigger: usageRefreshTrigger
                    )
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(viewMode == .columns ? "看板" : "计量统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewMode == .columns {
                        projectSelectorMenu
                    } else {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                viewMode = .columns
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.subheadline.weight(.semibold))
                                Text("看板")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(viewMode == .columns ? "看板" : "计量统计")
                        .font(.headline.weight(.semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if viewMode == .columns {
                        HStack(spacing: 12) {
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    viewMode = .usage
                                }
                            } label: {
                                Image(systemName: "chart.bar.xaxis")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .accessibilityLabel("计量统计")

                            Button {
                                createSheetInitialStatus = .todo
                                showCreateSheet = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                            }
                            .accessibilityLabel("新建会话")
                        }
                    } else {
                        Button {
                            usageRefreshTrigger &+= 1
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityLabel("刷新统计")
                    }
                }
            }
            .navigationDestination(for: ConversationListItem.self) { item in
                ConversationDetailView(client: client, conversation: item)
            }
            .sheet(isPresented: $showCreateSheet) {
                KanbanCreateSessionSheet(
                    client: client,
                    projects: projects,
                    initialProjectID: selectedProjectID ?? projects.first(where: { !$0.isHome })?.id ?? projects.first?.id,
                    initialStatus: createSheetInitialStatus ?? .todo
                ) { createdItem, initialStatus in
                    Task {
                        if initialStatus != .todo {
                            try? await client.updateSessionStatus(sessionID: createdItem.id, status: initialStatus)
                        }
                        await reload()
                        path.append(createdItem)
                    }
                }
            }
            .alert(
                "重命名会话",
                isPresented: Binding(
                    get: { renamingSession != nil },
                    set: { if !$0 { renamingSession = nil } }
                )
            ) {
                TextField("会话名称", text: $renameDraft)
                Button("取消", role: .cancel) { renamingSession = nil }
                Button("保存") {
                    if let target = renamingSession {
                        performRename(target, newName: renameDraft)
                    }
                    renamingSession = nil
                }
            }
            .alert(
                "删除会话",
                isPresented: Binding(
                    get: { deletingSession != nil },
                    set: { if !$0 { deletingSession = nil } }
                ),
                presenting: deletingSession
            ) { target in
                Button("取消", role: .cancel) { deletingSession = nil }
                Button("删除", role: .destructive) {
                    performDelete(target)
                    deletingSession = nil
                }
            } message: { target in
                Text("确定删除会话“\(target.resolvedTitle)”吗？正在执行中的会话不会被删除。")
            }
        }
        .onAppear {
            onChromeHiddenChange?(!path.isEmpty)
        }
        .onChange(of: path.count) { _, count in
            onChromeHiddenChange?(count > 0)
        }
        .task {
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(errorMessage == nil ? 15 : 4))
            }
        }
    }

    // MARK: - Top Bars

    private var projectSelectorMenu: some View {
        Menu {
            Button {
                selectedProjectID = nil
                Task { await reload() }
            } label: {
                HStack {
                    Label("全部项目", systemImage: "square.stack.3d.up")
                    if selectedProjectID == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(projects) { project in
                Button {
                    selectedProjectID = project.id
                    Task { await reload() }
                } label: {
                    HStack {
                        Label(
                            project.displayName,
                            systemImage: project.isGit ? "arrow.triangle.branch" : "folder"
                        )
                        if selectedProjectID?.lowercased() == project.id.lowercased() {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedProject?.isGit == true ? "arrow.triangle.branch" : "folder.fill")
                    .font(.caption)
                Text(selectedProject?.displayName ?? "全部项目")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.footnote)
            Text(text)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                withAnimation { noticeMessage = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Four-Column Kanban Board (`builtin:columns`)

    @ViewBuilder
    private var columnsBoardContent: some View {
        if isLoading && sessions.isEmpty {
            KanbanBoardSkeletonView()
        } else if let errorMessage, sessions.isEmpty {
            Spacer()
            LoadFailureView(message: errorMessage) {
                Task { await reload() }
            }
            Spacer()
        } else {
            ZStack(alignment: .top) {
                GeometryReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(KanbanSessionStatus.activeColumns) { columnStatus in
                                kanbanColumnView(
                                    status: columnStatus,
                                    width: min(proxy.size.width - 52, 344)
                                )
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.top, 10 + min(pullOffset * 0.35, 42))
                        .padding(.bottom, 86)
                    }
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                }
                .simultaneousGesture(twoStagePullGesture)

                if pullOffset > 8 || isPullRefreshing {
                    pullFeedbackCapsule
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    private var pullFeedbackCapsule: some View {
        let isDeepPull = pullOffset >= usageThreshold
        let isHalfPull = pullOffset >= refreshThreshold && !isDeepPull
        let label: String = {
            if isPullRefreshing { return "正在刷新看板…" }
            if isDeepPull { return "松手打开计量统计" }
            if isHalfPull { return "松手刷新看板 · 继续下拉打开计量统计" }
            return "下拉刷新 · 拉到底打开计量统计"
        }()
        let iconName: String = {
            if isDeepPull { return "chart.bar.xaxis" }
            return "arrow.clockwise"
        }()

        return HStack(spacing: 6) {
            if isPullRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: iconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDeepPull ? .white : Color.accentColor)
            }
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isDeepPull ? .white : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            isDeepPull
                ? AnyShapeStyle(Color.accentColor)
                : AnyShapeStyle(.ultraThinMaterial),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(isDeepPull ? 0.25 : 0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private var twoStagePullGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .local)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard dy > 0, abs(dy) > abs(dx) * 1.2 else { return }
                let damped = min(dy * 0.65, 135)
                pullOffset = damped
                if damped >= usageThreshold && !didTriggerFullPullHaptic {
                    didTriggerFullPullHaptic = true
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    #endif
                } else if damped < usageThreshold {
                    didTriggerFullPullHaptic = false
                }
            }
            .onEnded { _ in
                let finalOffset = pullOffset
                didTriggerFullPullHaptic = false
                if finalOffset >= usageThreshold {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        pullOffset = 0
                        viewMode = .usage
                    }
                } else if finalOffset >= refreshThreshold {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        pullOffset = 0
                        isPullRefreshing = true
                    }
                    Task {
                        await reload()
                        await MainActor.run {
                            withAnimation(.easeOut(duration: 0.2)) {
                                isPullRefreshing = false
                            }
                        }
                    }
                } else {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                        pullOffset = 0
                    }
                }
            }
    }

    private func kanbanColumnView(status: KanbanSessionStatus, width: CGFloat) -> some View {
        let items = sessionsForStatus(status)
        return VStack(alignment: .leading, spacing: 0) {
            // Column Header
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 8, height: 8)
                Text(status.title)
                    .font(.subheadline.weight(.semibold))
                Text("\(items.count)")
                    .font(.footnote.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    createSheetInitialStatus = status
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color(.tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("在\(status.title)新建会话")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(statusColor(status).opacity(0.06))

            if items.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 40)
                    Text("暂无\(status.title)会话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        createSheetInitialStatus = status
                        showCreateSheet = true
                    } label: {
                        Label("新建会话", systemImage: "plus")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { session in
                            sessionCard(session, showStatusPill: false)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Reusable Session Card (`SessionHubListItem` in `kanban-board` mode)

    private func sessionCard(_ session: KanbanSessionSummary, showStatusPill: Bool) -> some View {
        let member = session.collaboration?.memberName.flatMap { $0.isEmpty ? nil : $0 }
        let showsStatus = !session.isRunning && (showStatusPill || session.status == .inreview)
        let accent = session.isRunning ? Color.orange : statusColor(session.status)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.top, 3)
                }

                Text(session.resolvedTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 4)

                Menu {
                    sessionContextMenuItems(session)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 20)
                        .contentShape(Rectangle())
                }
            }

            if let prompt = session.firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty,
               prompt != session.resolvedTitle
            {
                Text(prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if session.isRunning || showsStatus || member != nil {
                HStack(spacing: 5) {
                    if session.isRunning {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini).tint(.orange)
                            Text("进行中")
                        }
                        .modifier(CardChip(tint: .orange))
                    } else if showsStatus {
                        Text(session.status.title)
                            .modifier(CardChip(tint: statusColor(session.status)))
                    }
                    if let member {
                        HStack(spacing: 3) {
                            Image(systemName: "person.2.fill").font(.system(size: 8))
                            Text(member).lineLimit(1)
                        }
                        .modifier(CardChip(tint: .indigo))
                    }
                }
            }

            HStack(spacing: 5) {
                AgentIconView(agent: session.effectiveAgentKey, size: 13)
                Text(session.model?.isEmpty == false ? session.model! : session.agentDisplayName)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !session.workspaceDisplayLabel.isEmpty {
                    Text("·").foregroundStyle(.quaternary)
                    Text(session.workspaceDisplayLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let date = session.updatedDate {
                    Text(Self.shortRelative(date))
                        .foregroundStyle(.tertiary)
                        .layoutPriority(2)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            if session.isRunning || session.status == .inreview {
                Capsule()
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .padding(.leading, 1.5)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    session.isRunning ? Color.orange.opacity(0.35) : Color.primary.opacity(0.06),
                    lineWidth: session.isRunning ? 1 : 0.5
                )
        )
        .shadow(color: .black.opacity(0.035), radius: 3, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            openSession(session)
        }
        .contextMenu {
            sessionContextMenuItems(session)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.unitsStyle = .short
        f.dateTimeStyle = .named
        return f
    }()

    static func shortRelative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "刚刚" }
        return relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    @ViewBuilder
    private func sessionContextMenuItems(_ session: KanbanSessionSummary) -> some View {
        Button {
            openSession(session)
        } label: {
            Label("打开会话", systemImage: "bubble.left.and.bubble.right")
        }

        Menu("移动状态", systemImage: "arrow.left.arrow.right") {
            ForEach(KanbanSessionStatus.activeColumns) { status in
                Button {
                    performStatusChange(session, to: status)
                } label: {
                    HStack {
                        Text(status.title)
                        if session.status == status {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        Button {
            performTogglePin(session)
        } label: {
            Label(
                session.isPinned ? "取消置顶" : "置顶",
                systemImage: session.isPinned ? "pin.slash" : "pin"
            )
        }

        Button {
            renameDraft = session.resolvedTitle
            renamingSession = session
        } label: {
            Label("重命名会话", systemImage: "pencil")
        }

        if session.isForkSupported {
            Button {
                performFork(session)
            } label: {
                Label("从本会话 Fork", systemImage: "arrow.branch")
            }
        }

        Menu("复制") {
            Button {
                copyToClipboard(session.resolvedTitle)
                noticeMessage = "已复制会话名称"
            } label: {
                Label("会话名称", systemImage: "doc.on.doc")
            }
            Button {
                copyToClipboard(session.sessionInfoText)
                noticeMessage = "已复制会话信息"
            } label: {
                Label("会话信息", systemImage: "info.circle")
            }
        }

        Divider()

        if session.isArchived {
            Button {
                performStatusChange(session, to: .todo)
            } label: {
                Label("移至待办", systemImage: "tray.and.arrow.up")
            }
        } else {
            Button {
                performStatusChange(session, to: .archived)
            } label: {
                Label("归档", systemImage: "archivebox")
            }
        }

        Button(role: .destructive) {
            deletingSession = session
        } label: {
            Label("删除会话", systemImage: "trash")
        }
    }

    // MARK: - Computed Properties & Sorting

    private var selectedProject: ProjectSummary? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id.lowercased() == selectedProjectID.lowercased() }
    }

    private var activeSessions: [KanbanSessionSummary] {
        sessions.filter { !$0.isArchived }
    }

    private func sessionsForStatus(_ status: KanbanSessionStatus) -> [KanbanSessionSummary] {
        sortSessionsList(activeSessions.filter { $0.status == status }, by: .defaultOrder)
    }

    private func sortSessionsList(
        _ list: [KanbanSessionSummary],
        by field: KanbanSortField
    ) -> [KanbanSessionSummary] {
        list.sorted { left, right in
            if left.isPinned != right.isPinned {
                return left.isPinned && !right.isPinned
            }
            switch field {
            case .defaultOrder, .time:
                return (left.updatedDate ?? .distantPast) > (right.updatedDate ?? .distantPast)
            case .name:
                let cmp = left.resolvedTitle.localizedStandardCompare(right.resolvedTitle)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return (left.updatedDate ?? .distantPast) > (right.updatedDate ?? .distantPast)
            case .status:
                if left.status.sortOrder != right.status.sortOrder {
                    return left.status.sortOrder < right.status.sortOrder
                }
                return (left.updatedDate ?? .distantPast) > (right.updatedDate ?? .distantPast)
            case .agent:
                let cmp = left.agentDisplayName.localizedStandardCompare(right.agentDisplayName)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return (left.updatedDate ?? .distantPast) > (right.updatedDate ?? .distantPast)
            }
        }
    }

    private func statusColor(_ status: KanbanSessionStatus) -> Color {
        switch status {
        case .todo: return .blue
        case .inprogress: return .orange
        case .inreview: return .purple
        case .done: return .green
        case .archived: return .gray
        }
    }

    // MARK: - Actions & Data Loading

    private func reload() async {
        do {
            let loadedProjects = try await client.projects()
            projects = loadedProjects
            let wsIDs: [String]
            if let selectedProjectID,
               let match = loadedProjects.first(where: { $0.id.lowercased() == selectedProjectID.lowercased() })
            {
                wsIDs = match.workspaceIds
                if let wsList = try? await client.kanbanWorkspaces(projectID: match.id) {
                    workspaces = wsList
                }
            } else {
                wsIDs = loadedProjects.flatMap(\.workspaceIds)
            }
            let loadedSessions = try await client.kanbanAllSessions(workspaceIDs: wsIDs)
            sessions = loadedSessions
            errorMessage = nil
            isLoading = false
        } catch {
            errorMessage = describeHostFailure(error)
            isLoading = false
        }
    }

    private func openSession(_ session: KanbanSessionSummary) {
        if session.completesWhenViewed {
            if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[idx].status = .done
            }
            Task {
                try? await client.markSessionViewed(sessionID: session.id)
                await reload()
            }
        }
        path.append(session.asConversationListItem)
    }

    private func performStatusChange(_ session: KanbanSessionSummary, to newStatus: KanbanSessionStatus) {
        let oldStatus = session.status
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].status = newStatus
        }
        Task {
            do {
                try await client.updateSessionStatus(sessionID: session.id, status: newStatus)
                await reload()
            } catch {
                if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[idx].status = oldStatus
                }
                noticeMessage = describeHostFailure(error)
            }
        }
    }

    private func performTogglePin(_ session: KanbanSessionSummary) {
        let nextPinned = !session.isPinned
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].pinnedAt = nextPinned ? ISO8601DateFormatter().string(from: Date()) : nil
        }
        Task {
            do {
                try await client.setSessionPinned(sessionID: session.id, pinned: nextPinned)
                await reload()
            } catch {
                noticeMessage = describeHostFailure(error)
                await reload()
            }
        }
    }

    private func performRename(_ session: KanbanSessionSummary, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].name = trimmed.isEmpty ? nil : trimmed
        }
        Task {
            do {
                try await client.renameSession(sessionID: session.id, name: trimmed.isEmpty ? nil : trimmed)
                await reload()
            } catch {
                noticeMessage = describeHostFailure(error)
                await reload()
            }
        }
    }

    private func performDelete(_ session: KanbanSessionSummary) {
        let removed = session
        withAnimation {
            sessions.removeAll { $0.id == session.id }
        }
        Task {
            do {
                try await client.deleteKanbanSession(sessionID: removed.id)
                await reload()
            } catch {
                noticeMessage = describeHostFailure(error)
                await reload()
            }
        }
    }

    private func performFork(_ session: KanbanSessionSummary) {
        Task {
            do {
                if let newID = try await client.forkConversation(conversationID: session.id) {
                    noticeMessage = "已分叉会话"
                    await reload()
                    if let forked = sessions.first(where: { $0.id == newID }) {
                        openSession(forked)
                    }
                }
            } catch {
                noticeMessage = "分叉失败：\(describeHostFailure(error))"
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Create Kanban Session Sheet

private struct KanbanCreateSessionSheet: View {
    let client: HostClient
    let projects: [ProjectSummary]
    let initialProjectID: String?
    let initialStatus: KanbanSessionStatus
    let onCreated: (ConversationListItem, KanbanSessionStatus) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProjectID: String = ""
    @State private var agents: [CatalogAgent] = []
    @State private var selectedAgentID: String = "claude_code"
    @State private var selectedStatus: KanbanSessionStatus = .todo
    @State private var sessionName: String = ""
    @State private var initialPrompt: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("归属项目与状态") {
                    Picker("项目", selection: $selectedProjectID) {
                        ForEach(projects) { project in
                            Text(project.displayName).tag(project.id)
                        }
                    }

                    Picker("看板列", selection: $selectedStatus) {
                        ForEach(KanbanSessionStatus.activeColumns) { status in
                            Text(status.title).tag(status)
                        }
                    }
                }

                Section("编程代理") {
                    if agents.isEmpty {
                        HStack {
                            Text("默认代理")
                            Spacer()
                            AgentModelLabel(
                                agent: selectedAgentID,
                                model: KanbanSessionSummary.formatAgentDisplayName(selectedAgentID)
                            )
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Agent", selection: $selectedAgentID) {
                            ForEach(agents) { agent in
                                AgentMenuLabel(agentID: agent.id, hostName: agent.displayName).tag(agent.id)
                            }
                        }
                    }
                }

                Section("会话信息（可选）") {
                    TextField("会话名称（留空则自动生成）", text: $sessionName)
                    TextField("初始消息 / 任务描述（可选）", text: $initialPrompt, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("创建会话")
                        }
                    }
                    .disabled(isSubmitting || selectedWorkspaceID == nil)
                }
            }
            .onAppear {
                selectedStatus = initialStatus
                if selectedProjectID.isEmpty {
                    selectedProjectID = initialProjectID ?? projects.first?.id ?? ""
                }
            }
            .task {
                if let loaded = try? await client.agentCatalog(), !loaded.isEmpty {
                    agents = loaded
                    if let usable = loaded.first(where: \.usable) ?? loaded.first {
                        selectedAgentID = usable.id
                    }
                }
            }
        }
    }

    private var selectedWorkspaceID: String? {
        projects.first { $0.id == selectedProjectID }?.workspaceIds.first
            ?? projects.first?.workspaceIds.first
    }

    private func create() async {
        guard let workspaceID = selectedWorkspaceID else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            var created = try await client.createConversation(
                workspaceID: workspaceID,
                agentID: selectedAgentID
            )
            let trimmedName = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedName.isEmpty {
                try? await client.renameSession(sessionID: created.id, name: trimmedName)
                created = ConversationListItem(
                    id: created.id,
                    workspace_id: created.workspace_id,
                    title: trimmedName,
                    status: selectedStatus.rawValue,
                    agent_id: created.agent_id,
                    model: created.model,
                    message_count: created.message_count,
                    updated_at: created.updated_at
                )
            }
            let trimmedPrompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPrompt.isEmpty {
                try? await client.sendMessage(
                    conversationID: created.id,
                    workspaceID: workspaceID,
                    agentID: selectedAgentID,
                    text: trimmedPrompt
                )
            }
            dismiss()
            onCreated(created, selectedStatus)
        } catch {
            errorMessage = describeHostFailure(error)
        }
    }
}
