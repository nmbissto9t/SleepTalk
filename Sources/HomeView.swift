import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var monitor: MonitorEngine
    @EnvironmentObject private var store: SessionStore
    @State private var showSettings = false
    @State private var confirmStop = false
    @State private var pendingDeletion: Session?

    private var finishedSessions: [Session] {
        store.sessions.filter { $0.id != monitor.activeSessionID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    monitorCard
                }

                Section("记录") {
                    if finishedSessions.isEmpty {
                        Text("还没有记录。睡前点“开始监听”，然后锁屏即可。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(finishedSessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session)
                        }
                    }
                    .onDelete { offsets in
                        // 整晚删除无法恢复，先确认。
                        pendingDeletion = offsets.first.map { finishedSessions[$0] }
                    }
                }
            }
            .navigationTitle("梦话记录")
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(sessionID: id)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { store.applyRetention(beforeNewSession: false) }) {
                SettingsView()
            }
            .confirmationDialog("结束这次监听？", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("结束监听", role: .destructive) { monitor.stop() }
                Button("继续监听", role: .cancel) {}
            }
            .confirmationDialog(
                "删除这晚的全部记录？",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let target = pendingDeletion { store.delete(sessionID: target.id) }
                    pendingDeletion = nil
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("包括收藏的片段，删除后无法恢复。")
            }
        }
    }

    private var isDelayed: Bool {
        if case .delayed = monitor.status { return true }
        return false
    }

    private var monitorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: monitor.isActive ? "moon.stars.fill" : "moon")
                    .font(.title2)
                    .foregroundStyle(monitor.isActive ? Color.indigo : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(monitor.status.title).font(.headline)
                    if let started = monitor.startedAt {
                        Text("\(Format.shortClock(started)) 开始 · 梦话 \(monitor.speechClipCount) 段")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if case .delayed(let until) = monitor.status {
                HStack {
                    Text("距离开始还有")
                    Text(until, style: .timer).monospacedDigit()
                    Spacer()
                    Button("立即开始") { monitor.skipDelay() }
                        .buttonStyle(.bordered)
                }
                .font(.subheadline)
            }

            if monitor.isActive {
                LevelMeter(level: monitor.levelDB, floor: monitor.floorDB)
                Text("现在可以锁屏。不要从后台划掉 App，建议插电，并把手机放在枕边一两米内。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                if monitor.isActive {
                    confirmStop = true
                } else {
                    store.applyRetention(beforeNewSession: true)
                    monitor.start()
                }
            } label: {
                Text(monitor.isActive ? (isDelayed ? "取消" : "结束监听") : "开始监听")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(monitor.isActive ? .red : .indigo)
            .disabled(monitor.status == .starting)
        }
        .padding(.vertical, 6)
    }
}

private struct LevelMeter: View {
    let level: Float
    let floor: Float

    private func position(_ db: Float) -> CGFloat {
        CGFloat(min(1, max(0, (db + 80) / 60)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(Color.indigo)
                        .frame(width: proxy.size.width * position(level))
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2)
                        .offset(x: proxy.size.width * position(floor))
                }
            }
            .frame(height: 8)
            Text("环境音量，竖线是房间底噪")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Format.nightTitle(session.startedAt)).font(.headline)
                if session.endedAbnormally || !session.gaps.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("有未监听的时段")
                }
            }
            Text("\(Format.shortClock(session.startedAt))–\(Format.shortClock(session.effectiveEnd)) · 梦话 \(session.count(of: .speech)) 段 · 鼾声 \(Format.duration(session.seconds(of: .snore)))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.triggerDB) private var triggerDB = 12.0
    @AppStorage(SettingsKey.startDelayMinutes) private var startDelayMinutes = 15
    @AppStorage(SettingsKey.amplifyPlayback) private var amplifyPlayback = true
    @AppStorage(SettingsKey.snoreCleanupEnabled) private var snoreCleanupEnabled = true
    @AppStorage(SettingsKey.snoreAudioDays) private var snoreAudioDays = 7

    @State private var usage: StorageUsage?

    /// 界面上越大越灵敏，内部的触发门槛则相反。
    private var sensitivity: Binding<Double> {
        Binding(
            get: { 30 - triggerDB },
            set: { triggerDB = 30 - $0 }
        )
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = info?["CFBundleVersion"] as? String ?? "未知"
        return "\(version)（\(build)）"
    }

    private func usageRow(_ title: String, _ bytes: Int64) -> some View {
        LabeledContent(title, value: StorageUsage.text(bytes))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $startDelayMinutes, in: 0...240) {
                        Text(startDelayMinutes == 0 ? "延迟开始：不延迟" : "延迟开始：\(startDelayMinutes) 分钟")
                    }
                } header: {
                    Text("开始监听")
                } footer: {
                    Text("延迟期间麦克风会保持开启以防 App 被系统挂起，但不保存声音。长按加减号可以快速调整。修改后从下一次监听开始生效。")
                }

                Section {
                    Slider(value: sensitivity, in: 6...24, step: 1) {
                        Text("灵敏度")
                    } minimumValueLabel: {
                        Text("低").font(.caption)
                    } maximumValueLabel: {
                        Text("高").font(.caption)
                    }
                } header: {
                    Text("灵敏度")
                } footer: {
                    Text("小声的梦话录不到就调高，翻身等声音录得太多就调低。")
                }

                Section {
                    Toggle("放大回放音量", isOn: $amplifyPlayback)
                } header: {
                    Text("回放")
                } footer: {
                    Text("只影响回放，不影响录音、分类和保存的文件。背景噪声也会一起变大，觉得太吵可以关闭。")
                }

                Section {
                    Toggle("自动清理鼾声音频", isOn: $snoreCleanupEnabled)
                    if snoreCleanupEnabled {
                        Stepper(value: $snoreAudioDays, in: 1...365) {
                            Text("保留 \(snoreAudioDays) 天")
                        }
                    }
                } header: {
                    Text("音频保留")
                } footer: {
                    Text("梦话和收藏的片段不会自动删除。“其他”的音频保留到下次开始监听。清理后仍保留时间和统计，但无法再回放。升级前录的旧音频不会被自动清理。")
                }

                Section {
                    if let usage {
                        usageRow("总共占用", usage.total)
                        usageRow("梦话", usage.speech)
                        usageRow("鼾声", usage.snore)
                        usageRow("其他片段", usage.other)
                        usageRow("记录和缓存", usage.misc)
                    } else {
                        Text("正在统计…").foregroundStyle(.secondary)
                    }
                    ExportButton(title: "导出全部录音", folder: Storage.root, archiveName: "梦话记录-全部")
                } header: {
                    Text("占用空间")
                } footer: {
                    Text("统计 App 保存的数据，不含 App 本身的安装体积。录音不进入 iCloud 和电脑备份，卸载或换手机前请先导出。")
                }

                Section("隐私") {
                    Text("录音只保存在这台手机上，App 没有任何上传功能，只有你主动导出或分享时才会离开手机。录音可能包含同屋其他人的声音。")
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("版本", value: versionText)
                }
            }
            .task {
                usage = await Task.detached(priority: .utility) { Storage.usage() }.value
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
