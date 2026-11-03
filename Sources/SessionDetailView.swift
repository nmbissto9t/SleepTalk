import SwiftUI

struct SessionDetailView: View {
    let sessionID: UUID

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var monitor: MonitorEngine
    @StateObject private var player = ClipPlayer()
    @State private var filter: ClipFilter = .all

    private enum ClipFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case speech = "梦话"
        case favorite = "收藏"
        var id: String { rawValue }
    }

    private var session: Session? { store.session(id: sessionID) }

    private func visibleClips(in session: Session) -> [Clip] {
        let sorted = session.clips.sorted { $0.startedAt < $1.startedAt }
        switch filter {
        case .all: return sorted
        case .speech: return sorted.filter { $0.kind == .speech }
        case .favorite: return sorted.filter { $0.favorite }
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
            Section("概览") {
                LabeledContent("时段", value: "\(Format.shortClock(session.startedAt))–\(Format.shortClock(session.effectiveEnd))")
                LabeledContent("实际监听", value: "\(Format.duration(session.coveredSeconds))（\(Int(session.coverageRatio * 100))%）")
                LabeledContent("保留片段", value: "\(session.clips.count) 段")
                LabeledContent("丢弃片段", value: "\(session.discardedCount) 段")
            }

            if session.endedAbnormally || !session.gaps.isEmpty {
                Section("未监听的时段") {
                    ForEach(session.gaps, id: \.self) { gap in
                        Label(
                            "\(Format.shortClock(gap.start))–\(Format.shortClock(gap.end))",
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

                let clips = visibleClips(in: session)
                if clips.isEmpty {
                    Text("没有符合条件的片段").foregroundStyle(.secondary)
                }
                ForEach(clips) { clip in
                    clipRow(clip)
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

    private func clipRow(_ clip: Clip) -> some View {
        let url = Storage.clipURL(sessionID: sessionID, fileName: clip.fileName)
        let isPlaying = player.playingClipID == clip.id

        return HStack(spacing: 12) {
            Button {
                player.toggle(clip: clip, url: url)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.borderless)
            .disabled(monitor.isActive)
            .accessibilityLabel(isPlaying ? "停止" : "播放")

            VStack(alignment: .leading, spacing: 2) {
                Text(Format.clock(clip.startedAt)).font(.body.monospacedDigit())
                HStack(spacing: 6) {
                    Label(clip.kind.title, systemImage: clip.kind.icon)
                    Text("· \(Format.duration(clip.duration))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("\(clip.topLabel) \(Int(clip.confidence * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                if isPlaying { player.stop() }
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
