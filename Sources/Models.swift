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

    /// 超过 90 秒的未监听空档。
    var gaps: [CoverageRange] {
        var result: [CoverageRange] = []
        var cursor = startedAt
        for range in coverage {
            if range.start.timeIntervalSince(cursor) > 90 {
                result.append(CoverageRange(start: cursor, end: range.start))
            }
            cursor = max(cursor, range.end)
        }
        if effectiveEnd.timeIntervalSince(cursor) > 90 {
            result.append(CoverageRange(start: cursor, end: effectiveEnd))
        }
        return result
    }

    func count(of kind: ClipKind) -> Int {
        clips.filter { $0.kind == kind }.count
    }
}

enum SettingsKey {
    static let triggerDB = "triggerDB"
    static let keepSnore = "keepSnore"
    static let keepAll = "keepAll"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            triggerDB: 12.0,
            keepSnore: false,
            keepAll: false
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
