import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import UIKit

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
    let id: UUID
    let url: URL
    var sourceStart: Double
    var sourceEnd: Double
    var timelineStart: Double
    var volume: Double = 0.7
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var duration: Double { max(0, sourceEnd - sourceStart) }
    var name: String { url.deletingPathExtension().lastPathComponent }
    init(url: URL, sourceStart: Double, sourceEnd: Double, timelineStart: Double, volume: Double = 0.7) {
        self.id = UUID(); self.url = url; self.sourceStart = sourceStart; self.sourceEnd = sourceEnd
        self.timelineStart = timelineStart; self.volume = volume
    }
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
    @Published var shareURL: URL?
    @Published var exportProgress = 0.0
    private var exportTimer: Timer?
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

    private var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private func libraryURL(for original: URL) throws -> URL {
        let access = original.startAccessingSecurityScopedResource()
        defer { if access { original.stopAccessingSecurityScopedResource() } }
        let directory = documents.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + "-" + original.lastPathComponent
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: original, to: target)
        return target
    }

    func importVideos(urls: [URL]) {
        var added = 0
        for original in urls {
            do {
                let url = try libraryURL(for: original)
                let asset = AVURLAsset(url: url)
                let seconds = CMTimeGetSeconds(asset.duration)
                guard seconds.isFinite && seconds > 0.05, !asset.tracks(withMediaType: .video).isEmpty else {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                let clip = VideoClip(url: url, sourceStart: 0, sourceEnd: seconds, timelineStart: videoEnd)
                clips.append(clip)
                selectedID = clip.id
                added += 1
            } catch { self.error = "Video eklenemedi: \(error.localizedDescription)" }
        }
        if added == 0 && error == nil { error = "Okunabilen bir video akışı bulunamadı." }
        else if added > 0 { status = "\(added) video eklendi."; rebuild() }
    }

    func importSong(url original: URL) {
        do {
            let url = try libraryURL(for: original)
            let asset = AVURLAsset(url: url)
            let length = CMTimeGetSeconds(asset.duration)
            guard length.isFinite && length > 0.05, !asset.tracks(withMediaType: .audio).isEmpty else {
                try? FileManager.default.removeItem(at: url)
                throw EditorError.message("Okunabilen bir ses akışı bulunamadı.")
            }
            let start = max(0, playhead)
            let clip = AudioClip(url: url, sourceStart: 0, sourceEnd: length, timelineStart: start)
            audioClips.append(clip)
            selectedAudioID = clip.id
            selectedID = nil
            status = "Ses parçası \(timecode(start)) konumuna eklendi."
            rebuild()
        } catch { self.error = "Ses eklenemedi: \(error.localizedDescription)" }
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
        do {
            let directory = documents.appendingPathComponent("Projects", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = (!asNew ? projectURL : nil) ?? directory.appendingPathComponent("Kadrena-\(Int(Date().timeIntervalSince1970)).json")
            let project = EditorProject(clips: clips, audioClips: audioClips, canvasPreset: canvasPreset,
                                        frameRate: frameRate, exportQuality: exportQuality,
                                        keepOriginalAudio: keepOriginalAudio, darkMode: darkMode,
                                        videoFadeOut: videoFadeOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: destination, options: .atomic)
            projectURL = destination
            status = "Proje kaydedildi: \(destination.lastPathComponent)"
        } catch { self.error = "Proje kaydedilemedi: \(error.localizedDescription)" }
    }

    func availableProjects() -> [URL] {
        let directory = documents.appendingPathComponent("Projects", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return files.filter { $0.pathExtension.lowercased() == "json" }.sorted { modified($0) > modified($1) }
    }

    func openProject(url: URL) {
        do {
            let project = try JSONDecoder().decode(EditorProject.self, from: Data(contentsOf: url))
            guard (1...3).contains(project.version) else { throw EditorError.message("Bu proje sürümü desteklenmiyor.") }
            let mediaURLs = project.clips.map(\.url) + project.audioClips.map(\.url)
            if let missing = mediaURLs.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                throw EditorError.message("Kaynak dosya bulunamadı: \(missing.lastPathComponent)")
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

    func shareProject() {
        if projectURL == nil { saveProject() }
        shareURL = projectURL
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

    func export(format: AVFileType) {
        guard !clips.isEmpty, !exporting else { return }
        let ext = format == .mov ? "mov" : format == .m4v ? "m4v" : "mp4"
        let directory = documents.appendingPathComponent("Exports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Kadrena-\(Int(Date().timeIntervalSince1970)).\(ext)")
            let (asset, mix, videoComposition) = try composition()
            guard let session = AVAssetExportSession(asset: asset, presetName: exportQuality.preset) else {
                throw EditorError.message("Dışa aktarma oturumu oluşturulamadı.")
            }
            guard session.supportedFileTypes.contains(format) else {
                throw EditorError.message("Bu video için seçilen çıktı biçimi desteklenmiyor.")
            }
            session.outputURL = url
            session.outputFileType = format
            session.shouldOptimizeForNetworkUse = true
            session.audioMix = mix
            session.videoComposition = videoComposition
            exporting = true
            exportProgress = 0
            status = "Video dışa aktarılıyor…"
            exportTimer?.invalidate()
            exportTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak session] _ in
                Task { @MainActor in self?.exportProgress = Double(session?.progress ?? 0) }
            }
            session.exportAsynchronously { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.exportTimer?.invalidate()
                    self.exportTimer = nil
                    self.exporting = false
                    if session.status == .completed {
                        self.exportProgress = 1
                        self.status = "Video hazır: \(url.lastPathComponent)"
                        self.shareURL = url
                    } else {
                        self.error = session.error?.localizedDescription ?? "Video dışa aktarılamadı."
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
