import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var monitor: MonitorEngine
    @EnvironmentObject private var store: SessionStore
    @State private var showSettings = false
    @State private var confirmStop = false

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
                        let targets = offsets.map { finishedSessions[$0].id }
                        targets.forEach { store.delete(sessionID: $0) }
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
            .sheet(isPresented: $showSettings, onDismiss: { store.cleanIfNeeded() }) {
                SettingsView()
            }
            .confirmationDialog("结束今晚的监听？", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("结束监听", role: .destructive) { monitor.stop() }
                Button("继续监听", role: .cancel) {}
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
                        Text("\(Format.shortClock(started)) 开始 · 保留 \(monitor.savedClipCount) · 丢弃 \(monitor.discardedCount)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let stopAt = monitor.autoStopAt {
                        Text("将在 \(Format.shortClock(stopAt)) 自动结束")
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
            Text("当前 \(Int(level)) dB · 底噪 \(Int(floor)) dB")
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
                Text(Format.day(session.startedAt)).font(.headline)
                if session.endedAbnormally || !session.gaps.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("有未监听的时段")
                }
            }
            Text("\(Format.shortClock(session.startedAt))–\(Format.shortClock(session.effectiveEnd)) · 梦话 \(session.count(of: .speech)) 段 · 覆盖 \(Int(session.coverageRatio * 100))%")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.triggerDB) private var triggerDB = 12.0
    @AppStorage(SettingsKey.keepSnore) private var keepSnore = false
    @AppStorage(SettingsKey.keepAll) private var keepAll = false
    @AppStorage(SettingsKey.autoStopEnabled) private var autoStopEnabled = true
    @AppStorage(SettingsKey.autoStopMinutes) private var autoStopMinutes = 480
    @AppStorage(SettingsKey.startDelayMinutes) private var startDelayMinutes = 15
    @AppStorage(SettingsKey.amplifyPlayback) private var amplifyPlayback = true
    @AppStorage(SettingsKey.autoCleanSnore) private var autoCleanSnore = false
    @AppStorage(SettingsKey.snoreRetentionDays) private var snoreRetentionDays = 30

    @State private var usage: StorageUsage?

    private func usageRow(_ title: String, _ bytes: Int64) -> some View {
        LabeledContent(title, value: StorageUsage.text(bytes))
    }

    private var autoStopTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: autoStopMinutes / 60,
                    minute: autoStopMinutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                autoStopMinutes = (parts.hour ?? 8) * 60 + (parts.minute ?? 0)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $startDelayMinutes, in: 0...240) {
                        Text(startDelayMinutes == 0 ? "延迟开始：不延迟" : "延迟开始：\(startDelayMinutes) 分钟")
                    }
                    Toggle("定时结束", isOn: $autoStopEnabled)
                    if autoStopEnabled {
                        DatePicker("结束时间", selection: autoStopTime, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("监听时段")
                } footer: {
                    Text("延迟期间麦克风会保持开启以防 App 被系统挂起，但不保存声音。长按加减号可以快速调整。修改后从下一次监听开始生效。")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("高于底噪 \(Int(triggerDB)) dB 时开始判断")
                        Slider(value: $triggerDB, in: 6...24, step: 1)
                    }
                } header: {
                    Text("触发灵敏度")
                } footer: {
                    Text("数值越小越灵敏。漏录就调小，误触发太多就调大。")
                }

                Section {
                    Toggle("保留鼾声", isOn: $keepSnore)
                    Toggle("保留所有片段（校准用）", isOn: $keepAll)
                } header: {
                    Text("保留范围")
                } footer: {
                    Text("第一晚建议打开“保留所有片段”，早上听一遍就能知道有没有被误判而丢掉的梦话。平时关闭以节省空间。")
                }

                Section {
                    Toggle("放大回放音量", isOn: $amplifyPlayback)
                } header: {
                    Text("回放")
                } footer: {
                    Text("只影响回放，不影响录音、分类和保存的文件。背景噪声也会一起变大，觉得太吵可以关闭。")
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
                } header: {
                    Text("占用空间")
                } footer: {
                    Text("统计 App 保存的数据，不含 App 本身的安装体积。")
                }

                Section {
                    Toggle("自动清理鼾声", isOn: $autoCleanSnore)
                    if autoCleanSnore {
                        Stepper(value: $snoreRetentionDays, in: 1...365) {
                            Text("保留 \(snoreRetentionDays) 天")
                        }
                    }
                } header: {
                    Text("存储")
                } footer: {
                    Text("只删除过期且未收藏的鼾声，不会删除梦话和其他片段。删除后无法恢复。")
                }

                Section("隐私") {
                    Text("录音只保存在这台手机上，App 没有任何上传功能。")
                        .foregroundStyle(.secondary)
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
