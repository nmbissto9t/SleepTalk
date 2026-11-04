import Accelerate
import AVFoundation
import Combine
import SoundAnalysis
import UIKit

/// 整夜监听的核心。除 @Published 属性外，所有状态只在 `queue` 上读写。
///
/// 流程：麦克风 → 计算音量 → 高于底噪时开始录片段（连同预录缓存）
///      → 同时送入系统声音分类器 → 安静后根据分类结果决定保留或丢弃。
final class MonitorEngine: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case calibrating
        case delayed(until: Date)
        case listening
        case capturing
        case interrupted
        case failed(String)

        var title: String {
            switch self {
            case .stopped: return "未开始"
            case .starting: return "正在启动…"
            case .calibrating: return "正在适应房间底噪…"
            case .delayed: return "延迟开始中，暂不录音"
            case .listening: return "监听中"
            case .capturing: return "正在录制片段"
            case .interrupted: return "被打断，等待恢复"
            case .failed(let message): return message
            }
        }
    }

    // 调参集中放在这里，实测后主要改这几个值。
    private enum Tuning {
        static let preRollSeconds = 3.0
        static let calibrationSeconds = 3.0
        static let triggerHoldSeconds = 0.15
        static let quietTailSeconds = 3.0
        static let maxClipSeconds = 120.0
        static let classifierWindowSeconds = 1.5
        static let speechThreshold = 0.4
        static let snoreThreshold = 0.5
        static let heartbeatSeconds = 30
        static let stallSeconds = 10.0
        static let coverageJoinSeconds = 90.0
        static let minimumFloorDB: Float = -75
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var levelDB: Float = -80
    @Published private(set) var floorDB: Float = -80
    @Published private(set) var speechClipCount = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var activeSessionID: UUID?

    var isActive: Bool { activeSessionID != nil }

    /// 在主线程调用。
    var onSessionEnded: (() -> Void)?

    private let queue = DispatchQueue(label: "sleeptalk.monitor", qos: .userInitiated)
    private var engine = AVAudioEngine()
    private var format: AVAudioFormat?
    private var observers: [NSObjectProtocol] = []
    private var heartbeat: DispatchSourceTimer?
    private var heartbeatTick = 0

    private var wanted = false
    private var session: Session?
    private var capture: Capture?
    private var isForeground = true
    private var currentStatus: Status = .stopped

    private var ring: [AVAudioPCMBuffer] = []
    private var ringSeconds = 0.0
    private var noiseFloor: Float?
    private var loudSeconds = 0.0
    private var calibrateUntil = Date.distantPast
    private var lastBufferAt = Date.distantPast
    private var lastLevelPublish = Date.distantPast

    private var restartPending = false
    private var inOutage = false

    /// 延迟开始结束后才为 true；此前麦克风保持运行以免被系统挂起，但不录制片段。
    private var armed = false
    private var armedAt = Date.distantPast
    private var coverageOpen = false

    private var triggerDB: Float = 12

    init() {
        registerObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 对外接口（主线程调用）

    func start() {
        guard !isActive else { return }
        status = .starting
        let battery = Self.batteryDescription()
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.status = .failed("没有麦克风权限，请到“设置”里开启")
                }
                return
            }
            self.queue.async { self.beginSession(battery: battery) }
        }
    }

    func stop() {
        guard isActive else { return }
        let battery = Self.batteryDescription()
        queue.async { self.endSession(battery: battery) }
    }

    /// 跳过剩余的延迟时间，立即开始记录。
    func skipDelay() {
        queue.async {
            guard self.wanted, !self.armed else { return }
            self.armedAt = Date()
        }
    }

    func setForeground(_ foreground: Bool) {
        queue.async { self.isForeground = foreground }
    }

    private static func batteryDescription() -> String {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel < 0 ? "未知" : "\(Int(device.batteryLevel * 100))%"
        let charging = device.batteryState == .charging || device.batteryState == .full
        return "电量 \(level)，\(charging ? "已插电" : "未插电")"
    }

    // MARK: - 会话生命周期

    private func beginSession(battery: String) {
        loadSettings()
        let now = Date()
        let storedDelay = UserDefaults.standard.integer(forKey: SettingsKey.startDelayMinutes)
        let delayMinutes = max(0, min(240, storedDelay))
        var newSession = Session(startedAt: now.addingTimeInterval(Double(delayMinutes) * 60))
        do {
            _ = try Storage.ensureFolder(for: newSession.id)
            newSession.events.append(LogEvent(date: now, message: "启动监听，\(battery)"))
            session = newSession
            wanted = true
            noiseFloor = nil
            inOutage = false
            armed = false
            armedAt = newSession.startedAt
            coverageOpen = false
            heartbeatTick = 0
            try startAudio()
            if delayMinutes == 0 {
                arm(at: now)
            } else {
                log("延迟 \(delayMinutes) 分钟后开始记录，期间不保存声音")
            }
            startHeartbeat()
            saveSession()
            let id = newSession.id
            DispatchQueue.main.async {
                self.activeSessionID = id
                self.speechClipCount = 0
            }
        } catch {
            wanted = false
            session = nil
            Storage.delete(sessionID: newSession.id)
            stopAudio()
            publish(status: .failed("启动失败：\(error.localizedDescription)"))
        }
    }

    private func arm(at now: Date) {
        armed = true
        ring.removeAll()
        ringSeconds = 0
        loudSeconds = 0
        session?.startedAt = now
        log("开始记录")
        markCoverage(now)
        saveSession()
        DispatchQueue.main.async {
            self.startedAt = now
        }
    }

    private func endSession(battery: String) {
        guard wanted else { return }
        wanted = false
        if capture != nil { finishCapture() }
        // finishCapture 把收尾排在队列里，这里排在它之后执行。
        queue.async {
            self.heartbeat?.cancel()
            self.heartbeat = nil
            self.stopAudio()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            let now = Date()
            if self.armed {
                if self.coverageOpen { self.markCoverage(now) }
                self.log("结束监听，\(battery)")
                self.session?.endedAt = now
                self.saveSession()
            } else if let id = self.session?.id {
                // 延迟期间就结束了：没有任何内容，不留空记录。
                Storage.delete(sessionID: id)
            }
            self.session = nil
            self.coverageOpen = false
            self.armed = false
            self.currentStatus = .stopped
            DispatchQueue.main.async {
                self.status = .stopped
                self.activeSessionID = nil
                self.startedAt = nil
                self.onSessionEnded?()
            }
        }
    }

    // MARK: - 音频引擎

    private func startAudio() throws {
        let audioSession = AVAudioSession.sharedInstance()
        // mixWithOthers：被打断后在后台也更容易重新激活。
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try audioSession.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MonitorError.microphoneUnavailable
        }

        input.removeTap(onBus: 0)
        format = inputFormat
        ring.removeAll()
        ringSeconds = 0
        loudSeconds = 0

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let copy = buffer.deepCopy() else { return }
            self.queue.async { self.process(copy) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        lastBufferAt = Date()
        calibrateUntil = Date().addingTimeInterval(Tuning.calibrationSeconds)
        publish(status: .calibrating)
    }

    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func scheduleRestart(after delay: TimeInterval) {
        guard wanted, !restartPending else { return }
        restartPending = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            self.restartAudio()
        }
    }

    private func restartAudio() {
        guard wanted else { return }
        if capture != nil { finishCapture() }
        closeCoverage()
        stopAudio()
        do {
            try startAudio()
            if inOutage {
                log("监听已恢复")
                inOutage = false
            }
            markCoverage(Date())
            saveSession()
        } catch {
            if !inOutage {
                log("恢复监听失败，将继续重试：\(error.localizedDescription)")
                inOutage = true
                saveSession()
            }
            publish(status: .interrupted)
        }
    }

    // MARK: - 系统通知

    private func registerObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let info = note.userInfo
            let rawType = info?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
            self.queue.async { self.handleInterruption(type) }
        })

        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let source = note.object as? AVAudioEngine
            self.queue.async {
                guard source === self.engine else { return }
                self.handleConfigurationChange()
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleMediaReset() }
        })
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard wanted else { return }
        switch type {
        case .began:
            log("被系统打断（来电、闹钟或其他音频）")
            inOutage = true
            closeCoverage()
            if capture != nil { finishCapture() }
            publish(status: .interrupted)
            saveSession()
        case .ended:
            log("打断结束，尝试恢复")
            scheduleRestart(after: 1)
        default:
            break
        }
    }

    private func handleConfigurationChange() {
        guard wanted else { return }
        let current = engine.inputNode.outputFormat(forBus: 0)
        if engine.isRunning, current == format { return }
        log("音频配置变化，重新启动监听")
        scheduleRestart(after: 0.5)
    }

    private func handleMediaReset() {
        guard wanted else { return }
        log("系统音频服务重置，重建音频引擎")
        inOutage = true
        closeCoverage()
        if capture != nil { finishCapture() }
        engine = AVAudioEngine()
        scheduleRestart(after: 1)
    }

    // MARK: - 心跳与覆盖记录

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(Tuning.heartbeatSeconds),
                       repeating: .seconds(Tuning.heartbeatSeconds))
        timer.setEventHandler { [weak self] in self?.onHeartbeat() }
        timer.resume()
        heartbeat = timer
    }

    private func onHeartbeat() {
        guard wanted else { return }
        loadSettings()
        let now = Date()
        let alive = engine.isRunning && now.timeIntervalSince(lastBufferAt) < Tuning.stallSeconds
        if alive {
            markCoverage(now)
        } else {
            if !inOutage {
                log("麦克风没有数据，尝试恢复")
                inOutage = true
            }
            closeCoverage()
            scheduleRestart(after: 0)
        }
        heartbeatTick += 1
        if heartbeatTick % 2 == 0 || !alive { saveSession() }
    }

    private func markCoverage(_ now: Date) {
        guard armed, var current = session else { return }
        if coverageOpen, var last = current.coverage.last,
           now.timeIntervalSince(last.end) <= Tuning.coverageJoinSeconds {
            last.end = now
            current.coverage[current.coverage.count - 1] = last
        } else {
            if let last = current.coverage.last, now.timeIntervalSince(last.end) >= 5 {
                current.events.append(LogEvent(
                    date: now,
                    message: "发现未监听空档：\(Format.clock(last.end)) – \(Format.clock(now))"
                ))
            }
            current.coverage.append(CoverageRange(start: now, end: now))
            coverageOpen = true
        }
        session = current
    }

    /// 监听中断时调用：覆盖范围只算到最后一次真正收到麦克风数据的时刻。
    private func closeCoverage() {
        guard coverageOpen, var current = session, var last = current.coverage.last else { return }
        coverageOpen = false
        last.end = max(last.start, max(last.end, lastBufferAt))
        current.coverage[current.coverage.count - 1] = last
        session = current
    }

    // MARK: - 音频处理

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard wanted, buffer.format == format else { return }

        let now = Date()
        lastBufferAt = now
        let db = buffer.rmsDB()
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate

        if let active = capture {
            continueCapture(active, buffer: buffer, db: db, seconds: seconds)
        } else {
            processIdle(buffer, db: db, seconds: seconds, now: now)
        }

        if isForeground, now.timeIntervalSince(lastLevelPublish) > 0.25 {
            lastLevelPublish = now
            let floorValue = noiseFloor ?? db
            DispatchQueue.main.async {
                self.levelDB = db
                self.floorDB = floorValue
            }
        }
    }

    private func processIdle(_ buffer: AVAudioPCMBuffer, db: Float, seconds: Double, now: Date) {
        ring.append(buffer)
        ringSeconds += seconds
        while ring.count > 1, ringSeconds - Double(ring[0].frameLength) / ring[0].format.sampleRate > Tuning.preRollSeconds {
            ringSeconds -= Double(ring[0].frameLength) / ring[0].format.sampleRate
            ring.removeFirst()
        }

        let floorValue = noiseFloor ?? db
        // 底噪：向下快速跟随，向上缓慢跟随（约 10 秒）。
        let rate: Float = db < floorValue ? 0.2 : 0.01
        let updated = max(Tuning.minimumFloorDB, floorValue + (db - floorValue) * rate)
        noiseFloor = updated

        if now < calibrateUntil {
            noiseFloor = max(Tuning.minimumFloorDB, floorValue + (db - floorValue) * 0.2)
            return
        }

        if !armed {
            if now >= armedAt {
                arm(at: now)
            } else {
                let delayed = Status.delayed(until: armedAt)
                if currentStatus != delayed { publish(status: delayed) }
                return
            }
        }

        if currentStatus != .listening { publish(status: .listening) }

        if db > updated + triggerDB {
            loudSeconds += seconds
            if loudSeconds >= Tuning.triggerHoldSeconds {
                loudSeconds = 0
                beginCapture(firstLevel: db)
            }
        } else {
            loudSeconds = 0
        }
    }

    // MARK: - 片段录制

    private func beginCapture(firstLevel: Float) {
        guard let session, let format else { return }
        guard Storage.hasFreeSpace() else {
            let skipped = (session.storageSkippedCount ?? 0) + 1
            self.session?.storageSkippedCount = skipped
            if skipped == 1 { log("存储空间不足，开始跳过录制") }
            return
        }
        let preRoll = ringSeconds
        let fileName = "clip-\(UUID().uuidString).m4a"
        let url = Storage.clipURL(sessionID: session.id, fileName: fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 48_000
        ]

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            log("无法创建录音文件：\(error.localizedDescription)")
            return
        }
        Storage.relaxProtection(of: url)

        let newCapture = Capture(
            file: file,
            url: url,
            fileName: fileName,
            startedAt: Date().addingTimeInterval(-preRoll),
            sampleRate: format.sampleRate,
            initialLevel: firstLevel
        )
        attachClassifier(to: newCapture, format: format)
        capture = newCapture
        publish(status: .capturing)

        let buffered = ring
        ring.removeAll()
        ringSeconds = 0
        for buffer in buffered {
            write(buffer, to: newCapture, db: buffer.rmsDB())
        }
        newCapture.lastLoudFrame = newCapture.framesWritten
    }

    private func attachClassifier(to capture: Capture, format: AVAudioFormat) {
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: Tuning.classifierWindowSeconds, preferredTimescale: 48_000)
            request.overlapFactor = 0.5

            let observer = ResultsObserver { [weak self, weak capture] items in
                guard let self else { return }
                self.queue.async {
                    guard let capture else { return }
                    capture.absorb(items)
                }
            }
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: observer)
            capture.analyzer = analyzer
            capture.observer = observer
        } catch {
            capture.classifierFailed = true
            log("声音分类器不可用，片段将全部保留：\(error.localizedDescription)")
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, to capture: Capture, db: Float) {
        do {
            try capture.file?.write(from: buffer)
        } catch {
            log("写入录音失败：\(error.localizedDescription)")
            capture.writeFailed = true
            return
        }
        capture.analyzer?.analyze(buffer, atAudioFramePosition: capture.framesWritten)
        capture.framesWritten += AVAudioFramePosition(buffer.frameLength)
        capture.peakDB = max(capture.peakDB, db)
        capture.tailDB += (db - capture.tailDB) * 0.1
    }

    private func continueCapture(_ active: Capture, buffer: AVAudioPCMBuffer, db: Float, seconds: Double) {
        write(buffer, to: active, db: db)
        if active.writeFailed {
            finishCapture()
            return
        }

        let floorValue = noiseFloor ?? db
        // 录制中底噪也缓慢上移（约 60 秒），防止持续噪声一直占着录制。
        noiseFloor = floorValue + (db - floorValue) * 0.002

        // 判定“还在出声”的门槛略低于触发门槛，避免一句话被切断。
        if db > floorValue + max(3, triggerDB - 3) {
            active.lastLoudFrame = active.framesWritten
        }

        let quiet = Double(active.framesWritten - active.lastLoudFrame) / active.sampleRate
        let total = Double(active.framesWritten) / active.sampleRate
        if quiet >= Tuning.quietTailSeconds || total >= Tuning.maxClipSeconds {
            finishCapture()
        }
    }

    private func finishCapture() {
        guard let finished = capture else { return }
        capture = nil
        finished.analyzer?.completeAnalysis()
        // 分类结果也是排队回到 queue 的，所以收尾排在它们之后。
        queue.async { self.finalize(finished) }
    }

    private func finalize(_ finished: Capture) {
        finished.file = nil // 释放 AVAudioFile 才会写完文件尾。
        finished.analyzer = nil
        finished.observer = nil

        let duration = Double(finished.framesWritten) / finished.sampleRate
        let kind: ClipKind
        if finished.bestSpeech >= Tuning.speechThreshold {
            kind = .speech
        } else if finished.bestSnore >= Tuning.snoreThreshold {
            kind = .snore
        } else {
            kind = .other
        }

        // 持续噪声（如刚打开风扇）结束录制时把底噪抬上去，避免反复触发。
        if let floorValue = noiseFloor {
            noiseFloor = max(floorValue, finished.tailDB - 2)
        }

        // 先全部保留，之后由保留规则清理音频；这样模型漏判时还有机会找回。
        let keep = !finished.writeFailed && duration > 0

        if keep {
            let confidence = kind == .speech ? finished.bestSpeech
                : kind == .snore ? finished.bestSnore
                : finished.topConfidence
            let clip = Clip(
                fileName: finished.fileName,
                startedAt: finished.startedAt,
                duration: duration,
                kind: kind,
                confidence: confidence,
                topLabel: finished.topLabel,
                peakDB: finished.peakDB,
                // 分类器失败时无法判断内容，不自动清理。
                autoCleanable: !finished.classifierFailed
            )
            session?.clips.append(clip)
        } else {
            try? FileManager.default.removeItem(at: finished.url)
            session?.discardedCount += 1
        }
        saveSession()

        let speech = session?.count(of: .speech) ?? 0
        DispatchQueue.main.async {
            self.speechClipCount = speech
        }
        if wanted, capture == nil, !inOutage { publish(status: .listening) }
    }

    // MARK: - 工具

    private func loadSettings() {
        let defaults = UserDefaults.standard
        triggerDB = Float(defaults.double(forKey: SettingsKey.triggerDB))
    }

    private func log(_ message: String) {
        session?.events.append(LogEvent(date: Date(), message: message))
    }

    private func saveSession() {
        guard let session else { return }
        do {
            try Storage.save(session)
        } catch {
            NSLog("SleepTalk: failed to save session: \(error)")
        }
    }

    private func publish(status newStatus: Status) {
        currentStatus = newStatus
        DispatchQueue.main.async { self.status = newStatus }
    }
}

private enum MonitorError: LocalizedError {
    case microphoneUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: return "麦克风暂时不可用"
        }
    }
}

// MARK: - 单个片段的录制状态

private final class Capture {
    var file: AVAudioFile?
    let url: URL
    let fileName: String
    let startedAt: Date
    let sampleRate: Double

    var analyzer: SNAudioStreamAnalyzer?
    var observer: ResultsObserver?
    var classifierFailed = false
    var writeFailed = false

    var framesWritten: AVAudioFramePosition = 0
    var lastLoudFrame: AVAudioFramePosition = 0
    var peakDB: Float
    var tailDB: Float

    var bestSpeech = 0.0
    var bestSnore = 0.0
    var topLabel = "未知"
    var topConfidence = 0.0

    init(file: AVAudioFile, url: URL, fileName: String, startedAt: Date, sampleRate: Double, initialLevel: Float) {
        self.file = file
        self.url = url
        self.fileName = fileName
        self.startedAt = startedAt
        self.sampleRate = sampleRate
        self.peakDB = initialLevel
        self.tailDB = initialLevel
    }

    func absorb(_ items: [(label: String, confidence: Double)]) {
        for item in items {
            if MonitorEngineLabels.speech.contains(item.label) {
                bestSpeech = max(bestSpeech, item.confidence)
            }
            if MonitorEngineLabels.snore.contains(item.label) {
                bestSnore = max(bestSnore, item.confidence)
            }
            if item.label != "silence", item.confidence > topConfidence {
                topConfidence = item.confidence
                topLabel = item.label
            }
        }
    }
}

private enum MonitorEngineLabels {
    static let speech: Set<String> = [
        "speech", "whispering", "shout", "yell", "screaming",
        "children_shouting", "conversation", "narration_monologue", "babbling"
    ]
    static let snore: Set<String> = ["snoring"]
}

private final class ResultsObserver: NSObject, SNResultsObserving {
    private let handler: ([(label: String, confidence: Double)]) -> Void

    init(handler: @escaping ([(label: String, confidence: Double)]) -> Void) {
        self.handler = handler
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        handler(result.classifications.map { (label: $0.identifier, confidence: $0.confidence) })
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        NSLog("SleepTalk: classifier failed: \(error)")
    }

    func requestDidComplete(_ request: SNRequest) {}
}

// MARK: - 缓冲区工具

private extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            let bytes = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            memcpy(to, from, Int(bytes))
            destination[index].mDataByteSize = bytes
        }
        return copy
    }

    func rmsDB() -> Float {
        guard let channel = floatChannelData?[0], frameLength > 0 else { return -160 }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(frameLength))
        return 20 * log10(max(rms, 1e-9))
    }
}
