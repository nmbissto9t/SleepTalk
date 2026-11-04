import Accelerate
import AVFoundation
import SwiftUI

/// 从已保存的音频里提取波形，结果缓存在 Caches，丢失后可以重新生成。录音引擎不参与。
enum WaveformLoader {
    private static let rawBarCount = 120

    static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Waveforms", isDirectory: true)
    }

    /// 每根柱子是该时间段的线性峰值（0...1 左右），尚未归一化。
    static func bars(for clip: Clip, sessionID: UUID) -> [Float] {
        let cacheURL = cacheFolder.appendingPathComponent("\(clip.id.uuidString).json")
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([Float].self, from: data) {
            return cached
        }
        let url = Storage.clipURL(sessionID: sessionID, fileName: clip.fileName)
        guard let computed = try? computeBars(url: url) else { return [] }
        try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(computed) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return computed
    }

    private static func computeBars(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let total = file.length
        guard total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            return []
        }
        var result = [Float](repeating: 0, count: rawBarCount)
        var position: AVAudioFramePosition = 0

        while file.framePosition < total {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channel = buffer.floatChannelData?[0] else { break }
            var cursor = 0
            while cursor < frames {
                let bar = min(rawBarCount - 1, Int(position * AVAudioFramePosition(rawBarCount) / total))
                let barEnd = AVAudioFramePosition(bar + 1) * total / AVAudioFramePosition(rawBarCount)
                let count = max(1, min(frames - cursor, Int(barEnd - position)))
                var peak: Float = 0
                vDSP_maxmgv(channel + cursor, 1, &peak, vDSP_Length(count))
                result[bar] = max(result[bar], peak)
                cursor += count
                position += AVAudioFramePosition(count)
            }
        }
        return result
    }
}

/// 一个或一组片段的显示数据，并负责柱子位置和“第几段第几秒”之间的换算。
struct WaveformModel: Equatable {
    /// 值小于 0 表示段与段之间的空隙。
    let bars: [Float]
    let clipStarts: [Int]
    let clipCounts: [Int]
    let durations: [TimeInterval]
    let peak: Float

    static func build(clips: [Clip], sessionID: UUID, target: Int = 80) -> WaveformModel {
        let total = max(0.001, clips.reduce(0) { $0 + $1.duration })
        var bars: [Float] = []
        var starts: [Int] = []
        var counts: [Int] = []
        var peak: Float = 0

        for (index, clip) in clips.enumerated() {
            let raw = WaveformLoader.bars(for: clip, sessionID: sessionID)
            peak = max(peak, raw.max() ?? 0)
            let share = clip.duration / total * Double(target)
            let count = clips.count == 1 ? target : max(2, Int(share.rounded()))
            starts.append(bars.count)
            counts.append(count)
            bars.append(contentsOf: resample(raw, to: count))
            if index < clips.count - 1 { bars.append(-1) }
        }

        return WaveformModel(
            bars: bars,
            clipStarts: starts,
            clipCounts: counts,
            durations: clips.map(\.duration),
            peak: peak
        )
    }

    private static func resample(_ raw: [Float], to count: Int) -> [Float] {
        guard !raw.isEmpty else { return [Float](repeating: 0, count: count) }
        return (0..<count).map { index in
            let start = index * raw.count / count
            let end = max(start + 1, (index + 1) * raw.count / count)
            return raw[start..<min(end, raw.count)].max() ?? 0
        }
    }

    var totalDuration: TimeInterval {
        durations.reduce(0, +)
    }

    func elapsed(clipIndex: Int, offset: TimeInterval) -> TimeInterval {
        guard durations.indices.contains(clipIndex) else { return 0 }
        return durations[..<clipIndex].reduce(0, +) + min(max(0, offset), durations[clipIndex])
    }

    func barPosition(clipIndex: Int, offset: TimeInterval) -> Double {
        guard clipStarts.indices.contains(clipIndex) else { return 0 }
        let duration = max(0.001, durations[clipIndex])
        let ratio = min(1, max(0, offset / duration))
        return Double(clipStarts[clipIndex]) + ratio * Double(clipCounts[clipIndex])
    }

    func location(atFraction fraction: Double) -> (index: Int, offset: TimeInterval) {
        guard !clipStarts.isEmpty else { return (0, 0) }
        let position = min(1, max(0, fraction)) * Double(bars.count)
        var index = 0
        for candidate in clipStarts.indices where Double(clipStarts[candidate]) <= position {
            index = candidate
        }
        let within = (position - Double(clipStarts[index])) / Double(max(1, clipCounts[index]))
        return (index, min(1, max(0, within)) * durations[index])
    }
}

struct WaveformView: View {
    let model: WaveformModel?
    /// 已播放到第几根柱子；没有在播放时为 nil。
    let progress: Double?
    var height: CGFloat = 32
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard let model, !model.bars.isEmpty else {
                    let line = CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)
                    context.fill(Path(line), with: .color(Color.secondary.opacity(0.25)))
                    return
                }
                let slot = size.width / CGFloat(model.bars.count)
                let barWidth = max(1, slot * 0.65)
                let maximum = max(0.0001, model.peak)
                for (index, value) in model.bars.enumerated() where value >= 0 {
                    // 按本段最大音量线性缩放，让安静的部分保持低矮，起伏更明显。
                    let level = CGFloat(value / maximum)
                    let barHeight = max(2, level * size.height)
                    let rect = CGRect(
                        x: CGFloat(index) * slot,
                        y: (size.height - barHeight) / 2,
                        width: barWidth,
                        height: barHeight
                    )
                    let played = progress.map { Double(index) < $0 } ?? false
                    let color = played ? Color.indigo : Color.secondary.opacity(0.6)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    guard proxy.size.width > 0 else { return }
                    onSeek(Double(value.location.x / proxy.size.width))
                }
            )
        }
        .frame(height: height)
        .accessibilityLabel("波形，点按可跳转到对应位置")
    }
}

/// 播放按钮 + 波形。单个片段和鼾声分组共用。
struct WavePlaybackRow: View {
    let clips: [Clip]
    let sessionID: UUID
    let disabled: Bool
    var compact = false
    @ObservedObject var player: ClipPlayer

    @State private var model: WaveformModel?

    /// 分组和组内第一段要区分开，否则展开后会共用播放状态。
    static func playlistID(for clips: [Clip]) -> String {
        clips.count > 1 ? "group-\(clips[0].id.uuidString)" : clips[0].id.uuidString
    }

    private var playlistID: String { Self.playlistID(for: clips) }

    private var timeText: String {
        guard let model else { return "" }
        let total = Format.playback(model.totalDuration)
        guard isCurrent else { return total }
        let elapsed = model.elapsed(clipIndex: player.clipIndex, offset: player.clipOffset)
        return "\(Format.playback(elapsed)) / \(total)"
    }
    private var isCurrent: Bool { player.playlistID == playlistID }
    private var isPlaying: Bool { isCurrent && player.isPlaying }

    private var urls: [URL] {
        clips.map { Storage.clipURL(sessionID: sessionID, fileName: $0.fileName) }
    }

    private var progress: Double? {
        guard isCurrent, let model else { return nil }
        return model.barPosition(clipIndex: player.clipIndex, offset: player.clipOffset)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                guard let model else { return }
                player.toggle(playlistID: playlistID, urls: urls, peak: model.peak)
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(compact ? .title3 : .title2)
            }
            .buttonStyle(.borderless)
            .disabled(disabled || model == nil)
            .accessibilityLabel(isPlaying ? "暂停" : "播放")

            WaveformView(model: model, progress: progress, height: compact ? 24 : 32) { fraction in
                guard !disabled, let model else { return }
                let target = model.location(atFraction: fraction)
                player.seek(
                    playlistID: playlistID,
                    urls: urls,
                    peak: model.peak,
                    index: target.index,
                    offset: target.offset
                )
            }

            Text(timeText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 62, alignment: .trailing)
        }
        .task(id: clips.map(\.id)) {
            let currentClips = clips
            let currentSession = sessionID
            let built = await Task.detached(priority: .utility) {
                WaveformModel.build(clips: currentClips, sessionID: currentSession)
            }.value
            model = built
        }
    }
}
