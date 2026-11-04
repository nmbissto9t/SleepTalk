import Foundation

enum ClipKind: String, Codable, CaseIterable, Identifiable {
    case speech, snore, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speech: return "梦话"
        case .snore: return "鼾声"
        case .other: return "其他"
        }
    }

    var icon: String {
        switch self {
        case .speech: return "text.bubble.fill"
        case .snore: return "zzz"
        case .other: return "waveform"
        }
    }
}

struct Clip: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var fileName: String
    var startedAt: Date
    var duration: TimeInterval
    var kind: ClipKind
    /// 分类器给出的最高置信度（0...1），分类器不可用时为 0。
    var confidence: Double
    /// 除静音外置信度最高的标签，用于校准。
    var topLabel: String
    var peakDB: Float
    var favorite: Bool = false
}

/// 一段确认在监听的时间。相邻两段之间的空档就是“未监听”。
struct CoverageRange: Codable, Hashable {
    var start: Date
    var end: Date
}

struct LogEvent: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var message: String
}

struct Session: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var startedAt: Date
    var endedAt: Date?
    var endedAbnormally: Bool = false
    var coverage: [CoverageRange] = []
    var clips: [Clip] = []
    var discardedCount: Int = 0
    var events: [LogEvent] = []

    var effectiveEnd: Date {
        endedAt ?? coverage.last?.end ?? startedAt
    }

    var totalSeconds: TimeInterval {
        max(0, effectiveEnd.timeIntervalSince(startedAt))
    }

    var coveredSeconds: TimeInterval {
        coverage.reduce(0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) }
    }

    /// 监听覆盖率，0...1。
    var coverageRatio: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, coveredSeconds / totalSeconds)
    }

    /// 至少 5 秒的未监听空档。
    var gaps: [CoverageRange] {
        var result: [CoverageRange] = []
        var cursor = startedAt
        for range in coverage {
            if range.start.timeIntervalSince(cursor) >= 5 {
                result.append(CoverageRange(start: cursor, end: range.start))
            }
            cursor = max(cursor, range.end)
        }
        if effectiveEnd.timeIntervalSince(cursor) >= 5 {
            result.append(CoverageRange(start: cursor, end: effectiveEnd))
        }
        return result
    }

    func count(of kind: ClipKind) -> Int {
        clips.filter { $0.kind == kind }.count
    }

    func seconds(of kind: ClipKind) -> TimeInterval {
        clips.filter { $0.kind == kind }.reduce(0) { $0 + $1.duration }
    }
}

/// 时间线上的一项：单个片段，或一组相邻的鼾声。分组只影响显示，原始片段不变。
enum TimelineItem: Identifiable {
    case single(Clip)
    case snoreGroup([Clip])

    var id: UUID {
        switch self {
        case .single(let clip): return clip.id
        case .snoreGroup(let clips): return clips[0].id
        }
    }

    static let maximumSnoreGapSeconds: TimeInterval = 30

    static func build(from clips: [Clip]) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var pending: [Clip] = []

        func flush() {
            if pending.count == 1 {
                items.append(.single(pending[0]))
            } else if !pending.isEmpty {
                items.append(.snoreGroup(pending))
            }
            pending = []
        }

        for clip in clips.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard clip.kind == .snore else {
                flush()
                items.append(.single(clip))
                continue
            }
            if let last = pending.last {
                let previousEnd = last.startedAt.addingTimeInterval(last.duration)
                if clip.startedAt.timeIntervalSince(previousEnd) > maximumSnoreGapSeconds {
                    flush()
                }
            }
            pending.append(clip)
        }
        flush()
        return items
    }
}

enum SettingsKey {
    static let triggerDB = "triggerDB"
    static let keepSnore = "keepSnore"
    static let keepAll = "keepAll"
    static let autoStopEnabled = "autoStopEnabled"
    static let autoStopMinutes = "autoStopMinutes"
    static let startDelayMinutes = "startDelayMinutes"
    static let amplifyPlayback = "amplifyPlayback"
    static let autoCleanSnore = "autoCleanSnore"
    static let snoreRetentionDays = "snoreRetentionDays"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            triggerDB: 12.0,
            keepSnore: false,
            keepAll: false,
            autoStopEnabled: true,
            autoStopMinutes: 480,
            startDelayMinutes: 15,
            amplifyPlayback: true,
            autoCleanSnore: false,
            snoreRetentionDays: 30
        ])
    }
}

enum Format {
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let shortClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f
    }()

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
    static func shortClock(_ date: Date) -> String { shortClockFormatter.string(from: date) }
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        return "\(minutes) 分 \(total % 60) 秒"
    }
}
