import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import UIKit
import PhotosUI

struct ContentView: View {
    @StateObject private var model = EditorModel()
    @State private var showVideoImporter = false
    @State private var showAudioImporter = false
    @State private var showPhotos = false
    @State private var showSettings = false
    @State private var showProjects = false
    @State private var showFullScreen = false
    @State private var showExportMenu = false
    @State private var shareItem: ShareItem?
    @State private var timelineZoom = 1.0

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    header
                    preview
                    timeline
                    inspector
                    statusBar
                }
                .padding(.horizontal, geometry.size.width > 700 ? 26 : 14)
                .padding(.top, 10)
                .padding(.bottom, 30)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
            .background(SoftTheme.base.ignoresSafeArea())
        }
        .preferredColorScheme(model.darkMode ? .dark : .light)
        .fileImporter(isPresented: $showVideoImporter, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importVideos(urls: urls)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio, .mp3, .mpeg4Audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importSong(url: url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $showSettings) { settingsPanel }
        .sheet(isPresented: $showPhotos) {
            PhotoVideoPicker(onPick: { url in
                model.importVideos(urls: [url])
                try? FileManager.default.removeItem(at: url)
            }, onError: { model.error = $0 })
        }
        .sheet(isPresented: $showProjects) { projectsPanel }
        .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
        .fullScreenCover(isPresented: $showFullScreen) { fullScreenPreview }
        .confirmationDialog("Çıktı biçimi", isPresented: $showExportMenu) {
            Button("MP4") { model.export(format: .mp4) }
            Button("MOV") { model.export(format: .mov) }
            Button("M4V") { model.export(format: .m4v) }
        } message: { Text("Dışa aktarma bitince paylaşım menüsü açılır.") }
        .alert("İşlem tamamlanamadı", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Tamam", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: model.shareURL) { url in
            if let url { shareItem = ShareItem(url: url); model.shareURL = nil }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image("BrandMark").resizable().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Kadrena").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Video düzenleme stüdyosu").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Menu {
                    Button("Projeyi kaydet", systemImage: "square.and.arrow.down") { model.saveProject() }
                        .keyboardShortcut("s", modifiers: .command)
                    Button("Farklı kaydet", systemImage: "square.on.square") { model.saveProject(asNew: true) }
                    Button("Proje aç", systemImage: "folder") { showProjects = true }
                    Button("Projeyi paylaş", systemImage: "square.and.arrow.up") { model.shareProject() }
                } label: {
                    Image(systemName: "folder").font(.system(size: 19)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Projeler")
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 19)).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Ayarlar")
                .keyboardShortcut(",", modifiers: .command)
            }
            HStack(spacing: 10) {
                Button { showVideoImporter = true } label: {
                    Label("Video ekle", systemImage: "film.stack.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("o", modifiers: .command)
                Button { showAudioImporter = true } label: {
                    Label("Ses ekle", systemImage: "music.note").frame(maxWidth: .infinity)
                }
                .buttonStyle(ToolButtonStyle())
                .keyboardShortcut("l", modifiers: .command)
                Button { showPhotos = true } label: {
                    Image(systemName: "photo.on.rectangle").frame(width: 32)
                }
                .buttonStyle(ToolButtonStyle())
                .accessibilityLabel("Fotoğraflardan video ekle")
                Button { showExportMenu = true } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: 36)
                }
                .buttonStyle(ToolButtonStyle())
                .disabled(model.clips.isEmpty || model.exporting)
                .accessibilityLabel("Dışa aktar")
                .keyboardShortcut("e", modifiers: .command)
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 8) {
            HStack {
                Text("ÖNİZLEME").sectionHeading()
                Spacer()
                Menu {
                    ForEach(CanvasPreset.allCases) { preset in
                        Button(preset.rawValue) { model.canvasPreset = preset; model.rebuild() }
                    }
                } label: { Label(model.canvasPreset.rawValue, systemImage: "aspectratio") }
                    .font(.caption)
                Button { showFullScreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .frame(width: 40, height: 40)
                    .disabled(model.clips.isEmpty)
                    .accessibilityLabel("Tam ekran önizleme")
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            GeometryReader { area in
                let width = min(area.size.width, area.size.height * model.canvasAspect)
                let height = width / model.canvasAspect
                ZStack {
                    Color.black
                    if model.clips.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "play.square.stack").font(.system(size: 42))
                            Text("Video ekleyerek başlayın").font(.subheadline)
                        }.foregroundStyle(.white.opacity(0.55))
                    } else {
                        PlayerCanvas(player: model.player)
                            .frame(width: width, height: height)
                    }
                }
                .frame(width: area.size.width, height: area.size.height)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .frame(height: 260)
            HStack(spacing: 12) {
                Button { model.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                    .accessibilityLabel("Başa git")
                Button { model.stepFrames(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .accessibilityLabel("Önceki kare")
                Button(action: model.togglePlay) {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 21))
                        .frame(width: 48, height: 48)
                        .background(SoftTheme.accent, in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(model.clips.isEmpty)
                .accessibilityLabel(model.playing ? "Duraklat" : "Oynat")
                .keyboardShortcut(.space, modifiers: [])
                Button { model.stepFrames(1) } label: { Image(systemName: "forward.frame.fill") }
                    .accessibilityLabel("Sonraki kare")
                Button { model.seek(to: model.duration) } label: { Image(systemName: "forward.end.fill") }
                    .accessibilityLabel("Sona git")
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)
            .disabled(model.clips.isEmpty)
            HStack(spacing: 8) {
                Text(timecode(model.playhead))
                Slider(value: Binding(get: { model.playhead }, set: { model.seek(to: $0) }), in: 0...max(0.1, model.duration))
                    .tint(SoftTheme.accent)
                    .disabled(model.clips.isEmpty)
                Text(timecode(model.duration))
            }
            .font(.system(size: 11, design: .monospaced))
            .monospacedDigit()
        }
        .padding(14)
        .softSurface()
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ZAMAN ÇİZELGESİ").sectionHeading()
                Spacer()
                Button { timelineZoom = max(0.6, timelineZoom - 0.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("Zaman çizelgesini küçült")
                Button { timelineZoom = min(5, timelineZoom + 0.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Zaman çizelgesini büyüt")
            }
            HStack(spacing: 8) {
                Button { splitAtPlayhead() } label: { Label("Böl", systemImage: "scissors") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.selectedID == nil && model.selectedAudioID == nil)
                    .keyboardShortcut("b", modifiers: .command)
                Button(role: .destructive) { model.removeSelection() } label: { Label("Sil", systemImage: "trash") }
                    .buttonStyle(ToolButtonStyle())
                    .disabled(model.selectedID == nil && model.selectedAudioID == nil)
                    .keyboardShortcut(.delete, modifiers: [])
                Spacer()
                Text("\(timecode(model.playhead)) / \(timecode(model.duration))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let scale = 50.0 * timelineZoom
                let width = max(geometry.size.width, (model.duration + 2) * scale)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 7) {
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(SoftTheme.trackWell).frame(width: width, height: 29)
                            ForEach(0...Int(ceil(width / scale)), id: \.self) { second in
                                if second % (timelineZoom < 1 ? 5 : 1) == 0 {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Rectangle().fill(SoftTheme.ink.opacity(0.4)).frame(width: 1, height: 8)
                                        Text(clock(Double(second))).font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }.offset(x: Double(second) * scale + 2)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(to: $0.location.x / scale) })
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 8).fill(SoftTheme.trackWell)
                                .frame(width: width, height: 56)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onEnded { model.seek(to: $0.location.x / scale) })
                            ForEach(model.clips) { clip in
                                TimelineClipBar(name: clip.name, icon: "film", selected: model.selectedID == clip.id,
                                                isAudio: false, start: clip.timelineStart, duration: clip.duration, scale: scale,
                                                height: 56, select: { model.selectVideo(clip.id) },
                                                seek: { model.seek(to: $0) }, move: { model.moveVideo(clip.id, to: $0) },
                                                trim: { leading, delta in model.trimVideoEdge(clip.id, leading: leading, delta: delta) })
                            }
                        }.frame(width: width, height: 56)
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 8).fill(SoftTheme.trackWell)
                                .frame(width: width, height: 49)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onEnded { model.seek(to: $0.location.x / scale) })
                            ForEach(model.audioClips) { clip in
                                TimelineClipBar(name: clip.name, icon: "waveform", selected: model.selectedAudioID == clip.id,
                                                isAudio: true, start: clip.timelineStart, duration: clip.duration, scale: scale,
                                                height: 49, select: { model.selectAudio(clip.id) },
                                                seek: { model.seek(to: $0) }, move: { model.moveAudio(clip.id, to: $0) },
                                                trim: { leading, delta in model.trimAudioEdge(clip.id, leading: leading, delta: delta) })
                            }
                        }.frame(width: width, height: 49)
                    }
                    .overlay(alignment: .topLeading) {
                        Rectangle().fill(SoftTheme.accent).frame(width: 2, height: 148)
                            .offset(x: model.playhead * scale).allowsHitTesting(false)
                    }
                    .frame(width: width, alignment: .leading)
                }
            }
            .frame(height: 158)
            Text("Cetvele dokun: konum seç · Klibi sürükle: taşı · Kenarını sürükle: kırp")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .softSurface()
    }

    private func splitAtPlayhead() {
        if model.selectedAudioID != nil { model.splitAudio() }
        else { model.split() }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.selectedAudioID == nil ? "VİDEO AYARLARI" : "SES AYARLARI").sectionHeading()
            if let i = model.selectedAudioIndex {
                let clip = model.audioClips[i]
                let maxFade = max(0.01, min(5, clip.duration / 2, max(0.01, model.duration - clip.timelineStart) / 2))
                Text(clip.name).font(.headline).lineLimit(1)
                HStack {
                    Text("Başlangıç: \(timecode(clip.timelineStart))")
                    Spacer()
                    Text("Süre: \(timecode(clip.duration))")
                }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                settingSlider("Ses düzeyi", value: Binding(get: { model.audioClips[i].volume }, set: { model.audioClips[i].volume = $0 }), range: 0...1, label: "\(Int(clip.volume * 100))%", tint: .mint) { model.rebuild() }
                settingSlider("Giriş soldurması", value: Binding(get: { model.audioClips[i].fadeIn }, set: { model.audioClips[i].fadeIn = $0 }), range: 0...maxFade, label: String(format: "%.1f sn", clip.fadeIn), tint: .mint) { model.rebuild() }
                settingSlider("Çıkış soldurması", value: Binding(get: { model.audioClips[i].fadeOut }, set: { model.audioClips[i].fadeOut = $0 }), range: 0...maxFade, label: String(format: "%.1f sn", clip.fadeOut), tint: .mint) { model.rebuild() }
                Button("Sesi sil", role: .destructive) { model.removeSelectedAudio() }
            } else if let i = model.selectedIndex {
                let clip = model.clips[i]
                Text(clip.name).font(.headline).lineLimit(1)
                Text("Kaynak: \(timecode(clip.sourceStart)) – \(timecode(clip.sourceEnd))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                HStack {
                    Button("Başlangıcı buraya al") { model.trimSelectedAtPlayhead(startEdge: true) }
                    Button("Bitişi buraya al") { model.trimSelectedAtPlayhead(startEdge: false) }
                }.font(.caption)
                Button("Videoyu sil", role: .destructive) { model.removeSelected() }
            } else {
                Text("Düzenlemek için zaman çizelgesinde bir klip seçin.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .softSurface()
    }

    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String, tint: Color, onEnd: @escaping () -> Void) -> some View {
        VStack(spacing: 2) {
            HStack { Text(title); Spacer(); Text(label).monospacedDigit().foregroundStyle(.secondary) }
                .font(.caption)
            Slider(value: value, in: range, onEditingChanged: { if !$0 { onEnd() } }).tint(tint)
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            if model.exporting { ProgressView(value: model.exportProgress).tint(SoftTheme.accent) }
            Text("\(model.clips.count) video · \(model.audioClips.count) ses · \(timecode(model.duration))")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsPanel: some View {
        NavigationStack {
            Form {
                Section("Görünüm ve tuval") {
                    Toggle("Koyu tema", isOn: $model.darkMode)
                    Picker("Tuval oranı", selection: $model.canvasPreset) {
                        ForEach(CanvasPreset.allCases) { preset in Text(preset.rawValue).tag(preset) }
                    }.onChange(of: model.canvasPreset) { _ in model.rebuild() }
                    LabeledContent("Çıktı boyutu", value: "\(Int(model.canvasSize.width)) × \(Int(model.canvasSize.height))")
                    Text("Kaynak, ilk videonun oranını korur. Farklı oranlı klipler kırpılmadan sığdırılır.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Video ve ses") {
                    settingSlider("Video sonunda kararma", value: $model.videoFadeOut,
                                  range: 0...max(0.1, min(10, model.videoEnd)),
                                  label: String(format: "%.1f sn", model.videoFadeOut), tint: SoftTheme.accent) { model.rebuild() }
                        .disabled(model.clips.isEmpty)
                    Toggle("Videonun kendi sesini kullan", isOn: $model.keepOriginalAudio)
                        .onChange(of: model.keepOriginalAudio) { _ in model.rebuild() }
                    Picker("Kare hızı", selection: $model.frameRate) {
                        Text("24 fps").tag(24); Text("30 fps").tag(30); Text("60 fps").tag(60)
                    }.onChange(of: model.frameRate) { _ in model.rebuild() }
                    Picker("Çıktı kalitesi", selection: $model.exportQuality) {
                        ForEach(ExportQuality.allCases) { quality in Text(quality.rawValue).tag(quality) }
                    }
                }
            }
            .navigationTitle("Ayarlar")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Bitti") { showSettings = false } } }
        }
        .preferredColorScheme(model.darkMode ? .dark : .light)
    }

    private var projectsPanel: some View {
        NavigationStack {
            List {
                let projects = model.availableProjects()
                if projects.isEmpty { ContentUnavailableView("Proje yok", systemImage: "folder", description: Text("Proje menüsünden ilk projenizi kaydedin.")) }
                ForEach(projects, id: \.self) { url in
                    Button {
                        model.openProject(url: url)
                        showProjects = false
                    } label: {
                        Label(url.deletingPathExtension().lastPathComponent, systemImage: "film.stack")
                    }
                }
            }
            .navigationTitle("Projeler")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Bitti") { showProjects = false } } }
        }
        .preferredColorScheme(model.darkMode ? .dark : .light)
    }

    private var fullScreenPreview: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { area in
                let width = min(area.size.width, area.size.height * model.canvasAspect)
                let height = width / model.canvasAspect
                PlayerCanvas(player: model.player)
                    .frame(width: width, height: height)
                    .position(x: area.size.width / 2, y: area.size.height / 2)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { showFullScreen = false } label: { Label("Kapat", systemImage: "xmark") }
                        .padding(10).background(.black.opacity(0.55), in: Capsule())
                }
                Spacer()
                HStack(spacing: 18) {
                    Button { model.stepFrames(-1) } label: { Image(systemName: "backward.frame.fill") }
                    Button(action: model.togglePlay) { Image(systemName: model.playing ? "pause.fill" : "play.fill") }
                        .font(.title2)
                    Button { model.stepFrames(1) } label: { Image(systemName: "forward.frame.fill") }
                    Text(timecode(model.playhead)).font(.system(size: 12, design: .monospaced))
                }
                Slider(value: Binding(get: { model.playhead }, set: { model.seek(to: $0) }),
                       in: 0...max(0.1, model.duration)).tint(.white)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(20)
        }
        .persistentSystemOverlays(.hidden)
    }
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
        let baseWidth = max(36, duration * scale)
        let visibleWidth = max(36, baseWidth - leftDX + rightDX)
        HStack(spacing: 0) {
            handle(leading: true)
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(name).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? .white : isAudio ? SoftTheme.audioInk : SoftTheme.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                select()
                seek(start + max(0, value.location.x / scale))
            })
            .gesture(DragGesture(minimumDistance: 5)
                .onChanged { value in select(); moveDX = value.translation.width }
                .onEnded { value in
                    let delta = value.translation.width
                    moveDX = 0
                    if abs(delta) < 5 { seek(start + value.startLocation.x / scale) }
                    else { move(max(0, start + delta / scale)) }
                })
            handle(leading: false)
        }
        .frame(width: visibleWidth, height: height)
        .background(selected ? (isAudio ? SoftTheme.audioSelected : SoftTheme.accent) : (isAudio ? SoftTheme.audioTrack : SoftTheme.videoTrack),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.white.opacity(0.8) : SoftTheme.highlight.opacity(0.5)))
        .offset(x: start * scale + moveDX + leftDX)
        .zIndex(selected ? 1 : 0)
    }

    private func handle(leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(selected ? 0.9 : 0.6))
            .frame(width: 5, height: height - 18)
            .frame(width: 17, height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
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

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct PlayerCanvas: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(frame: .zero)
        view.playerLayer.player = player
        return view
    }
    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct PhotoVideoPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .videos
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onError: onError) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL) -> Void
        let onError: (String) -> Void
        init(onPick: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
            self.onPick = onPick; self.onError = onError
        }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            for result in results {
                let provider = result.itemProvider
                let identifier = provider.registeredTypeIdentifiers.first {
                    UTType($0)?.conforms(to: .movie) == true
                } ?? UTType.movie.identifier
                provider.loadFileRepresentation(forTypeIdentifier: identifier) { [weak self] url, error in
                    guard let self else { return }
                    guard let url else {
                        DispatchQueue.main.async { self.onError(error?.localizedDescription ?? "Video alınamadı.") }
                        return
                    }
                    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    let temporary = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                    do {
                        try FileManager.default.copyItem(at: url, to: temporary)
                        DispatchQueue.main.async { self.onPick(temporary) }
                    } catch {
                        DispatchQueue.main.async { self.onError(error.localizedDescription) }
                    }
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum SoftTheme {
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { trait in trait.userInterfaceStyle == .dark ? dark : light })
    }
    static let base = adaptive(light: UIColor(red: 0.91, green: 0.93, blue: 0.97, alpha: 1), dark: UIColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1))
    static let accent = adaptive(light: UIColor(red: 0.37, green: 0.30, blue: 0.78, alpha: 1), dark: UIColor(red: 0.55, green: 0.47, blue: 0.91, alpha: 1))
    static let ink = adaptive(light: UIColor(red: 0.16, green: 0.19, blue: 0.29, alpha: 1), dark: UIColor(red: 0.90, green: 0.92, blue: 0.98, alpha: 1))
    static let highlight = adaptive(light: .white, dark: UIColor(red: 0.24, green: 0.27, blue: 0.34, alpha: 1))
    static let shadow = adaptive(light: UIColor(red: 0.68, green: 0.72, blue: 0.80, alpha: 0.65), dark: UIColor(white: 0, alpha: 0.55))
    static let videoTrack = adaptive(light: UIColor(red: 0.82, green: 0.82, blue: 0.95, alpha: 1), dark: UIColor(red: 0.31, green: 0.29, blue: 0.45, alpha: 1))
    static let audioTrack = adaptive(light: UIColor(red: 0.70, green: 0.86, blue: 0.81, alpha: 1), dark: UIColor(red: 0.17, green: 0.35, blue: 0.32, alpha: 1))
    static let audioSelected = adaptive(light: UIColor(red: 0.10, green: 0.53, blue: 0.43, alpha: 1), dark: UIColor(red: 0.13, green: 0.57, blue: 0.45, alpha: 1))
    static let audioInk = adaptive(light: UIColor(red: 0.12, green: 0.31, blue: 0.27, alpha: 1), dark: UIColor(red: 0.87, green: 0.97, blue: 0.93, alpha: 1))
    static let trackWell = adaptive(light: UIColor(red: 0.86, green: 0.89, blue: 0.94, alpha: 1), dark: UIColor(red: 0.10, green: 0.12, blue: 0.17, alpha: 1))
}

extension View {
    func softSurface() -> some View {
        self.background(SoftTheme.base, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(SoftTheme.highlight.opacity(0.6), lineWidth: 1))
            .shadow(color: SoftTheme.highlight.opacity(0.6), radius: 7, x: -4, y: -4)
            .shadow(color: SoftTheme.shadow.opacity(0.7), radius: 9, x: 5, y: 5)
    }
    func sectionHeading() -> some View {
        self.font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
    }
}

struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 10).frame(minHeight: 42)
            .background(SoftTheme.base, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(SoftTheme.highlight.opacity(0.6)))
            .shadow(color: SoftTheme.shadow.opacity(0.6), radius: 5, x: 3, y: 3)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 10).frame(minHeight: 42)
            .background(SoftTheme.accent.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 11))
            .foregroundStyle(.white)
            .shadow(color: SoftTheme.accent.opacity(0.3), radius: 7, y: 3)
    }
}

@main struct KadrenaIOSApp: App {
    init() { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback) }
    var body: some Scene { WindowGroup { ContentView() } }
}
