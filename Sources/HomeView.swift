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
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .confirmationDialog("结束今晚的监听？", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("结束监听", role: .destructive) { monitor.stop() }
                Button("继续监听", role: .cancel) {}
            }
        }
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
                }
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
                Text(monitor.isActive ? "结束监听" : "开始监听")
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

    var body: some View {
        NavigationStack {
            Form {
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

                Section("隐私") {
                    Text("录音只保存在这台手机上，App 没有任何上传功能。")
                        .foregroundStyle(.secondary)
                }
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
