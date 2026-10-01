import SwiftUI
import AVFoundation
import AVKit
import AppKit

struct VideoClip: Identifiable, Codable {
    let id: UUID
    let url: URL
    var sourceStart: Double
    var sourceEnd: Double
    var timelineStart: Double
    var duration: Double { max(0, sourceEnd - sourceStart) }
    var name: String { url.deletingPathExtension().lastPathComponent }
    init(url: URL, sourceStart: Double, sourceEnd: Double, timelineStart: Double) {
        self.id = UUID(); self.url = url; self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd; self.timelineStart = timelineStart
    }
    enum CodingKeys: String, CodingKey { case id, url, sourceStart, sourceEnd, timelineStart }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try box.decode(URL.self, forKey: .url)
        sourceStart = try box.decode(Double.self, forKey: .sourceStart)
        sourceEnd = try box.decode(Double.self, forKey: .sourceEnd)
        timelineStart = try box.decodeIfPresent(Double.self, forKey: .timelineStart) ?? 0
    }
}

struct AudioClip: Identifiable, Codable {
    let id = UUID()
    let url: URL
    var sourceStart: Double
    var sourceEnd: Double
    var timelineStart: Double
    var volume: Double = 0.7
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var duration: Double { max(0, sourceEnd - sourceStart) }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum ExportQuality: String, CaseIterable, Identifiable, Codable {
    case highest = "Yüksek"
    case medium = "Orta"
    case low = "Küçük dosya"
    var id: String { rawValue }
    var preset: String {
        switch self {
        case .highest: return AVAssetExportPresetHighestQuality
        case .medium: return AVAssetExportPresetMediumQuality
        case .low: return AVAssetExportPresetLowQuality
        }
    }
}

enum CanvasPreset: String, CaseIterable, Identifiable, Codable {
    case source = "Kaynak"
    case portrait = "9:16"
    case landscape = "16:9"
    case classic = "4:3"
    case square = "1:1"
    case cinema = "21:9"

    var id: String { rawValue }
    var outputSize: CGSize? {
        switch self {
        case .source: return nil
        case .portrait: return CGSize(width: 1080, height: 1920)
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .classic: return CGSize(width: 1440, height: 1080)
        case .square: return CGSize(width: 1080, height: 1080)
        case .cinema: return CGSize(width: 1680, height: 720)
        }
    }
}

struct EditorProject: Codable {
    var version = 3
    var clips: [VideoClip]
    var audioClips: [AudioClip]
    var canvasPreset: CanvasPreset
    var frameRate: Int
    var exportQuality: ExportQuality
    var keepOriginalAudio: Bool
    var darkMode: Bool
    var videoFadeOut: Double? = nil
}

@MainActor final class EditorModel: ObservableObject {
    @Published var clips: [VideoClip] = []
    @Published var selectedID: UUID?
    @Published var audioClips: [AudioClip] = []
    @Published var selectedAudioID: UUID?
    @Published var keepOriginalAudio = true
    @Published var canvasPreset: CanvasPreset = .source
    @Published var frameRate = 30
    @Published var exportQuality: ExportQuality = .highest
    @Published var darkMode = true
    @Published var videoFadeOut = 0.0
    @Published var playhead = 0.0
    @Published var playing = false
    @Published var exporting = false
    @Published var status = "Başlamak için videolarınızı ekleyin."
    @Published var error: String?
    let player = AVPlayer()
    private var observer: Any?
    private var retainedURLs: Set<URL> = []
    private var projectURL: URL?

    var videoEnd: Double { clips.map { $0.timelineStart + $0.duration }.max() ?? 0 }
    var duration: Double { max(videoEnd, audioClips.map { $0.timelineStart + $0.duration }.max() ?? 0) }
    var selectedIndex: Int? { clips.firstIndex { $0.id == selectedID } }
    var selectedAudioIndex: Int? { audioClips.firstIndex { $0.id == selectedAudioID } }
    var canvasSize: CGSize {
        if let explicit = canvasPreset.outputSize { return explicit }
        guard let first = clips.first else { return CGSize(width: 1920, height: 1080) }
        let asset = AVURLAsset(url: first.url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            return CGSize(width: 1920, height: 1080)
        }
        let oriented = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        let width = abs(oriented.width)
        let height = abs(oriented.height)
        guard width > 0, height > 0 else { return CGSize(width: 1920, height: 1080) }
        let scale = min(1, 1920 / max(width, height))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value / 2).rounded(.down) * 2) }
        return CGSize(width: even(width * scale), height: even(height * scale))
    }
    var canvasAspect: CGFloat { canvasSize.width / canvasSize.height }

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite { self.playhead = min(max(0, seconds), self.duration) }
                if self.playing && self.duration > 0 && seconds >= self.duration - 0.08 {
                    self.player.pause()
                    self.playing = false
                }
            }
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
    }

    func importVideos() {
        let panel = NSOpenPanel()
        panel.title = "Video ekle"
        panel.prompt = "Videoları ekle"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK else { return }
        var added = 0
        for url in panel.urls {
            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(asset.duration)
            guard seconds.isFinite && seconds > 0.05, !asset.tracks(withMediaType: .video).isEmpty else { continue }
            _ = url.startAccessingSecurityScopedResource()
            retainedURLs.insert(url)
            let clip = VideoClip(url: url, sourceStart: 0, sourceEnd: seconds, timelineStart: videoEnd)
            clips.append(clip)
            selectedID = clip.id
            added += 1
        }
        if added == 0 { error = "Bu dosyalarda macOS tarafından okunabilen bir video akışı bulunamadı." }
        else { status = "\(added) video eklendi."; rebuild() }
    }

    func importSong() {
        let panel = NSOpenPanel()
        panel.title = "Müzik veya ses ekle"
        panel.prompt = "Sesi ekle"
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let asset = AVURLAsset(url: url)
        guard !asset.tracks(withMediaType: .audio).isEmpty else {
            error = "Bu dosyada macOS tarafından okunabilen bir ses akışı bulunamadı."
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        retainedURLs.insert(url)
        let length = CMTimeGetSeconds(asset.duration)
        guard length.isFinite && length > 0.05 else {
            error = "Ses dosyasının süresi okunamadı."
            return
        }
        let start = max(0, playhead)
        let clip = AudioClip(url: url, sourceStart: 0, sourceEnd: length, timelineStart: start)
        audioClips.append(clip)
        selectedAudioID = clip.id
        selectedID = nil
        status = "Ses parçası \(timecode(start)) konumuna eklendi."
        rebuild()
    }

    func selectVideo(_ id: UUID) { selectedID = id; selectedAudioID = nil }
    func selectAudio(_ id: UUID) { selectedAudioID = id; selectedID = nil }

    func removeSelectedAudio() {
        guard let i = selectedAudioIndex else { return }
        audioClips.remove(at: i)
        selectedAudioID = nil
        status = "Ses klibi silindi."
        rebuild()
    }

    func splitAudio() {
        guard let i = selectedAudioIndex else { return }
        let clip = audioClips[i]
        let offset = playhead - clip.timelineStart
        guard offset > 0.08 && offset < clip.duration - 0.08 else { return }
        audioClips[i].sourceEnd = clip.sourceStart + offset
        audioClips[i].fadeOut = 0
        var next = AudioClip(url: clip.url, sourceStart: clip.sourceStart + offset,
                             sourceEnd: clip.sourceEnd, timelineStart: playhead, volume: clip.volume)
        next.fadeOut = clip.fadeOut
        audioClips.insert(next, at: i + 1)
        selectedAudioID = next.id
        status = "Ses klibi \(timecode(playhead)) konumunda bölündü."
        rebuild()
    }

    func trimSelectedAudio(start: Double? = nil, end: Double? = nil) {
        guard let i = selectedAudioIndex else { return }
        let full = CMTimeGetSeconds(AVURLAsset(url: audioClips[i].url).duration)
        if let start {
            let value = min(max(0, start), audioClips[i].sourceEnd - 0.1)
            audioClips[i].timelineStart = max(0, audioClips[i].timelineStart + value - audioClips[i].sourceStart)
            audioClips[i].sourceStart = value
        }
        if let end { audioClips[i].sourceEnd = max(audioClips[i].sourceStart + 0.1, min(full, end)) }
        clampAudioFades(i)
        rebuild()
    }

    func setSelectedAudioTimelineStart(_ value: Double) {
        guard let i = selectedAudioIndex else { return }
        audioClips[i].timelineStart = max(0, value)
        rebuild()
    }

    func setSelectedAudioVolume(_ value: Double) {
        guard let i = selectedAudioIndex else { return }
        audioClips[i].volume = min(max(0, value), 1)
        rebuild()
    }

    func setSelectedAudioFade(inSeconds: Double? = nil, outSeconds: Double? = nil) {
        guard let i = selectedAudioIndex else { return }
        if let inSeconds { audioClips[i].fadeIn = max(0, inSeconds) }
        if let outSeconds { audioClips[i].fadeOut = max(0, outSeconds) }
        clampAudioFades(i)
        rebuild()
    }

    private func clampAudioFades(_ i: Int) {
        let limit = min(audioClips[i].duration / 2, max(0, duration - audioClips[i].timelineStart) / 2)
        audioClips[i].fadeIn = min(audioClips[i].fadeIn, limit)
        audioClips[i].fadeOut = min(audioClips[i].fadeOut, limit)
    }

    func togglePlay() {
        guard duration > 0 else { return }
        if playing { player.pause(); playing = false }
        else {
            if playhead >= duration - 0.05 { seek(to: 0) }
            player.play(); playing = true
        }
    }

    func seek(to seconds: Double) {
        let value = min(max(0, seconds), duration)
        playhead = value
        player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func pause() { player.pause(); playing = false }

    func stepFrames(_ count: Int) {
        pause()
        seek(to: playhead + Double(count) / Double(max(1, frameRate)))
    }

    func stepSeconds(_ count: Double) {
        pause()
        seek(to: playhead + count)
    }

    func removeSelection() {
        if selectedAudioID != nil { removeSelectedAudio() }
        else { removeSelected() }
    }

    func split() {
        guard let i = clipIndex(at: playhead) else { return }
        let clip = clips[i]
        let offset = playhead - clip.timelineStart
        guard offset > 0.08 && offset < clip.duration - 0.08 else { return }
        let cut = clip.sourceStart + offset
        clips[i].sourceEnd = cut
        let next = VideoClip(url: clip.url, sourceStart: cut, sourceEnd: clip.sourceEnd, timelineStart: playhead)
        clips.insert(next, at: i + 1)
        selectedID = next.id
        status = "Klip oynatma konumunda bölündü."
        rebuild()
    }

    func trimSelected(start: Double? = nil, end: Double? = nil) {
        guard let i = selectedIndex else { return }
        let full = CMTimeGetSeconds(AVURLAsset(url: clips[i].url).duration)
        if let start {
            let value = min(max(0, start), clips[i].sourceEnd - 0.1)
            clips[i].timelineStart = max(0, clips[i].timelineStart + value - clips[i].sourceStart)
            clips[i].sourceStart = value
        }
        if let end { clips[i].sourceEnd = max(clips[i].sourceStart + 0.1, min(full, end)) }
        rebuild()
    }

    func trimSelectedAtPlayhead(startEdge: Bool) {
        guard let i = selectedIndex else { return }
        let timelineStart = clips[i].timelineStart
        let sourceTime = clips[i].sourceStart + (playhead - timelineStart)
        guard sourceTime > clips[i].sourceStart + 0.1,
              sourceTime < clips[i].sourceEnd - 0.1 else { return }
        if startEdge {
            trimSelected(start: sourceTime)
        }
        else { trimSelected(end: sourceTime) }
        status = startEdge ? "Klip başlangıcı oynatma konumuna alındı." : "Klip bitişi oynatma konumuna alındı."
    }

    func removeSelected() {
        guard let i = selectedIndex else { return }
        clips.remove(at: i)
        selectedID = clips.first?.id
        rebuild()
    }

    func moveVideo(_ id: UUID, to proposed: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let length = clips[i].duration
        let others = clips.filter { $0.id != id }.sorted { $0.timelineStart < $1.timelineStart }
        var candidates: [Double] = [max(0, proposed)]
        for other in others {
            candidates.append(max(0, other.timelineStart - length))
            candidates.append(other.timelineStart + other.duration)
        }
        let valid = candidates.filter { candidate in
            others.allSatisfy { candidate + length <= $0.timelineStart + 0.001 || candidate >= $0.timelineStart + $0.duration - 0.001 }
        }
        clips[i].timelineStart = valid.min { abs($0 - proposed) < abs($1 - proposed) } ?? max(0, proposed)
        clips.sort { $0.timelineStart < $1.timelineStart }
        status = "Video \(timecode(clips.first(where: { $0.id == id })?.timelineStart ?? 0)) konumuna taşındı."
        rebuild()
    }

    func moveAudio(_ id: UUID, to proposed: Double) {
        guard let i = audioClips.firstIndex(where: { $0.id == id }) else { return }
        audioClips[i].timelineStart = max(0, proposed)
        rebuild()
    }

    func trimVideoEdge(_ id: UUID, leading: Bool, delta: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips[i]
        let full = CMTimeGetSeconds(AVURLAsset(url: clip.url).duration)
        if leading {
            let previousEnd = clips.filter { $0.id != id && $0.timelineStart < clip.timelineStart }
                .map { $0.timelineStart + $0.duration }.max() ?? 0
            let change = min(max(delta, max(-clip.sourceStart, previousEnd - clip.timelineStart)), clip.duration - 0.1)
            clips[i].sourceStart += change
            clips[i].timelineStart += change
        } else {
            let nextStart = clips.filter { $0.id != id && $0.timelineStart >= clip.timelineStart + clip.duration - 0.001 }
                .map(\.timelineStart).min() ?? Double.infinity
            let change = min(max(delta, -(clip.duration - 0.1)), min(full - clip.sourceEnd, nextStart - clip.timelineStart - clip.duration))
            clips[i].sourceEnd += change
        }
        rebuild()
    }

    func trimAudioEdge(_ id: UUID, leading: Bool, delta: Double) {
        guard let i = audioClips.firstIndex(where: { $0.id == id }) else { return }
        let clip = audioClips[i]
        let full = CMTimeGetSeconds(AVURLAsset(url: clip.url).duration)
        if leading {
            let change = min(max(delta, max(-clip.sourceStart, -clip.timelineStart)), clip.duration - 0.1)
            audioClips[i].sourceStart += change
            audioClips[i].timelineStart += change
        } else {
            let change = min(max(delta, -(clip.duration - 0.1)), full - clip.sourceEnd)
            audioClips[i].sourceEnd += change
        }
        clampAudioFades(i)
        rebuild()
    }

    func saveProject(asNew: Bool = false) {
        var destination = asNew ? nil : projectURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.title = "Projeyi kaydet"
            panel.nameFieldStringValue = "Kadrena Projesi.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK else { return }
            destination = panel.url
        }
        guard let destination else { return }
        let project = EditorProject(clips: clips, audioClips: audioClips, canvasPreset: canvasPreset,
                                    frameRate: frameRate, exportQuality: exportQuality,
                                    keepOriginalAudio: keepOriginalAudio, darkMode: darkMode,
                                    videoFadeOut: videoFadeOut)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: destination, options: .atomic)
            projectURL = destination
            status = "Proje kaydedildi: \(destination.lastPathComponent)"
        } catch { self.error = "Proje kaydedilemedi: \(error.localizedDescription)" }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Proje aç"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = try JSONDecoder().decode(EditorProject.self, from: Data(contentsOf: url))
            guard (1...3).contains(project.version) else { throw EditorError.message("Bu proje sürümü desteklenmiyor.") }
            let mediaURLs = project.clips.map(\.url) + project.audioClips.map(\.url)
            if let missing = mediaURLs.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                throw EditorError.message("Kaynak dosya bulunamadı: \(missing.lastPathComponent)")
            }
            for mediaURL in mediaURLs {
                _ = mediaURL.startAccessingSecurityScopedResource()
                retainedURLs.insert(mediaURL)
            }
            clips = project.clips
            if project.version == 1 {
                var cursor = 0.0
                for i in clips.indices { clips[i].timelineStart = cursor; cursor += clips[i].duration }
            }
            audioClips = project.audioClips
            canvasPreset = project.canvasPreset
            frameRate = project.frameRate
            exportQuality = project.exportQuality
            keepOriginalAudio = project.keepOriginalAudio
            darkMode = project.darkMode
            videoFadeOut = max(0, project.videoFadeOut ?? 0)
            selectedID = clips.first?.id
            selectedAudioID = nil
            playhead = 0
            projectURL = url
            rebuild()
            status = "Proje açıldı: \(url.lastPathComponent)"
        } catch { self.error = "Proje açılamadı: \(error.localizedDescription)" }
    }

    private func clipIndex(at seconds: Double) -> Int? {
        for (i, clip) in clips.enumerated() {
            if seconds >= clip.timelineStart && seconds < clip.timelineStart + clip.duration { return i }
        }
        return nil
    }

    private func composition() throws -> (AVMutableComposition, AVMutableAudioMix, AVMutableVideoComposition?) {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw EditorError.message("Video izi oluşturulamadı.")
        }
        let hasClipAudio = clips.contains { !AVURLAsset(url: $0.url).tracks(withMediaType: .audio).isEmpty }
        let originalAudio = hasClipAudio ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero
        let renderSize = canvasSize
        let fadeLength = min(max(0, videoFadeOut), videoEnd)
        let fadeStart = videoEnd - fadeLength
        func opacity(at seconds: Double) -> Float {
            guard fadeLength > 0 else { return 1 }
            return Float(min(1, max(0, (videoEnd - seconds) / fadeLength)))
        }

        for clip in clips.sorted(by: { $0.timelineStart < $1.timelineStart }) {
            let at = CMTime(seconds: clip.timelineStart, preferredTimescale: 600)
            if CMTimeCompare(at, cursor) > 0 {
                let gap = AVMutableVideoCompositionInstruction()
                gap.timeRange = CMTimeRange(start: cursor, duration: CMTimeSubtract(at, cursor))
                gap.backgroundColor = CGColor(gray: 0, alpha: 1)
                instructions.append(gap)
            }
            let asset = AVURLAsset(url: clip.url)
            guard let sourceVideo = asset.tracks(withMediaType: .video).first else { continue }
            let range = CMTimeRange(start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600), duration: CMTime(seconds: clip.duration, preferredTimescale: 600))
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: at)
            if let audio = asset.tracks(withMediaType: .audio).first {
                try originalAudio?.insertTimeRange(range, of: audio, at: at)
            }
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            let oriented = sourceVideo.preferredTransform
            let bounds = CGRect(origin: .zero, size: sourceVideo.naturalSize).applying(oriented)
            let sx = renderSize.width / max(1, bounds.width)
            let sy = renderSize.height / max(1, bounds.height)
            let scale = min(sx, sy)
            let offsetX = (renderSize.width - bounds.width * scale) / 2
            let offsetY = (renderSize.height - bounds.height * scale) / 2
            let normalized = oriented.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
            layer.setTransform(normalized, at: at)
            if fadeLength > 0 {
                let clipEnd = clip.timelineStart + clip.duration
                let rampStart = max(clip.timelineStart, fadeStart)
                if clipEnd > rampStart {
                    layer.setOpacityRamp(fromStartOpacity: opacity(at: rampStart),
                                         toEndOpacity: opacity(at: clipEnd),
                                         timeRange: CMTimeRange(start: CMTime(seconds: rampStart, preferredTimescale: 600),
                                                                duration: CMTime(seconds: clipEnd - rampStart, preferredTimescale: 600)))
                }
            }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: at, duration: range.duration)
            instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = CMTimeAdd(at, range.duration)
        }
        let total = CMTime(seconds: duration, preferredTimescale: 600)
        if CMTimeCompare(total, cursor) > 0 {
            let gap = AVMutableVideoCompositionInstruction()
            gap.timeRange = CMTimeRange(start: cursor, duration: CMTimeSubtract(total, cursor))
            gap.backgroundColor = CGColor(gray: 0, alpha: 1)
            instructions.append(gap)
        }

        let mix = AVMutableAudioMix()
        var mixParameters: [AVAudioMixInputParameters] = []
        if let originalAudio {
            let params = AVMutableAudioMixInputParameters(track: originalAudio)
            params.setVolume(keepOriginalAudio ? 1 : 0, at: .zero)
            mixParameters.append(params)
        }
        for clip in audioClips {
            guard clip.timelineStart < duration else { continue }
            let asset = AVURLAsset(url: clip.url)
            guard let source = asset.tracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let length = min(clip.duration, duration - clip.timelineStart)
            guard length > 0.05 else { continue }
            let at = CMTime(seconds: clip.timelineStart, preferredTimescale: 600)
            let range = CMTimeRange(start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                                    duration: CMTime(seconds: length, preferredTimescale: 600))
            try track.insertTimeRange(range, of: source, at: at)
            let params = AVMutableAudioMixInputParameters(track: track)
            let level = Float(clip.volume)
            params.setVolume(level, at: at)
            let fadeIn = min(clip.fadeIn, length / 2)
            let fadeOut = min(clip.fadeOut, length / 2)
            if fadeIn > 0 {
                params.setVolumeRamp(fromStartVolume: 0, toEndVolume: level,
                                     timeRange: CMTimeRange(start: at, duration: CMTime(seconds: fadeIn, preferredTimescale: 600)))
            }
            if fadeOut > 0 {
                let fadeStart = CMTime(seconds: clip.timelineStart + length - fadeOut, preferredTimescale: 600)
                params.setVolumeRamp(fromStartVolume: level, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: fadeStart, duration: CMTime(seconds: fadeOut, preferredTimescale: 600)))
            }
            mixParameters.append(params)
        }
        mix.inputParameters = mixParameters
        let videoComposition: AVMutableVideoComposition?
        if instructions.isEmpty { videoComposition = nil }
        else {
            let vc = AVMutableVideoComposition()
            vc.instructions = instructions
            vc.renderSize = renderSize
            vc.frameDuration = CMTime(value: 1, timescale: Int32(frameRate))
            videoComposition = vc
        }
        return (composition, mix, videoComposition)
    }

    func rebuild() {
        player.pause(); playing = false
        guard !clips.isEmpty else {
            player.replaceCurrentItem(with: nil)
            playhead = 0
            status = "Başlamak için videolarınızı ekleyin."
            return
        }
        do {
            let (asset, mix, videoComposition) = try composition()
            let item = AVPlayerItem(asset: asset)
            item.audioMix = mix
            item.videoComposition = videoComposition
            player.replaceCurrentItem(with: item)
            seek(to: min(playhead, max(0, duration - 0.02)))
        } catch {
            let ns = error as NSError
            self.error = "\(error.localizedDescription) (\(ns.domain):\(ns.code))"
        }
    }

    func export() {
        guard !clips.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Videoyu dışa aktar"
        panel.nameFieldStringValue = "Kadrena.mp4"
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .appleProtectedMPEG4Video]
        panel.canSelectHiddenExtension = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let ext = url.pathExtension.lowercased()
        let type: AVFileType = ext == "mov" ? .mov : ext == "m4v" ? .m4v : .mp4
        do {
            let (asset, mix, videoComposition) = try composition()
            guard let session = AVAssetExportSession(asset: asset, presetName: exportQuality.preset) else {
                throw EditorError.message("Dışa aktarma oturumu oluşturulamadı.")
            }
            guard session.supportedFileTypes.contains(type) else {
                throw EditorError.message("Seçilen dosya biçimi bu videolar için desteklenmiyor. MP4 veya MOV deneyin.")
            }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            session.outputURL = url
            session.outputFileType = type
            session.shouldOptimizeForNetworkUse = true
            session.audioMix = mix
            session.videoComposition = videoComposition
            exporting = true
            status = "Video dışa aktarılıyor…"
            session.exportAsynchronously { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.exporting = false
                    if session.status == .completed { self.status = "Video kaydedildi: \(url.lastPathComponent)" }
                    else {
                        let detail = session.error.map { "\($0.localizedDescription) (\(($0 as NSError).domain):\(($0 as NSError).code))" }
                        self.error = detail ?? "Video dışa aktarılamadı."
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

enum EditorError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}

func clock(_ time: Double) -> String {
    let n = max(0, Int(time))
    return String(format: "%02d:%02d", n / 60, n % 60)
}

func timecode(_ time: Double) -> String {
    let n = max(0, Int((time * 100).rounded()))
    return String(format: "%02d:%02d.%02d", n / 6000, (n / 100) % 60, n % 100)
}

struct TimelineClipBar: View {
    let name: String
    let icon: String
    let selected: Bool
    let isAudio: Bool
    let start: Double
    let duration: Double
    let scale: Double
    let height: CGFloat
    let select: () -> Void
    let seek: (Double) -> Void
    let move: (Double) -> Void
    let trim: (Bool, Double) -> Void
    @State private var moveDX = 0.0
    @State private var leftDX = 0.0
    @State private var rightDX = 0.0

    var body: some View {
        let baseWidth = max(24, duration * scale)
        let visibleWidth = max(24, baseWidth - leftDX + rightDX)
        HStack(spacing: 0) {
            handle(leading: true)
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(name).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? Color.white : isAudio ? SoftTheme.audioInk : SoftTheme.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                select()
                seek(start + max(0, value.location.x / scale))
            })
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { value in
                    select()
                    moveDX = value.translation.width
                }
                .onEnded { value in
                    let delta = value.translation.width
                    moveDX = 0
                    if abs(delta) < 3 { seek(start + value.startLocation.x / scale) }
                    else { move(max(0, start + delta / scale)) }
                })
            handle(leading: false)
        }
        .frame(width: visibleWidth, height: height)
        .background(selected ? (isAudio ? SoftTheme.audioSelected : SoftTheme.accent) : (isAudio ? SoftTheme.audioTrack : SoftTheme.videoTrack),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.white.opacity(0.65) : SoftTheme.highlight.opacity(0.5)))
        .offset(x: start * scale + moveDX + leftDX)
        .zIndex(selected ? 1 : 0)
        .help("Sürükle: taşı · Sol/sağ kenarı sürükle: kırp")
    }

    private func handle(leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(selected ? 0.8 : 0.5))
            .frame(width: 6, height: height - 12)
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    select()
                    if leading { leftDX = value.translation.width }
                    else { rightDX = value.translation.width }
                }
                .onEnded { value in
                    let delta = value.translation.width / scale
                    leftDX = 0; rightDX = 0
                    trim(leading, delta)
                })
    }
}

struct ContentView: View {
    @StateObject private var model = EditorModel()
    @State private var mediaSearch = ""
    @State private var showSettings = false
    @State private var timelineZoom = 1.0
    @State private var fullScreenWindow: FullScreenPreviewWindow?
    @State private var keyboardMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 16) {
                mediaPanel.frame(width: 250).softSurface()
                VStack(spacing: 16) {
                    preview.softSurface()
                    timeline.softSurface()
                }
                inspector.frame(width: 238).softSurface()
            }
            .padding(16)
            statusBar
        }
        .frame(minWidth: 1050, minHeight: 690)
        .background(SoftTheme.base)
        .preferredColorScheme(model.darkMode ? .dark : .light)
        .sheet(isPresented: $showSettings) { settingsPanel }
        .alert("İşlem tamamlanamadı", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Tamam", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onAppear { installKeyboardMonitor() }
        .onDisappear {
            if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor); self.keyboardMonitor = nil }
        }
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.keyWindow?.title == "Kadrena" else { return event }
            guard NSApp.keyWindow?.firstResponder is NSTextView == false else { return event }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if flags == .command {
                switch key {
                case "k": splitAtPlayhead()
                case "l": model.importSong()
                case "m": model.export()
                case "=": timelineZoom = min(5, timelineZoom + 0.25)
                case "-": timelineZoom = max(0.6, timelineZoom - 0.25)
                case ",": showSettings = true
                default: return event
                }
                return nil
            }
            if flags == [.command, .shift] {
                if key == "s" { model.saveProject(asNew: true); return nil }
                return event
            }
            if flags == [] {
                switch event.keyCode {
                case 123: model.stepFrames(-1)
                case 124: model.stepFrames(1)
                case 115: model.seek(to: 0)
                case 119: model.seek(to: model.duration)
                case 51, 117: model.removeSelection()
                default: return event
                }
                return nil
            }
            if flags == .shift {
                switch event.keyCode {
                case 123: model.stepSeconds(-1)
                case 124: model.stepSeconds(1)
                default: return event
                }
                return nil
            }
            return event
        }
    }

    private var videoFadeLabel: String {
        model.videoFadeOut < 0.05 ? "Kapalı" : String(format: "%.2f sn", model.videoFadeOut)
    }

    private func splitAtPlayhead() {
        if model.selectedAudioID != nil { model.splitAudio() }
        else { model.split() }
    }

    private func openFullScreenPreview() {
        guard !model.clips.isEmpty else { return }
        if let fullScreenWindow, fullScreenWindow.isVisible {
            fullScreenWindow.makeKeyAndOrderFront(nil)
            return
        }
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let window = FullScreenPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 750),
                                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                             backing: .buffered, defer: false, screen: screen)
        window.title = "Tam Ekran Önizleme"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FullScreenPreviewView(model: model) { [weak window] in
            window?.close()
        })
        window.onKeyDown = { [weak window, weak model] event in
            guard let model else { return false }
            switch event.keyCode {
            case 53: window?.close(); return true
            case 49: model.togglePlay(); return true
            case 123:
                if event.modifierFlags.contains(.shift) { model.stepSeconds(-1) }
                else { model.stepFrames(-1) }
                return true
            case 124:
                if event.modifierFlags.contains(.shift) { model.stepSeconds(1) }
                else { model.stepFrames(1) }
                return true
            default: return false
            }
        }
        fullScreenWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
                   let icon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "film.stack.fill").resizable().scaledToFit()
                }
            }
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Kadrena").font(.system(size: 18, weight: .bold))
                Text("Mac için video düzenleme").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Proje aç…", action: model.openProject)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Projeyi kaydet", action: { model.saveProject() })
                    .keyboardShortcut("s", modifiers: .command)
                Button("Farklı kaydet…", action: { model.saveProject(asNew: true) })
            } label: { Label("Proje", systemImage: "folder") }
                .menuStyle(.borderlessButton).frame(width: 82)
            Button(action: model.importVideos) { Label("Video ekle", systemImage: "plus") }
                .buttonStyle(ToolButtonStyle()).keyboardShortcut("o", modifiers: .command)
                .help("Yerel videoları ekle (⌘O)")
            Button(action: model.importSong) { Label("Ses ekle", systemImage: "music.note") }
                .buttonStyle(ToolButtonStyle())
            Button { showSettings = true } label: { Label("Ayarlar", systemImage: "gearshape.fill") }
                .buttonStyle(ToolButtonStyle()).keyboardShortcut(",", modifiers: .command)
            Menu {
                Button("Ses ekle…", action: model.importSong).keyboardShortcut("l", modifiers: .command)
                Button("Farklı kaydet…") { model.saveProject(asNew: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Dışa aktar…", action: model.export).keyboardShortcut("m", modifiers: .command)
                Divider()
                Button("Oynatma konumunda böl", action: splitAtPlayhead).keyboardShortcut("k", modifiers: .command)
                Button("Seçili klibi sil", action: model.removeSelection).keyboardShortcut(.delete, modifiers: [])
                Divider()
                Button("Önceki kare") { model.stepFrames(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("Sonraki kare") { model.stepFrames(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("1 saniye geri") { model.stepSeconds(-1) }.keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("1 saniye ileri") { model.stepSeconds(1) }.keyboardShortcut(.rightArrow, modifiers: .shift)
                Button("Başa git") { model.seek(to: 0) }.keyboardShortcut(.home, modifiers: [])
                Button("Sona git") { model.seek(to: model.duration) }.keyboardShortcut(.end, modifiers: [])
                Divider()
                Button("Zaman çizelgesini büyüt") { timelineZoom = min(5, timelineZoom + 0.25) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zaman çizelgesini küçült") { timelineZoom = max(0.6, timelineZoom - 0.25) }
                    .keyboardShortcut("-", modifiers: .command)
            } label: { Image(systemName: "keyboard").frame(width: 24) }
                .menuStyle(.borderlessButton)
                .help("Klavye kısayolları")
            Button(action: model.export) {
                if model.exporting { ProgressView().controlSize(.small) }
                else { Label("Dışa aktar", systemImage: "square.and.arrow.up") }
            }
                .buttonStyle(PrimaryButtonStyle()).disabled(model.clips.isEmpty || model.exporting)
                .keyboardShortcut("e", modifiers: .command)
                .help("Videoyu kaydet (⌘E)")
        }
        .padding(.horizontal, 22).frame(height: 70)
    }

    private var mediaPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("MEDYA", count: model.clips.count)
            if !model.clips.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Klip ara", text: $mediaSearch).textFieldStyle(.plain)
                }
                .font(.system(size: 12))
                .padding(9)
                .background(SoftTheme.base, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(SoftTheme.highlight.opacity(0.8)))
            }
            if model.clips.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Henüz video yok").font(.headline)
                    Text("Yerel videolarınızı ekleyip düzenlemeye başlayın.")
                        .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Video seç", action: model.importVideos).buttonStyle(PrimaryButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.clips.filter { mediaSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(mediaSearch) }) { clip in
                            Button { model.selectVideo(clip.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "film.fill").frame(width: 35, height: 35)
                                        .background(SoftTheme.base, in: RoundedRectangle(cornerRadius: 7))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(clip.name).lineLimit(1).font(.system(size: 12, weight: .medium))
                                        Text(clock(clip.duration)).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(8)
                                .background(clip.id == model.selectedID ? SoftTheme.accent.opacity(0.16) : SoftTheme.base, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(clip.id == model.selectedID ? SoftTheme.accent.opacity(0.7) : SoftTheme.highlight.opacity(0.8)))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Divider()
            Toggle("Videonun kendi sesi", isOn: $model.keepOriginalAudio)
                .font(.system(size: 12))
                .tint(SoftTheme.accent)
                .onChange(of: model.keepOriginalAudio) { _ in model.rebuild() }
            Divider()
            sectionTitle("SES KLİPLERİ", count: model.audioClips.count)
            if !model.audioClips.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.audioClips) { clip in
                            Button { model.selectAudio(clip.id); model.seek(to: clip.timelineStart) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "waveform").foregroundStyle(.mint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(clip.name).lineLimit(1).font(.system(size: 12, weight: .medium))
                                        Text("\(timecode(clip.timelineStart)) · \(timecode(clip.duration))")
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(8)
                                .background(model.selectedAudioID == clip.id ? Color.mint.opacity(0.20) : SoftTheme.base,
                                            in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 170)
            } else {
                Button(action: model.importSong) { Label("Müzik veya ses ekle", systemImage: "plus.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
            }
        }
        .padding(16)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ÖNİZLEME").font(.system(size: 11, weight: .bold)).tracking(1.3).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(CanvasPreset.allCases) { preset in
                        Button(preset.rawValue) { model.canvasPreset = preset; model.rebuild() }
                    }
                } label: {
                    Label(model.canvasPreset.rawValue, systemImage: "aspectratio")
                        .font(.system(size: 11, weight: .semibold))
                }.menuStyle(.borderlessButton).frame(width: 103)
                Text("\(timecode(model.playhead)) / \(timecode(model.duration))")
                    .monospacedDigit().font(.system(size: 11)).foregroundStyle(.secondary)
                Button(action: openFullScreenPreview) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .disabled(model.clips.isEmpty)
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .help("Tam ekran önizleme (⇧⌘F, çıkış: Esc)")
            }.padding(.horizontal, 20).frame(height: 44)
            GeometryReader { area in
                let availableWidth = max(1, area.size.width)
                let availableHeight = max(1, area.size.height)
                let width = min(availableWidth, availableHeight * model.canvasAspect)
                let height = width / model.canvasAspect
                ZStack {
                    Color(red: 0.08, green: 0.10, blue: 0.15)
                    if model.clips.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "play.square.stack").font(.system(size: 47)).foregroundStyle(.white.opacity(0.25))
                            Text("Önizleme burada görünecek").foregroundStyle(.white.opacity(0.5))
                        }
                    } else {
                        PlayerCanvas(player: model.player)
                    }
                }
                .frame(width: width, height: height)
                .clipped()
                .position(x: area.size.width / 2, y: area.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 26).padding(.bottom, 16)
            HStack(spacing: 14) {
                Button { model.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }.buttonStyle(.plain)
                Button(action: model.togglePlay) {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .frame(width: 36, height: 36)
                        .background(SoftTheme.base, in: Circle())
                        .shadow(color: SoftTheme.highlight, radius: 4, x: -3, y: -3)
                        .shadow(color: SoftTheme.shadow, radius: 5, x: 3, y: 3)
                }.buttonStyle(.plain).disabled(model.clips.isEmpty).keyboardShortcut(.space, modifiers: [])
                Button { model.seek(to: model.duration) } label: { Image(systemName: "forward.end.fill") }.buttonStyle(.plain)
                Slider(value: Binding(get: { model.playhead }, set: { model.seek(to: $0) }), in: 0...max(0.1, model.duration))
                    .tint(SoftTheme.accent).disabled(model.clips.isEmpty)
            }
            .padding(.horizontal, 30).frame(height: 54)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Ayarlar", systemImage: "gearshape.fill").font(.system(size: 21, weight: .bold))
                Spacer()
                Button("Kapat") { showSettings = false }.buttonStyle(ToolButtonStyle())
            }
            Divider()
            Toggle("Koyu tema", isOn: $model.darkMode)
            Picker("Tuval oranı", selection: $model.canvasPreset) {
                ForEach(CanvasPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
            }
            .onChange(of: model.canvasPreset) { _ in model.rebuild() }
            HStack {
                Text("Çıktı boyutu")
                Spacer()
                Text("\(Int(model.canvasSize.width)) × \(Int(model.canvasSize.height)) px")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 13))
            Text("Kaynak, ilk videonun dikey veya yatay oranını korur. Farklı oranlı klipler kadraja sığdırılır.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("Video sonunda kararma")
                Spacer()
                Text(videoFadeLabel).monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 13))
            Slider(value: $model.videoFadeOut, in: 0...max(0.1, min(10, model.videoEnd)), onEditingChanged: { editing in
                if !editing { model.rebuild() }
            }).tint(SoftTheme.accent).disabled(model.clips.isEmpty)
            Text("Görüntü seçilen süre boyunca siyaha geçer. Ses soldurması ses klibinin ayarlarında kalır.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Kare hızı", selection: $model.frameRate) {
                Text("24 fps").tag(24)
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }.onChange(of: model.frameRate) { _ in model.rebuild() }
            Picker("Çıktı kalitesi", selection: $model.exportQuality) {
                ForEach(ExportQuality.allCases) { quality in Text(quality.rawValue).tag(quality) }
            }
            Toggle("Videonun kendi sesini kullan", isOn: $model.keepOriginalAudio)
                .onChange(of: model.keepOriginalAudio) { _ in model.rebuild() }
            Spacer()
        }
        .padding(25)
        .frame(width: 440, height: 525)
        .preferredColorScheme(model.darkMode ? .dark : .light)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("ZAMAN ÇİZELGESİ").font(.system(size: 11, weight: .bold)).tracking(1.3).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "minus.magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $timelineZoom, in: 0.6...5).frame(width: 95).tint(SoftTheme.accent)
                Image(systemName: "plus.magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                Button {
                    splitAtPlayhead()
                } label: { Label("Böl", systemImage: "scissors") }
                    .buttonStyle(ToolButtonStyle()).disabled(model.clips.isEmpty)
                    .keyboardShortcut("b", modifiers: .command)
                    .help("İmlecin bulunduğu yerde seçili klibi böl (⌘B)")
            }
            GeometryReader { geometry in
                let scale = 50.0 * timelineZoom
                let width = max(geometry.size.width, (model.duration + 2) * scale)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 7) {
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(SoftTheme.trackWell).frame(width: width, height: 25)
                            ForEach(0...Int(ceil(width / scale)), id: \.self) { second in
                                if second % (timelineZoom < 1 ? 5 : 1) == 0 {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Rectangle().fill(SoftTheme.highlight).frame(width: 1, height: 7)
                                        Text(clock(Double(second))).font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }.offset(x: Double(second) * scale + 2)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            model.seek(to: value.location.x / scale)
                        })
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 7).fill(SoftTheme.trackWell)
                                .frame(width: width, height: 53)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onEnded { model.seek(to: $0.location.x / scale) })
                            ForEach(model.clips) { clip in
                                TimelineClipBar(name: clip.name, icon: "film", selected: model.selectedID == clip.id,
                                                isAudio: false, start: clip.timelineStart, duration: clip.duration, scale: scale,
                                                height: 53,
                                                select: { model.selectVideo(clip.id) },
                                                seek: { model.seek(to: $0) },
                                                move: { model.moveVideo(clip.id, to: $0) },
                                                trim: { leading, delta in model.trimVideoEdge(clip.id, leading: leading, delta: delta) })
                            }
                        }.frame(width: width, height: 53)
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 7).fill(SoftTheme.trackWell)
                                .frame(width: width, height: 42)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onEnded { model.seek(to: $0.location.x / scale) })
                            ForEach(model.audioClips) { clip in
                                TimelineClipBar(name: clip.name, icon: "waveform", selected: model.selectedAudioID == clip.id,
                                                isAudio: true, start: clip.timelineStart, duration: clip.duration, scale: scale,
                                                height: 42,
                                                select: { model.selectAudio(clip.id) },
                                                seek: { model.seek(to: $0) },
                                                move: { model.moveAudio(clip.id, to: $0) },
                                                trim: { leading, delta in model.trimAudioEdge(clip.id, leading: leading, delta: delta) })
                            }
                        }.frame(width: width, height: 42)
                    }
                    .overlay(alignment: .topLeading) {
                        Rectangle().fill(SoftTheme.playhead).frame(width: 2, height: 141)
                            .offset(x: model.playhead * scale)
                            .allowsHitTesting(false)
                    }
                    .frame(width: width, alignment: .leading)
                }
            }
            Text("Cetvele tıklayıp konum seçin · Klibi sürükleyin · Kenarından kırpın · ⌘B ile bölün")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Oynatma: \(timecode(model.playhead))   ·   Toplam: \(timecode(model.duration))")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(height: 260)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 17) {
            sectionTitle(model.selectedAudioID == nil ? "VİDEO AYARLARI" : "SES AYARLARI", count: nil)
            if let i = model.selectedAudioIndex {
                let clip = model.audioClips[i]
                let maxFade = max(0.01, min(5, clip.duration / 2, max(0.01, model.duration - clip.timelineStart) / 2))
                Text(clip.name).font(.headline).lineLimit(2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Konum  \(timecode(clip.timelineStart))")
                    Text("Süre      \(timecode(clip.duration))")
                }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text("Ses klibini zaman çizelgesinde sürükleyerek taşıyın; kenarlarını sürükleyerek kırpın.")
                    .font(.caption).foregroundStyle(.secondary)
                Button { model.splitAudio() } label: {
                    Label("Oynatma noktasında böl", systemImage: "scissors")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(ToolButtonStyle())
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ses düzeyi · \(Int(clip.volume * 100))%")
                    Slider(value: Binding(get: { model.audioClips[i].volume }, set: { model.audioClips[i].volume = $0 }),
                           in: 0...1, onEditingChanged: { if !$0 { model.rebuild() } }).tint(.mint)
                    Text("Giriş soldurması · \(String(format: "%.2f", clip.fadeIn)) sn")
                    Slider(value: Binding(get: { model.audioClips[i].fadeIn }, set: { model.audioClips[i].fadeIn = $0 }),
                           in: 0...maxFade, onEditingChanged: { if !$0 { model.rebuild() } }).tint(.mint)
                    Text("Çıkış soldurması · \(String(format: "%.2f", clip.fadeOut)) sn")
                    Slider(value: Binding(get: { model.audioClips[i].fadeOut }, set: { model.audioClips[i].fadeOut = $0 }),
                           in: 0...maxFade, onEditingChanged: { if !$0 { model.rebuild() } }).tint(.mint)
                }.font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { model.removeSelectedAudio() } label: {
                    Label("Ses klibini sil", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(ToolButtonStyle())
            } else if let i = model.selectedIndex {
                let clip = model.clips[i]
                Text(clip.name).font(.headline).lineLimit(2)
                Text("Kaynak: \(timecode(clip.sourceStart)) – \(timecode(clip.sourceEnd))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Klibi zaman çizelgesinde sürükleyerek taşıyın; kenarlarını sürükleyerek kırpın.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    Button { model.trimSelectedAtPlayhead(startEdge: true) } label: {
                        Label("Başlangıcı buraya al", systemImage: "arrow.right.to.line")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { model.trimSelectedAtPlayhead(startEdge: false) } label: {
                        Label("Bitişi buraya al", systemImage: "arrow.left.to.line")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.buttonStyle(ToolButtonStyle())
                Button(role: .destructive) { model.removeSelected() } label: {
                    Label("Video klibini sil", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(ToolButtonStyle())
            } else {
                Text("Düzenlemek için video veya ses klibi seçin.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("İpucu: Cetvelde konumu seçin; klibi sürükleyerek taşıyın veya kenarından kırpın.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(SoftTheme.base, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
    }

    private var statusBar: some View {
        HStack {
            Circle().fill(model.exporting ? Color.orange : Color.green).frame(width: 7, height: 7)
            Text(model.status).lineLimit(1)
            Spacer()
            Text("\(model.clips.count) video · \(model.audioClips.count) ses  ·  \(timecode(model.duration))")
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).frame(height: 29)
        .background(SoftTheme.base)
    }

    private func sectionTitle(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
            Spacer()
            if let count { Text("\(count)").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }

}

struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(SoftTheme.base, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(SoftTheme.highlight.opacity(0.8)))
            .shadow(color: SoftTheme.highlight, radius: configuration.isPressed ? 1 : 4, x: -3, y: -3)
            .shadow(color: SoftTheme.shadow, radius: configuration.isPressed ? 1 : 5, x: 3, y: 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(configuration.isPressed ? SoftTheme.accent.opacity(0.75) : SoftTheme.accent, in: RoundedRectangle(cornerRadius: 9))
            .foregroundStyle(.white)
            .shadow(color: SoftTheme.accent.opacity(0.3), radius: 8, y: 4)
    }
}

final class PlayerLayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let videoLayer = AVPlayerLayer()
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        layer = videoLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerCanvas: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(frame: .zero)
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

final class FullScreenPreviewWindow: NSWindow {
    var onKeyDown: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }
}

struct FullScreenPreviewView: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    var body: some View {
        GeometryReader { area in
            let width = min(area.size.width, area.size.height * model.canvasAspect)
            let height = width / model.canvasAspect
            PlayerCanvas(player: model.player)
                .frame(width: width, height: height)
                .position(x: area.size.width / 2, y: area.size.height / 2)
        }
        .background(Color.black)
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Label("Tam ekrandan çık", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 15).padding(.vertical, 9)
                    .background(.black.opacity(0.7), in: Capsule())
            }
            .buttonStyle(.plain).foregroundStyle(.white)
            .padding(26)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 18) {
                Button { model.stepFrames(-1) } label: { Image(systemName: "backward.frame.fill") }
                Button(action: model.togglePlay) {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 20)).frame(width: 35)
                }
                Button { model.stepFrames(1) } label: { Image(systemName: "forward.frame.fill") }
                Text(timecode(model.playhead)).monospacedDigit()
                Slider(value: Binding(get: { model.playhead }, set: { model.seek(to: $0) }),
                       in: 0...max(0.1, model.duration)).tint(.white)
                Text(timecode(model.duration)).monospacedDigit()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 40).padding(.bottom, 28)
        }
        .onExitCommand(perform: close)
    }
}

enum SoftTheme {
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let base = adaptive(light: NSColor(red: 0.91, green: 0.93, blue: 0.97, alpha: 1),
                               dark: NSColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1))
    static let accent = adaptive(light: NSColor(red: 0.37, green: 0.30, blue: 0.78, alpha: 1),
                                 dark: NSColor(red: 0.55, green: 0.47, blue: 0.91, alpha: 1))
    static let ink = adaptive(light: NSColor(red: 0.16, green: 0.19, blue: 0.29, alpha: 1),
                              dark: NSColor(red: 0.90, green: 0.92, blue: 0.98, alpha: 1))
    static let highlight = adaptive(light: .white,
                                    dark: NSColor(red: 0.24, green: 0.27, blue: 0.34, alpha: 1))
    static let shadow = adaptive(light: NSColor(red: 0.68, green: 0.72, blue: 0.80, alpha: 0.65),
                                 dark: NSColor(white: 0, alpha: 0.6))
    static let videoTrack = adaptive(light: NSColor(red: 0.82, green: 0.82, blue: 0.95, alpha: 1),
                                     dark: NSColor(red: 0.31, green: 0.29, blue: 0.45, alpha: 1))
    static let audioTrack = adaptive(light: NSColor(red: 0.70, green: 0.86, blue: 0.81, alpha: 1),
                                     dark: NSColor(red: 0.17, green: 0.35, blue: 0.32, alpha: 1))
    static let audioSelected = adaptive(light: NSColor(red: 0.10, green: 0.53, blue: 0.43, alpha: 1),
                                        dark: NSColor(red: 0.13, green: 0.57, blue: 0.45, alpha: 1))
    static let audioInk = adaptive(light: NSColor(red: 0.12, green: 0.31, blue: 0.27, alpha: 1),
                                   dark: NSColor(red: 0.87, green: 0.97, blue: 0.93, alpha: 1))
    static let trackWell = adaptive(light: NSColor(red: 0.86, green: 0.89, blue: 0.94, alpha: 1),
                                    dark: NSColor(red: 0.10, green: 0.12, blue: 0.17, alpha: 1))
    static let playhead = ink
}

extension View {
    func softSurface() -> some View {
        self.background(SoftTheme.base, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(SoftTheme.highlight.opacity(0.8), lineWidth: 1))
            .shadow(color: SoftTheme.highlight, radius: 10, x: -7, y: -7)
            .shadow(color: SoftTheme.shadow, radius: 13, x: 7, y: 7)
    }
}

@main struct VideoAtolyesiApp: App {
    var body: some Scene {
        WindowGroup("Kadrena") { ContentView() }
            .windowStyle(.titleBar)
    }
}
