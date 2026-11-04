import XCTest
@testable import SleepTalk

final class SleepTalkTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func clip(
        _ kind: ClipKind,
        at offset: TimeInterval,
        duration: TimeInterval = 6,
        favorite: Bool = false,
        autoCleanable: Bool? = true
    ) -> Clip {
        var clip = Clip(
            fileName: "\(UUID().uuidString).m4a",
            startedAt: base.addingTimeInterval(offset),
            duration: duration,
            kind: kind,
            confidence: 0.8,
            topLabel: "test",
            peakDB: -20
        )
        clip.favorite = favorite
        clip.autoCleanable = autoCleanable
        return clip
    }

    // MARK: - 鼾声分组

    func testAdjacentSnoresBecomeOneGroup() {
        let items = TimelineItem.build(from: [clip(.snore, at: 0), clip(.snore, at: 10), clip(.snore, at: 40)])
        XCTAssertEqual(items.count, 1)
        guard case .snoreGroup(let clips) = items[0] else { return XCTFail("应该合成一组") }
        XCTAssertEqual(clips.count, 3)
    }

    func testLargeGapSplitsSnoreGroups() {
        let items = TimelineItem.build(from: [clip(.snore, at: 0), clip(.snore, at: 10), clip(.snore, at: 100)])
        XCTAssertEqual(items.count, 2)
        guard case .single = items[1] else { return XCTFail("孤立的鼾声应该单独显示") }
    }

    func testSpeechBreaksSnoreGroup() {
        let items = TimelineItem.build(from: [clip(.snore, at: 0), clip(.speech, at: 8), clip(.snore, at: 16)])
        XCTAssertEqual(items.count, 3)
    }

    // MARK: - 覆盖率

    func testCoverageAndGaps() {
        var session = Session(startedAt: base)
        session.endedAt = base.addingTimeInterval(1000)
        session.coverage = [
            CoverageRange(start: base, end: base.addingTimeInterval(400)),
            CoverageRange(start: base.addingTimeInterval(500), end: base.addingTimeInterval(1000))
        ]
        XCTAssertEqual(session.coverageRatio, 0.9, accuracy: 0.001)
        XCTAssertEqual(session.gaps.count, 1)
        XCTAssertEqual(session.gaps[0].start, base.addingTimeInterval(400))
    }

    func testVeryShortGapIsNotListed() {
        var session = Session(startedAt: base)
        session.endedAt = base.addingTimeInterval(100)
        session.coverage = [
            CoverageRange(start: base, end: base.addingTimeInterval(50)),
            CoverageRange(start: base.addingTimeInterval(52), end: base.addingTimeInterval(100))
        ]
        XCTAssertTrue(session.gaps.isEmpty)
        XCTAssertEqual(session.coverageRatio, 0.98, accuracy: 0.001)
    }

    // MARK: - 保留规则

    func testSpeechAudioIsNeverDeleted() {
        let old = clip(.speech, at: -9_000_000)
        XCTAssertFalse(RetentionPolicy.shouldDeleteAudio(old, now: base, snoreDays: 1, beforeNewSession: true))
    }

    func testFavoriteIsNeverDeleted() {
        let favorite = clip(.other, at: -100, favorite: true)
        XCTAssertFalse(RetentionPolicy.shouldDeleteAudio(favorite, now: base, snoreDays: 1, beforeNewSession: true))
    }

    func testOldVersionClipsAreNeverDeleted() {
        let legacy = clip(.other, at: -100, autoCleanable: nil)
        XCTAssertFalse(RetentionPolicy.shouldDeleteAudio(legacy, now: base, snoreDays: 1, beforeNewSession: true))
    }

    func testOtherIsDeletedOnlyBeforeNewSession() {
        let other = clip(.other, at: -100)
        XCTAssertFalse(RetentionPolicy.shouldDeleteAudio(other, now: base, snoreDays: 7, beforeNewSession: false))
        XCTAssertTrue(RetentionPolicy.shouldDeleteAudio(other, now: base, snoreDays: 7, beforeNewSession: true))
    }

    func testSnoreFollowsRetentionDays() {
        let recent = clip(.snore, at: -86_400 * 6)
        let expired = clip(.snore, at: -86_400 * 8)
        XCTAssertFalse(RetentionPolicy.shouldDeleteAudio(recent, now: base, snoreDays: 7, beforeNewSession: false))
        XCTAssertTrue(RetentionPolicy.shouldDeleteAudio(expired, now: base, snoreDays: 7, beforeNewSession: false))
        XCTAssertFalse(RetentionPolicy.shouldDeleteAudio(expired, now: base, snoreDays: nil, beforeNewSession: false))
    }

    func testDeletedAudioIsNotDeletedAgain() {
        var other = clip(.other, at: -100)
        other.audioDeletedAt = base
        XCTAssertFalse(RetentionPolicy.shouldDeleteAudio(other, now: base, snoreDays: 7, beforeNewSession: true))
    }

    // MARK: - 时间显示

    private func date(_ day: Int, _ hour: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    func testNightTitle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        XCTAssertEqual(Format.nightTitle(date(4, 1, calendar: calendar), calendar: calendar), "11月3日夜")
        XCTAssertEqual(Format.nightTitle(date(3, 23, calendar: calendar), calendar: calendar), "11月3日夜")
        XCTAssertEqual(Format.nightTitle(date(4, 14, calendar: calendar), calendar: calendar), "11月4日 14:00")
    }

    func testDisplayEndMatchesRoundedDuration() {
        let start = Date(timeIntervalSince1970: 1000.7)
        let end = Format.displayEnd(start: start, duration: 7.6)
        XCTAssertEqual(end.timeIntervalSince1970, 1008)
    }

    func testPlaybackText() {
        XCTAssertEqual(Format.playback(5), "0:05")
        XCTAssertEqual(Format.playback(157), "2:37")
    }

    // MARK: - 波形定位

    func testWaveformLocationRoundTrip() {
        let model = WaveformModel(
            bars: [0.1, 0.2, -1, 0.3, 0.4, 0.5, 0.6],
            clipStarts: [0, 3],
            clipCounts: [2, 4],
            durations: [10, 40],
            peak: 0.6
        )
        XCTAssertEqual(model.barPosition(clipIndex: 1, offset: 20), 5, accuracy: 0.001)
        let location = model.location(atFraction: 5.0 / 7.0)
        XCTAssertEqual(location.index, 1)
        XCTAssertEqual(location.offset, 20, accuracy: 0.001)
    }

    // MARK: - 旧数据兼容

    func testOldSessionJSONStillDecodes() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "startedAt": "2026-11-03T15:00:00Z",
          "endedAt": "2026-11-03T22:00:00Z",
          "endedAbnormally": false,
          "coverage": [],
          "discardedCount": 2,
          "events": [],
          "clips": [{
            "id": "22222222-2222-2222-2222-222222222222",
            "fileName": "a.m4a",
            "startedAt": "2026-11-03T16:00:00Z",
            "duration": 6,
            "kind": "other",
            "confidence": 0.5,
            "topLabel": "breathing",
            "peakDB": -30,
            "favorite": false
          }]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertNil(session.clips[0].autoCleanable)
        XCTAssertTrue(session.clips[0].hasAudio)
        XCTAssertFalse(RetentionPolicy.shouldDeleteAudio(
            session.clips[0],
            now: Date(),
            snoreDays: 1,
            beforeNewSession: true
        ))
    }
}
