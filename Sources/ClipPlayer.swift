import AVFoundation
import Combine

/// 回放一个或一组片段。用 AVAudioEngine 而不是 AVAudioPlayer，
/// 因为后者的音量不能超过原始音量，无法放大小声的梦话。
final class ClipPlayer: ObservableObject {
    private static let maximumGainDB: Float = 18
    private static let peakTargetDB: Float = -1

    @Published private(set) var playlistID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var clipIndex = 0
    @Published private(set) var clipOffset: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 1)

    private var urls: [URL] = []
    private var currentFile: AVAudioFile?
    private var connectedFormat: AVAudioFormat?
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var generation = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        engine.attach(node)
        engine.attach(equalizer)
        equalizer.bands[0].bypass = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.stop()
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // 刚启动回放时也可能收到这个通知；引擎还在运行就不用处理。
            guard let self, !self.engine.isRunning else { return }
            self.stop()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        timer?.invalidate()
    }

    func toggle(playlistID id: String, urls newURLs: [URL], peak: Float) {
        if playlistID == id {
            if isPlaying { pause() } else { resume() }
        } else {
            start(playlistID: id, urls: newURLs, peak: peak, index: 0, offset: 0)
        }
    }

    /// 跳到指定位置；如果这个列表还没在播放，就从该位置开始播放。
    func seek(playlistID id: String, urls newURLs: [URL], peak: Float, index: Int, offset: TimeInterval) {
        guard playlistID == id else {
            start(playlistID: id, urls: newURLs, peak: peak, index: index, offset: offset)
            return
        }
        do {
            try playSegment(index: index, offset: offset)
        } catch {
            fail(error)
        }
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        node.stop()
        engine.stop()
        currentFile = nil
        urls = []
        let wasActive = playlistID != nil
        playlistID = nil
        isPlaying = false
        clipIndex = 0
        clipOffset = 0
        // 没在播放时不要动音频会话，以免影响监听。
        if wasActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func start(playlistID id: String, urls newURLs: [URL], peak: Float, index: Int, offset: TimeInterval) {
        stop()
        guard !newURLs.isEmpty else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            equalizer.globalGain = gain(forPeak: peak)
            urls = newURLs
            playlistID = id
            errorMessage = nil
            try playSegment(index: index, offset: offset)
            startTimer()
        } catch {
            fail(error)
        }
    }

    private func gain(forPeak peak: Float) -> Float {
        guard UserDefaults.standard.bool(forKey: SettingsKey.amplifyPlayback) else { return 0 }
        let peakDB = 20 * log10(max(peak, 0.00001))
        return min(Self.maximumGainDB, max(0, Self.peakTargetDB - peakDB))
    }

    private func playSegment(index: Int, offset: TimeInterval) throws {
        guard urls.indices.contains(index) else {
            stop()
            return
        }
        generation += 1
        let token = generation
        node.stop()

        let file = try AVAudioFile(forReading: urls[index])
        currentFile = file
        let format = file.processingFormat
        if connectedFormat != format {
            engine.stop()
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(equalizer)
            engine.connect(node, to: equalizer, format: format)
            engine.connect(equalizer, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        let requested = AVAudioFramePosition(max(0, offset) * format.sampleRate)
        let startFrame = min(file.length, requested)
        let frames = file.length - startFrame
        clipIndex = index
        clipOffset = Double(startFrame) / format.sampleRate
        segmentStartFrame = startFrame

        guard frames > 0 else {
            advance()
            return
        }

        node.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(frames),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.advance()
            }
        }
        node.play()
        isPlaying = true
    }

    private func advance() {
        let next = clipIndex + 1
        guard urls.indices.contains(next) else {
            stop()
            return
        }
        do {
            try playSegment(index: next, offset: 0)
        } catch {
            fail(error)
        }
    }

    private func pause() {
        node.pause()
        isPlaying = false
    }

    private func resume() {
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            node.play()
            isPlaying = true
        } catch {
            fail(error)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
    }

    private func updateProgress() {
        guard isPlaying,
              let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime),
              playerTime.sampleRate > 0 else { return }
        clipOffset = Double(segmentStartFrame + playerTime.sampleTime) / playerTime.sampleRate
    }

    private func fail(_ error: Error) {
        stop()
        errorMessage = "无法播放：\(error.localizedDescription)"
    }
}
