import Foundation
import Combine

/// 每晚一个文件夹：Documents/Sessions/<uuid>/session.json 加若干 .m4a。
/// 使用“首次解锁后可访问”的保护级别，否则锁屏时写不进去。
struct StorageUsage: Equatable {
    var speech: Int64 = 0
    var snore: Int64 = 0
    var other: Int64 = 0
    /// session.json、波形缓存等，以及没有登记到记录里的文件。
    var misc: Int64 = 0

    var total: Int64 { speech + snore + other + misc }

    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum Storage {
    /// 一条记录中所有音频片段占用的字节数。
    static func clipBytes(in session: Session) -> Int64 {
        session.clips.reduce(0) { $0 + fileSize(clipURL(sessionID: session.id, fileName: $1.fileName)) }
    }

    /// 统计 App 保存的数据，不含 App 本身的安装体积。
    static func usage() -> StorageUsage {
        var result = StorageUsage()
        for session in loadAll() {
            for clip in session.clips {
                let size = fileSize(clipURL(sessionID: session.id, fileName: clip.fileName))
                switch clip.kind {
                case .speech: result.speech += size
                case .snore: result.snore += size
                case .other: result.other += size
                }
            }
        }
        let everything = folderSize(root) + folderSize(WaveformLoader.cacheFolder)
        result.misc = max(0, everything - result.speech - result.snore - result.other)
        return result
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private static func folderSize(_ url: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in files {
            total += fileSize(file)
        }
        return total
    }

    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Sessions", isDirectory: true)
    }

    /// 创建录音目录，并把它排除在 iCloud 和电脑备份之外。
    static func prepareRoot() {
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// 把一个文件夹打包成临时 zip，用于导出。
    static func exportArchive(of folder: URL, named name: String) throws -> URL {
        var coordinationError: NSError?
        var result: Result<URL, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: folder,
            options: [.forUploading],
            error: &coordinationError
        ) { zipURL in
            do {
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: zipURL, to: target)
                result = .success(target)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
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
        Storage.prepareRoot()
        recoverUnfinishedSessions()
        sessions = Storage.loadAll()
    }

    /// 在后台重新读取所有记录。
    func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = Storage.loadAll()
            DispatchQueue.main.async { self.sessions = loaded }
        }
    }

    func session(id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    func delete(sessionID: UUID) {
        Storage.delete(sessionID: sessionID)
        sessions.removeAll { $0.id == sessionID }
    }

    func delete(clip: Clip, from sessionID: UUID) {
        guard var session = session(id: sessionID) else { return }
        session.clips.removeAll { $0.id == clip.id }
        removeAudio(of: clip, sessionID: sessionID)
        update(session)
    }

    /// 删除一组片段中未收藏的部分。
    func deleteUnfavorited(clips: [Clip], from sessionID: UUID) {
        guard var session = session(id: sessionID) else { return }
        let targets = clips.filter { !$0.favorite }
        let ids = Set(targets.map(\.id))
        session.clips.removeAll { ids.contains($0.id) }
        targets.forEach { removeAudio(of: $0, sessionID: sessionID) }
        update(session)
    }

    func toggleFavorite(clip: Clip, in sessionID: UUID) {
        guard var session = session(id: sessionID),
              let index = session.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        session.clips[index].favorite.toggle()
        update(session)
    }

    func setKind(_ kind: ClipKind, for clip: Clip, in sessionID: UUID) {
        guard var session = session(id: sessionID),
              let index = session.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        session.clips[index].kind = kind
        session.clips[index].kindCorrected = true
        update(session)
    }

    /// 按保留规则清理音频。只清理新版本录的片段，不动进行中的记录。
    func applyRetention(beforeNewSession: Bool) {
        let defaults = UserDefaults.standard
        let snoreDays = defaults.bool(forKey: SettingsKey.snoreCleanupEnabled)
            ? max(1, defaults.integer(forKey: SettingsKey.snoreAudioDays))
            : nil
        let now = Date()
        var changedAny = false

        for var session in Storage.loadAll() where session.endedAt != nil {
            var changed = false
            for index in session.clips.indices {
                let clip = session.clips[index]
                guard RetentionPolicy.shouldDeleteAudio(
                    clip,
                    now: now,
                    snoreDays: snoreDays,
                    beforeNewSession: beforeNewSession
                ) else { continue }
                removeAudio(of: clip, sessionID: session.id)
                session.clips[index].audioDeletedAt = now
                changed = true
            }
            if changed {
                try? Storage.save(session)
                changedAny = true
            }
        }
        if changedAny { sessions = Storage.loadAll() }
    }

    private func update(_ session: Session) {
        try? Storage.save(session)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        }
    }

    private func removeAudio(of clip: Clip, sessionID: UUID) {
        try? FileManager.default.removeItem(at: Storage.clipURL(sessionID: sessionID, fileName: clip.fileName))
        WaveformLoader.removeCache(for: clip)
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
