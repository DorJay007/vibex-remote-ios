import SwiftUI

/// 3×3 pixel grid with a chevron wavefront driving right; two fronts are always in flight.
struct PixelLoader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cycle = 650.0
    private let delays: [Double] = (0..<9).map { index in
        let row = index / 3, column = index % 3
        return Double((column + abs(row - 1)) * 90)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let now = context.date.timeIntervalSinceReferenceDate * 1000
            Grid(horizontalSpacing: 1.5, verticalSpacing: 1.5) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primary)
                                .frame(width: 4, height: 4)
                                .opacity(opacity(now: now, index: row * 3 + column))
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func opacity(now: Double, index: Int) -> Double {
        guard !reduceMotion else { return 0.15 }
        let local = (now - delays[index]).truncatingRemainder(dividingBy: cycle)
        let phase = (local < 0 ? local + cycle : local) / cycle
        return 0.15 + 0.85 * pow(sin(.pi * phase), 2)
    }
}

/// Label whose highlight sweeps across it while work is in progress.
struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let phase = (context.date.timeIntervalSinceReferenceDate / 1.4).truncatingRemainder(dividingBy: 1)
            Text(text)
                .foregroundStyle(.secondary)
                .overlay {
                    if !reduceMotion {
                        Text(text)
                            .foregroundStyle(.primary)
                            .mask {
                                GeometryReader { proxy in
                                    LinearGradient(
                                        colors: [.clear, .black, .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: proxy.size.width * 0.6)
                                    .offset(x: (phase * 1.6 - 0.3) * proxy.size.width)
                                }
                            }
                    }
                }
        }
    }
}

/// Long-running work indicator: pixel grid, shimmering label and a live elapsed timer.
struct LoadingState: View {
    let label: String
    @State private var started = Date()

    var body: some View {
        HStack(spacing: 10) {
            PixelLoader()
            ShimmerText(text: label).font(.system(size: 13, weight: .medium))
            TimelineView(.periodic(from: started, by: 0.1)) { context in
                Text(elapsed(context.date.timeIntervalSince(started)))
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private func elapsed(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? String(format: "%.1fs", seconds)
            : String(format: "%dm %.1fs", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Sweeping Shimmer Skeleton Screen System (扫光骨架屏)

/// Reusable sweeping-highlight shimmer block.
struct ShimmerBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let phase = (context.date.timeIntervalSinceReferenceDate / 1.35)
                .truncatingRemainder(dividingBy: 1.0)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.065))
                .frame(width: width, height: height)
                .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
                .overlay {
                    if !reduceMotion {
                        GeometryReader { proxy in
                            let w = max(proxy.size.width, 60)
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: Color.primary.opacity(0.085), location: 0.45),
                                    .init(color: Color.white.opacity(0.22), location: 0.50),
                                    .init(color: Color.primary.opacity(0.085), location: 0.55),
                                    .init(color: .clear, location: 1.0),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .frame(width: w * 0.85)
                            .offset(x: (phase * 2.1 - 0.65) * w)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                }
        }
        .accessibilityHidden(true)
    }
}

/// Circular sweeping-highlight shimmer avatar/icon placeholder.
struct ShimmerCircle: View {
    let size: CGFloat

    var body: some View {
        ShimmerBlock(width: size, height: size, cornerRadius: size / 2)
    }
}

/// 1. Conversation Timeline Skeleton (对话详情流骨架屏)
struct ConversationTimelineSkeletonView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // User message bubble on right
                HStack {
                    Spacer(minLength: 72)
                    VStack(alignment: .trailing, spacing: 6) {
                        ShimmerBlock(width: 210, height: 38, cornerRadius: 16)
                    }
                }

                // Assistant turn 1
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ShimmerCircle(size: 22)
                        ShimmerBlock(width: 110, height: 13, cornerRadius: 5)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        ShimmerBlock(width: 96, height: 24, cornerRadius: 12)
                        ShimmerBlock(width: 124, height: 24, cornerRadius: 12)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ShimmerBlock(height: 14, cornerRadius: 6)
                        ShimmerBlock(height: 14, cornerRadius: 6)
                        ShimmerBlock(width: 240, height: 14, cornerRadius: 6)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }

                // User message bubble 2
                HStack {
                    Spacer(minLength: 96)
                    ShimmerBlock(width: 168, height: 36, cornerRadius: 16)
                }

                // Assistant turn 2
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ShimmerCircle(size: 22)
                        ShimmerBlock(width: 96, height: 13, cornerRadius: 5)
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ShimmerBlock(height: 14, cornerRadius: 6)
                        ShimmerBlock(width: 280, height: 14, cornerRadius: 6)
                        ShimmerBlock(width: 190, height: 14, cornerRadius: 6)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 2. Kanban Board Skeleton (四列看板骨架屏)
struct KanbanBoardSkeletonView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ShimmerCircle(size: 10)
                    ShimmerBlock(width: 88, height: 16, cornerRadius: 6)
                    Spacer()
                    ShimmerBlock(width: 28, height: 18, cornerRadius: 9)
                }
                .padding(.horizontal, 4)

                ForEach(0..<4, id: \.self) { idx in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            ShimmerCircle(size: 20)
                            ShimmerBlock(width: idx % 2 == 0 ? 180 : 140, height: 15, cornerRadius: 6)
                            Spacer()
                            ShimmerBlock(width: 52, height: 18, cornerRadius: 9)
                        }
                        ShimmerBlock(height: 13, cornerRadius: 5)
                        ShimmerBlock(width: 220, height: 13, cornerRadius: 5)
                        HStack(spacing: 8) {
                            ShimmerBlock(width: 72, height: 20, cornerRadius: 6)
                            ShimmerBlock(width: 84, height: 20, cornerRadius: 6)
                            Spacer()
                            ShimmerBlock(width: 48, height: 12, cornerRadius: 4)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 3. Usage Dashboard Skeleton (计量与统计面板骨架屏)
struct UsageDashboardSkeletonView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            ShimmerBlock(width: 72, height: 12, cornerRadius: 4)
                            ShimmerBlock(width: 110, height: 22, cornerRadius: 6)
                            ShimmerBlock(width: 88, height: 11, cornerRadius: 4)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    ShimmerBlock(width: 128, height: 15, cornerRadius: 6)
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach([48.0, 82.0, 64.0, 108.0, 74.0, 96.0, 56.0, 88.0], id: \.self) { h in
                            ShimmerBlock(height: h, cornerRadius: 6)
                        }
                    }
                    .frame(height: 116)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )

                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 12) {
                        ShimmerCircle(size: 32)
                        VStack(alignment: .leading, spacing: 6) {
                            ShimmerBlock(width: 140, height: 14, cornerRadius: 5)
                            ShimmerBlock(width: 96, height: 11, cornerRadius: 4)
                        }
                        Spacer()
                        ShimmerBlock(width: 64, height: 16, cornerRadius: 5)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 4. Collaboration Space List Skeleton (协作空间列表骨架屏)
struct CollaborationListSkeletonView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ShimmerBlock(height: 38, cornerRadius: 10)

                ForEach(0..<5, id: \.self) { idx in
                    HStack(spacing: 12) {
                        ShimmerBlock(width: 42, height: 42, cornerRadius: idx == 0 ? 21 : 13)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                ShimmerBlock(width: idx % 2 == 0 ? 116 : 92, height: 15, cornerRadius: 5)
                                Spacer()
                                ShimmerBlock(width: 42, height: 11, cornerRadius: 4)
                            }
                            ShimmerBlock(width: idx % 2 == 0 ? 210 : 168, height: 12, cornerRadius: 4)
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 5. Collaboration Chat Skeleton (协作空间对话流骨架屏)
struct CollaborationChatSkeletonView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { idx in
                    if idx % 2 == 1 {
                        HStack {
                            Spacer(minLength: 64)
                            ShimmerBlock(width: 186, height: 42, cornerRadius: 14)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 10) {
                            ShimmerCircle(size: 32)
                            VStack(alignment: .leading, spacing: 6) {
                                ShimmerBlock(width: 84, height: 12, cornerRadius: 4)
                                ShimmerBlock(width: 236, height: 54, cornerRadius: 14)
                            }
                            Spacer(minLength: 36)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 6. Settings / Skills / MCP / Plugins List Skeleton (设置与技能扩展列表骨架屏)
struct SettingsListSkeletonView: View {
    var rows: Int = 4

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(0..<rows, id: \.self) { idx in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            ShimmerBlock(width: 28, height: 28, cornerRadius: 7)
                            ShimmerBlock(width: idx % 2 == 0 ? 148 : 116, height: 15, cornerRadius: 5)
                            Spacer()
                            ShimmerBlock(width: 46, height: 18, cornerRadius: 9)
                        }
                        ShimmerBlock(height: 12, cornerRadius: 4)
                        ShimmerBlock(width: 196, height: 12, cornerRadius: 4)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 7. File Tree & Diff List Skeleton (文件树与代码差异骨架屏)
struct FileTreeSkeletonView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(0..<7, id: \.self) { idx in
                    HStack(spacing: 12) {
                        ShimmerBlock(width: 22, height: 22, cornerRadius: 5)
                        VStack(alignment: .leading, spacing: 5) {
                            ShimmerBlock(width: idx % 2 == 0 ? 164 : 122, height: 14, cornerRadius: 5)
                            ShimmerBlock(width: 96, height: 10, cornerRadius: 4)
                        }
                        Spacer()
                        ShimmerBlock(width: 34, height: 13, cornerRadius: 4)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 8. Code / Diff File Content Skeleton (代码与文件预览骨架屏)
struct CodeFileSkeletonView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                ForEach([0.72, 0.48, 0.86, 0.64, 0.35, 0.78, 0.56, 0.82, 0.44, 0.68, 0.52, 0.76], id: \.self) { ratio in
                    GeometryReader { geo in
                        HStack(spacing: 10) {
                            ShimmerBlock(width: 26, height: 12, cornerRadius: 4)
                            ShimmerBlock(width: max(60, (geo.size.width - 44) * ratio), height: 12, cornerRadius: 4)
                        }
                    }
                    .frame(height: 14)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 9. Account Card Skeleton (账号卡片骨架屏)
struct AccountCardSkeletonView: View {
    var body: some View {
        HStack(spacing: 12) {
            ShimmerCircle(size: 46)
            VStack(alignment: .leading, spacing: 6) {
                ShimmerBlock(width: 128, height: 16, cornerRadius: 5)
                ShimmerBlock(width: 186, height: 12, cornerRadius: 4)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
