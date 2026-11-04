import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var monitor: MonitorEngine
    @StateObject private var player = ClipPlayer()
    @State private var showSnore = false
    @State private var showOther = false
    @State private var expandedGroups: Set<UUID> = []

    private var session: Session? { store.session(id: sessionID) }

    var body: some View {
        Group {
            if let session {
                content(for: session)
            } else {
                Text("这条记录已被删除").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(session.map { Format.nightTitle($0.startedAt) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
    }

    private func sortedClips(of kind: ClipKind, in session: Session) -> [Clip] {
        session.clips
            .filter { $0.kind == kind }
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func content(for session: Session) -> some View {
        let speech = sortedClips(of: .speech, in: session)
        let snore = sortedClips(of: .snore, in: session)
        let other = sortedClips(of: .other, in: session)
        let favorites = (snore + other).filter { $0.favorite && $0.hasAudio }

        return List {
            Section("这晚") {
                SessionSummaryView(session: session)
            }

            warningsSection(for: session)

            if monitor.isActive || player.errorMessage != nil {
                Section {
                    if monitor.isActive {
                        Text("监听进行中，暂时不能播放，以免声音被再次录入。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let message = player.errorMessage {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                }
            }

            Section {
                if speech.isEmpty {
                    Text("这晚没有检测到梦话")
                        .foregroundStyle(.secondary)
                }
                ForEach(speech) { clip in
                    clipRow(clip)
                }
            } header: {
                Text("梦话")
            } footer: {
                if !speech.isEmpty {
                    Text("模型只能判断“像人在说话”，也可能是别人或电视的声音。")
                }
            }

            if !favorites.isEmpty {
                Section("收藏") {
                    ForEach(favorites) { clip in
                        clipRow(clip)
                    }
                }
            }

            snoreSection(snore)
            otherSection(other, discarded: session.discardedCount)

            Section {
                ExportButton(
                    title: "导出这晚的录音",
                    folder: Storage.folder(for: session.id),
                    archiveName: "梦话记录-\(Format.nightTitle(session.startedAt))"
                )
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

    // MARK: - 提醒

    @ViewBuilder
    private func warningsSection(for session: Session) -> some View {
        let skipped = session.storageSkippedCount ?? 0
        if session.endedAbnormally || !session.gaps.isEmpty || skipped > 0 {
            Section("需要留意") {
                ForEach(session.gaps, id: \.self) { gap in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("未监听 \(Format.clock(gap.start)) – \(Format.clock(gap.end))")
                    }
                    .foregroundStyle(.orange)
                }
                if skipped > 0 {
                    Text("手机存储空间不足，有 \(skipped) 次声音没有录下来，覆盖率不能反映这部分。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if session.endedAbnormally {
                    Text("这晚的监听没有正常结束，最后一次心跳之后的情况未知。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 折叠的鼾声和其他

    private func foldHeader(icon: String, title: String, isOpen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHint(isOpen ? "收起" : "展开")
    }

    @ViewBuilder
    private func snoreSection(_ clips: [Clip]) -> some View {
        if !clips.isEmpty {
            let playable = clips.filter(\.hasAudio)
            let items = TimelineItem.build(from: playable)
            let total = clips.reduce(0) { $0 + $1.duration }
            let cleaned = clips.count - playable.count

            Section {
                foldHeader(
                    icon: ClipKind.snore.icon,
                    title: "鼾声 \(Format.duration(total)) · \(TimelineItem.build(from: clips).count) 阵",
                    isOpen: showSnore
                ) {
                    showSnore.toggle()
                }

                if showSnore {
                    if cleaned > 0 {
                        Text("有 \(cleaned) 段音频已自动清理，只保留统计。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        switch item {
                        case .single(let clip):
                            clipRow(clip)
                        case .snoreGroup(let group):
                            groupRow(group)
                            if expandedGroups.contains(group[0].id) {
                                let groupPlaylist = WavePlaybackRow.playlistID(for: group)
                                ForEach(Array(group.enumerated()), id: \.element.id) { index, clip in
                                    clipRow(
                                        clip,
                                        nested: true,
                                        isCurrent: player.playlistID == groupPlaylist && player.clipIndex == index
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func otherSection(_ clips: [Clip], discarded: Int) -> some View {
        let count = clips.count + discarded
        if count > 0 {
            let playable = clips.filter(\.hasAudio)

            Section {
                foldHeader(
                    icon: ClipKind.other.icon,
                    title: "其他动静 \(count) 次",
                    isOpen: showOther
                ) {
                    showOther.toggle()
                }

                if showOther {
                    if playable.isEmpty {
                        Text("音频已不保留，这里只统计次数。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("音频会在下次开始监听时清理。如果其中有梦话，可以改标或收藏来保留。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(playable) { clip in
                        clipRow(clip)
                    }
                }
            }
        }
    }

    // MARK: - 行

    private func groupRow(_ clips: [Clip]) -> some View {
        let first = clips[0]
        let last = clips[clips.count - 1]
        let end = Format.displayEnd(start: last.startedAt, duration: last.duration)
        let total = clips.reduce(0) { $0 + $1.duration }
        let timeInfo = progressText(for: clips) ?? "共 \(Format.duration(total))"
        let groupID = first.id
        let isExpanded = expandedGroups.contains(groupID)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.clockRange(first.startedAt, end))
                        .font(.subheadline.monospacedDigit())
                    kindLine(kind: .snore, text: "\(clips.count) 段 · \(timeInfo)")
                }
                Spacer(minLength: 8)
                Button {
                    if isExpanded {
                        expandedGroups.remove(groupID)
                    } else {
                        expandedGroups.insert(groupID)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        Text(isExpanded ? "收起" : "展开")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            WavePlaybackRow(clips: clips, sessionID: sessionID, disabled: monitor.isActive, player: player)
        }
        .padding(.vertical, 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                player.stop()
                store.deleteUnfavorited(clips: clips, from: sessionID)
            } label: {
                Label("删除未收藏", systemImage: "trash")
            }
        }
    }

    /// 这个片段或分组正在播放时返回“已播放 / 总时长”，否则返回 nil。
    private func progressText(for clips: [Clip]) -> String? {
        guard player.playlistID == WavePlaybackRow.playlistID(for: clips),
              clips.indices.contains(player.clipIndex) else { return nil }
        let index = player.clipIndex
        let before: TimeInterval = clips[..<index].reduce(0) { $0 + $1.duration }
        let total: TimeInterval = clips.reduce(0) { $0 + $1.duration }
        let elapsed = before + min(max(0, player.clipOffset), clips[index].duration)
        return "\(Format.playback(elapsed)) / \(Format.playback(total))"
    }

    /// 图标和文字贴在一起的小标题行。
    private func kindLine(kind: ClipKind, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func detailText(for clip: Clip, includeKind: Bool) -> String {
        var parts: [String] = []
        if includeKind { parts.append(clip.kind.title) }
        parts.append(progressText(for: [clip]) ?? Format.duration(clip.duration))
        // 手动改过的分类和“其他”都不是模型的判断结果，不显示可信度。
        if clip.kind != .other, clip.kindCorrected != true, clip.confidence > 0 {
            parts.append("可信度 \(Int(clip.confidence * 100))%")
        }
        return parts.joined(separator: " · ")
    }

    private func clipMenu(for clip: Clip) -> some View {
        Menu {
            if clip.hasAudio {
                ShareLink(item: Storage.clipURL(sessionID: sessionID, fileName: clip.fileName)) {
                    Label("分享或存储音频", systemImage: "square.and.arrow.up")
                }
            }
            Menu("改标为") {
                ForEach(ClipKind.allCases.filter { $0 != clip.kind }) { kind in
                    Button(kind.title) {
                        player.stop()
                        store.setKind(kind, for: clip, in: sessionID)
                    }
                }
            }
            Button(role: .destructive) {
                player.stop()
                store.delete(clip: clip, from: sessionID)
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("更多操作")
    }

    /// nested 表示展开后位于鼾声分组内；isCurrent 表示分组正播放到这一段。
    private func clipRow(_ clip: Clip, nested: Bool = false, isCurrent: Bool = false) -> some View {
        let end = Format.displayEnd(start: clip.startedAt, duration: clip.duration)

        return VStack(alignment: .leading, spacing: nested ? 2 : 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if isCurrent {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2)
                                .accessibilityLabel("正在播放这一段")
                        }
                        Text(Format.clockRange(clip.startedAt, end))
                            .font((nested ? Font.caption : Font.subheadline).monospacedDigit())
                    }
                    .foregroundStyle(isCurrent ? Color.indigo : Color.primary)
                    if nested {
                        Text(detailText(for: clip, includeKind: false))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        kindLine(kind: clip.kind, text: detailText(for: clip, includeKind: true))
                    }
                }
                Spacer(minLength: 8)
                Button {
                    store.toggleFavorite(clip: clip, in: sessionID)
                } label: {
                    Image(systemName: clip.favorite ? "star.fill" : "star")
                        .foregroundStyle(clip.favorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(clip.favorite ? "取消收藏" : "收藏")
                clipMenu(for: clip)
            }
            if clip.hasAudio {
                WavePlaybackRow(
                    clips: [clip],
                    sessionID: sessionID,
                    disabled: monitor.isActive,
                    compact: nested,
                    player: player
                )
            } else {
                Text("音频已自动清理")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
        .listRowInsets(nested ? EdgeInsets(top: 6, leading: 36, bottom: 6, trailing: 16) : nil)
        .listRowBackground(nested ? Color.indigo.opacity(0.14) : nil)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                player.stop()
                store.delete(clip: clip, from: sessionID)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

/// 打开记录时最先看到的摘要：几个关键数字，加一条整晚的事件轴。
private struct SessionSummaryView: View {
    let session: Session
    @State private var clipBytes: Int64?

    private var footnote: String {
        var text = "实际监听 \(Format.duration(session.coveredSeconds))"
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
            for kind in [ClipKind.other, ClipKind.snore, ClipKind.speech] {
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
