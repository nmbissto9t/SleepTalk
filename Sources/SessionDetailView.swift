import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var monitor: MonitorEngine
    @StateObject private var player = ClipPlayer()
    @State private var filter: ClipFilter = .all
    @State private var expandedGroups: Set<UUID> = []

    private enum ClipFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case speech = "梦话"
        case snore = "鼾声"
        case favorite = "收藏"
        var id: String { rawValue }
    }

    private var session: Session? { store.session(id: sessionID) }

    private func timeline(in session: Session) -> [TimelineItem] {
        let sorted = session.clips.sorted { $0.startedAt < $1.startedAt }
        switch filter {
        case .all:
            return TimelineItem.build(from: sorted)
        case .snore:
            return TimelineItem.build(from: sorted.filter { $0.kind == .snore })
        case .speech:
            return sorted.filter { $0.kind == .speech }.map { TimelineItem.single($0) }
        case .favorite:
            return sorted.filter { $0.favorite }.map { TimelineItem.single($0) }
        }
    }

    var body: some View {
        Group {
            if let session {
                content(for: session)
            } else {
                Text("这条记录已被删除").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(session.map { Format.day($0.startedAt) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
    }

    private func content(for session: Session) -> some View {
        List {
            Section("这晚") {
                SessionSummaryView(session: session)
            }

            if session.endedAbnormally || !session.gaps.isEmpty {
                Section("未监听的时段") {
                    ForEach(session.gaps, id: \.self) { gap in
                        Label(
                            "\(Format.clock(gap.start)) – \(Format.clock(gap.end))",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                    if session.endedAbnormally {
                        Text("这晚的监听没有正常结束，最后一次心跳之后的情况未知。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("片段") {
                Picker("筛选", selection: $filter) {
                    ForEach(ClipFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if monitor.isActive {
                    Text("监听进行中，暂时不能播放，以免声音被再次录入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let message = player.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }

                let items = timeline(in: session)
                if items.isEmpty {
                    Text("没有符合条件的片段").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    switch item {
                    case .single(let clip):
                        clipRow(clip)
                    case .snoreGroup(let clips):
                        groupRow(clips)
                        if expandedGroups.contains(clips[0].id) {
                            ForEach(clips) { clip in
                                clipRow(clip)
                            }
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("运行日志（\(session.events.count) 条）") {
                    ForEach(session.events) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Format.clock(event.date))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(event.message).font(.footnote)
                        }
                    }
                }
            }
        }
    }

    private func groupRow(_ clips: [Clip]) -> some View {
        let first = clips[0]
        let last = clips[clips.count - 1]
        let end = last.startedAt.addingTimeInterval(last.duration)
        let total = clips.reduce(0) { $0 + $1.duration }
        let groupID = first.id
        let isExpanded = expandedGroups.contains(groupID)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Format.shortClock(first.startedAt))–\(Format.shortClock(end))")
                        .font(.body.monospacedDigit())
                    Label("鼾声 · \(clips.count) 段 · 共 \(Format.duration(total))", systemImage: ClipKind.snore.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if isExpanded {
                        expandedGroups.remove(groupID)
                    } else {
                        expandedGroups.insert(groupID)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? "收起这组片段" : "展开这组片段")
            }
            WavePlaybackRow(clips: clips, sessionID: sessionID, disabled: monitor.isActive, player: player)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                player.stop()
                store.deleteUnfavorited(clips: clips, from: sessionID)
            } label: {
                Label("删除未收藏", systemImage: "trash")
            }
        }
    }

    private func clipRow(_ clip: Clip) -> some View {
        let url = Storage.clipURL(sessionID: sessionID, fileName: clip.fileName)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.clock(clip.startedAt)).font(.body.monospacedDigit())
                    HStack(spacing: 6) {
                        Label(clip.kind.title, systemImage: clip.kind.icon)
                        Text("· \(Format.duration(clip.duration))")
                        Text("· \(clip.topLabel) \(Int(clip.confidence * 100))%")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    store.toggleFavorite(clip: clip, in: sessionID)
                } label: {
                    Image(systemName: clip.favorite ? "star.fill" : "star")
                        .foregroundStyle(clip.favorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(clip.favorite ? "取消收藏" : "收藏")
            }
            WavePlaybackRow(clips: [clip], sessionID: sessionID, disabled: monitor.isActive, player: player)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                player.stop()
                store.delete(clip: clip, from: sessionID)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            ShareLink(item: url) {
                Label("分享或存储音频", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// 打开记录时最先看到的摘要：几个关键数字，加一条整晚的事件轴。
private struct SessionSummaryView: View {
    let session: Session
    @State private var clipBytes: Int64?

    private var footnote: String {
        var text = "实际监听 \(Format.duration(session.coveredSeconds)) · 丢弃 \(session.discardedCount) 段"
        if let clipBytes {
            text += " · 录音占用 \(StorageUsage.text(clipBytes))"
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                stat(title: "梦话", value: "\(session.count(of: .speech)) 段")
                stat(title: "鼾声", value: Format.duration(session.seconds(of: .snore)))
                stat(title: "覆盖率", value: "\(Int(session.coverageRatio * 100))%")
            }

            EventAxis(session: session)
                .frame(height: 28)
                .accessibilityLabel("整晚事件分布：梦话 \(session.count(of: .speech)) 段，未监听 \(session.gaps.count) 处")

            HStack {
                Text(Format.shortClock(session.startedAt))
                Spacer()
                Text(Format.shortClock(session.effectiveEnd))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                legend(color: .indigo, title: "梦话")
                legend(color: .gray, title: "鼾声")
                legend(color: .teal, title: "其他")
                legend(color: .orange, title: "未监听")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task(id: session.clips.count) {
            let current = session
            clipBytes = await Task.detached(priority: .utility) { Storage.clipBytes(in: current) }.value
        }
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legend(color: Color, title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
        }
    }
}

private struct EventAxis: View {
    let session: Session

    var body: some View {
        Canvas { context, size in
            let start = session.startedAt
            let total = max(1, session.effectiveEnd.timeIntervalSince(start))

            func x(_ date: Date) -> CGFloat {
                let ratio = date.timeIntervalSince(start) / total
                return CGFloat(min(1, max(0, ratio))) * size.width
            }

            let background = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            context.fill(
                Path(roundedRect: background, cornerRadius: 4),
                with: .color(Color.secondary.opacity(0.12))
            )

            for gap in session.gaps {
                let rect = CGRect(
                    x: x(gap.start),
                    y: 0,
                    width: max(2, x(gap.end) - x(gap.start)),
                    height: size.height
                )
                context.fill(Path(rect), with: .color(Color.orange.opacity(0.6)))
            }

            // 梦话最后画，避免被密集的鼾声盖住。
            for kind in [ClipKind.snore, ClipKind.other, ClipKind.speech] {
                let color: Color
                switch kind {
                case .speech: color = .indigo
                case .snore: color = .gray
                case .other: color = .teal
                }
                for clip in session.clips where clip.kind == kind {
                    let left = x(clip.startedAt)
                    let right = x(clip.startedAt.addingTimeInterval(clip.duration))
                    let rect = CGRect(x: left, y: 0, width: max(2, right - left), height: size.height)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
