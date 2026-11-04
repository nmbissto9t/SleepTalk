import Foundation
import Combine

/// 每晚一个文件夹：Documents/Sessions/<uuid>/session.json 加若干 .m4a。
/// 使用“首次解锁后可访问”的保护级别，否则锁屏时写不进去。
enum Storage {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Sessions", isDirectory: true)
    }

    static func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func ensureFolder(for id: UUID) throws -> URL {
        let url = folder(for: id)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        return url
    }

    static func clipURL(sessionID: UUID, fileName: String) -> URL {
        folder(for: sessionID).appendingPathComponent(fileName)
    }

    static func relaxProtection(of url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    static func save(_ session: Session) throws {
        let dir = try ensureFolder(for: session.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(session)
        try data.write(
            to: dir.appendingPathComponent("session.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    static func loadAll() -> [Session] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessions: [Session] = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")) else {
                return nil
            }
            return try? decoder.decode(Session.self, from: data)
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    static func delete(sessionID: UUID) {
        try? FileManager.default.removeItem(at: folder(for: sessionID))
    }

    /// 删除没有登记到 session.json 的音频（App 中途被杀时没写完的片段）。
    static func removeOrphans(in session: Session) {
        let fm = FileManager.default
        let dir = folder(for: session.id)
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let known = Set(session.clips.map(\.fileName))
        for file in files where file.pathExtension == "m4a" && !known.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }

    static func hasFreeSpace(minimumBytes: Int64 = 200_000_000) -> Bool {
        let values = try? root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > minimumBytes
    }
}

final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    init() {
        recoverUnfinishedSessions()
        reload()
    }

    func reload() {
        sessions = Storage.loadAll()
    }

    func session(id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    func delete(sessionID: UUID) {
        Storage.delete(sessionID: sessionID)
        reload()
    }

    func delete(clip: Clip, from sessionID: UUID) {
        guard var session = session(id: sessionID) else { return }
        session.clips.removeAll { $0.id == clip.id }
        try? FileManager.default.removeItem(at: Storage.clipURL(sessionID: sessionID, fileName: clip.fileName))
        try? Storage.save(session)
        reload()
    }

    /// 删除一组片段中未收藏的部分。
    func deleteUnfavorited(clips: [Clip], from sessionID: UUID) {
        guard var session = session(id: sessionID) else { return }
        let targets = clips.filter { !$0.favorite }
        let ids = Set(targets.map(\.id))
        session.clips.removeAll { ids.contains($0.id) }
        for clip in targets {
            try? FileManager.default.removeItem(at: Storage.clipURL(sessionID: sessionID, fileName: clip.fileName))
        }
        try? Storage.save(session)
        reload()
    }

    /// 开关打开时，删除超过保留天数且未收藏的鼾声。不会动梦话、其他片段和进行中的记录。
    func cleanIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.autoCleanSnore) else { return }
        let days = max(1, defaults.integer(forKey: SettingsKey.snoreRetentionDays))
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var changed = false
        for var session in Storage.loadAll() where session.endedAt != nil {
            let expired = session.clips.filter { $0.kind == .snore && !$0.favorite && $0.startedAt < cutoff }
            guard !expired.isEmpty else { continue }
            let ids = Set(expired.map(\.id))
            session.clips.removeAll { ids.contains($0.id) }
            for clip in expired {
                try? FileManager.default.removeItem(at: Storage.clipURL(sessionID: session.id, fileName: clip.fileName))
            }
            try? Storage.save(session)
            changed = true
        }
        if changed { reload() }
    }

    func toggleFavorite(clip: Clip, in sessionID: UUID) {
        guard var session = session(id: sessionID),
              let index = session.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        session.clips[index].favorite.toggle()
        try? Storage.save(session)
        reload()
    }

    /// App 启动时还没有结束标记的记录，说明上次监听被系统或手动杀掉了。
    private func recoverUnfinishedSessions() {
        for var session in Storage.loadAll() where session.endedAt == nil {
            // 延迟开始期间被杀掉：没有任何内容，不留空记录。
            if session.coverage.isEmpty && session.clips.isEmpty {
                Storage.delete(sessionID: session.id)
                continue
            }
            let end = session.coverage.last?.end ?? session.startedAt
            session.endedAt = end
            session.endedAbnormally = true
            session.events.append(LogEvent(
                date: end,
                message: "最后一次心跳后 App 没有正常结束，可能被系统回收、手动划掉或手机重启"
            ))
            Storage.removeOrphans(in: session)
            try? Storage.save(session)
        }
    }
}
