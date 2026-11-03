import AVFoundation
import Combine

final class ClipPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingClipID: UUID?
    @Published private(set) var errorMessage: String?

    private var player: AVAudioPlayer?

    func toggle(clip: Clip, url: URL) {
        if playingClipID == clip.id {
            stop()
            return
        }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer
            playingClipID = clip.id
            errorMessage = nil
        } catch {
            errorMessage = "无法播放：\(error.localizedDescription)"
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingClipID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.player = nil
            self?.playingClipID = nil
        }
    }
}
