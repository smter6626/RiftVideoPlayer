import AVFoundation
import AppKit
import CryptoKit
import IOKit.pwr_mgt
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Rift", category: "PlayerState")

enum PlaybackBackend {
    case avFoundation
    case directFFmpeg
}

@MainActor
final class PlayerState: NSObject, ObservableObject, AVPlayerItemLegibleOutputPushDelegate {
    // A single AVPlayer instance is shared between the video layer and SwiftUI controls.
    let player = AVPlayer()

    @Published var fileName = "Video.mp4"
    @Published var isPlaying = false {
        didSet {
            if isPlaying { preventSleep() } else { allowSleep() }
        }
    }
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double {
        didSet { UserDefaults.standard.set(volume, forKey: SettingsKey.volume) }
    }
    @Published var playbackRate: Float {
        didSet { UserDefaults.standard.set(playbackRate, forKey: SettingsKey.playbackRate) }
    }
    @Published var fpsMode: FPSMode = .native {
        didSet { UserDefaults.standard.set(fpsMode.rawValue, forKey: SettingsKey.fpsMode) }
    }
    @Published var hasVideo = false
    @Published var statusMessage: String?
    @Published var conversionProgress: Double? = nil
    @Published var videoCodec: String? = nil
    @Published var audioCodec: String? = nil
    @Published var videoResolution: String? = nil
    @Published var sourceFrameRate: Double? = nil
    @Published var currentRenderingFPS: Double = 0.0
    @Published var isArtificialInterpolationActive = false
    @Published var fluxWorkingWidth: Int? = nil
    @Published var fluxOpticalFlowUsage: Double = 0.0
    @Published var fluxBlendFallbackUsage: Double = 0.0
    @Published var rifeStatus: String = NSLocalizedString("RIFE without model", comment: "")
    @Published var isRIFELoaded = false
    @Published var audioTracks: [AudioTrack] = []
    @Published var selectedAudioTrackIndex: Int = 0
    @Published var url: URL?
    @Published var interpolationMode: InterpolationMode = .disabled {
        didSet { UserDefaults.standard.set(interpolationMode.rawValue, forKey: SettingsKey.interpolationMode) }
    }
    @Published var isFramePlusPreparing = false
    @Published var isFramePlusPreRendered = false
    @Published var visualEnhancementsEnabled = false {
        didSet { UserDefaults.standard.set(visualEnhancementsEnabled, forKey: SettingsKey.visualEnhancements) }
    }
    @Published var rifeEnabled: Bool = false
    @Published var metrics = PlaybackMetrics()
    @Published var availableTracks: [MediaTrack] = []
    @Published var selectedAudioTrack: MediaTrack?
    @Published var selectedSubtitleTrack: MediaTrack?
    @Published var currentSubtitleText: String?
    @Published var hdrMetadata: HDRMetadata?
    @Published var isHDRContent = false
    @Published var playbackBackend: PlaybackBackend = .avFoundation
    @Published var directPlaybackURL: URL?
    @Published var usesNativeVideoLayer = false

    @Published var areControlsVisible = true
    var controlsAutoHideLastInteraction = Date()
    var controlsAutoHideTimer: Timer?

    func startHideTimer() {
        controlsAutoHideTimer?.invalidate()
        controlsAutoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.areControlsVisible else { return }
                guard self.hasVideo else { return }
                guard Date.now.timeIntervalSince(self.controlsAutoHideLastInteraction) >= 5 else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
                    self.areControlsVisible = false
                }
                NSCursor.hide()
            }
        }
    }

    func resetHideTimer() {
        controlsAutoHideLastInteraction = Date.now
        if !areControlsVisible {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                areControlsVisible = true
            }
            NSCursor.unhide()
        }
    }

    func stopHideTimer() {
        controlsAutoHideTimer?.invalidate()
        controlsAutoHideTimer = nil
    }

    private var sleepAssertionID: IOPMAssertionID = 0

    private func preventSleep() {
        guard sleepAssertionID == 0 else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            NSLocalizedString("Player is active", comment: "") as CFString,
            &sleepAssertionID
        )
    }

    private func allowSleep() {
        guard sleepAssertionID != 0 else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = 0
    }

    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private var audioSelectionGroup: AVMediaSelectionGroup?
    private var audioOptionsByIndex: [Int: AVMediaSelectionOption] = [:]
    private var subtitleSelectionGroup: AVMediaSelectionGroup?
    private var subtitleOptionsByID: [String: AVMediaSelectionOption] = [:]
    private var conversionProcess: Process?
    private var convertedVideoURL: URL?
    private var convertedVideoDirectoryURL: URL?
    private var convertedVideoShouldCleanup = true
    private var hlsServer: LocalHLSHTTPServer?
    private var hlsPlaylistUpdateTask: Task<Void, Never>?
    private var hlsSourcePlaylistURL: URL?
    private var hlsPlaybackPlaylistURL: URL?
    private var hlsMinimumRevealDuration: TimeInterval = 0
    private var hlsPlaybackOffset: Double = 0
    private var hlsSeekTask: Task<Void, Never>?
    private var audioTrackTask: Task<Void, Never>?
    private var hlsShouldResumePlayback = false
    private var cachedSourceMetadataURL: URL?
    private var cachedSourceStreams: [StreamInfo] = []
    private var cachedSourceDuration: Double?
    private var framePlusVideoURL: URL?
    private var originalVideoURL: URL?
    private var playbackSourceURL: URL?
    private var knownPlaybackDuration: Double?
    private var attemptedCompatibleFallback = false
    private weak var directPlaybackController: DirectFFmpegPlaybackControlling?
    private let rates: [Float] = [1.0, 1.25, 1.5, 2.0]
    private let containerFormatsNeedingConversion: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "ts", "m2ts"]

    var displayRenderingFPS: Double {
        if isFramePlusPreRendered { return 60 }
        if currentRenderingFPS > 0 { return currentRenderingFPS }
        if isFramePlusPreparing { return sourceFrameRate ?? 24 }
        return sourceFrameRate ?? 0
    }

    private enum SettingsKey {
        static let volume = "RiftVolume"
        static let playbackRate = "RiftPlaybackRate"
        static let interpolationMode = "RiftInterpolationMode"
        static let visualEnhancements = "RiftVisualEnhancements"
        static let fpsMode = "RiftFPSMode"
    }

    override init() {
        let loadedVolume = UserDefaults.standard.double(forKey: SettingsKey.volume)
        volume = loadedVolume > 0 ? min(max(loadedVolume, 0), 1) : 0.72
        let loadedRate = UserDefaults.standard.float(forKey: SettingsKey.playbackRate)
        playbackRate = loadedRate > 0 ? loadedRate : 1.0
        let loadedFPSMode = UserDefaults.standard.string(forKey: SettingsKey.fpsMode)
            .flatMap { FPSMode(rawValue: $0) } ?? .native
        fpsMode = loadedFPSMode
        let loadedInterpolation = UserDefaults.standard.string(forKey: SettingsKey.interpolationMode)
            .flatMap { InterpolationMode(rawValue: $0) } ?? .disabled
        interpolationMode = loadedInterpolation
        visualEnhancementsEnabled = UserDefaults.standard.bool(forKey: SettingsKey.visualEnhancements)

        super.init()
        player.volume = Float(volume)
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .none
        addTimeObserver()

        Logger.playback.info("Settings loaded: volume=\(self.volume), rate=\(self.playbackRate), fps=\(self.fpsMode.rawValue), interpolation=\(self.interpolationMode.rawValue)")

        if CommandLine.arguments.contains("--fps=60") {
            fpsMode = .flux
            interpolationMode = .motion2Intense
        }

        if let path = Self.launchVideoPath(from: CommandLine.arguments) {
            Task { @MainActor in
                self.loadVideo(URL(fileURLWithPath: path))
            }
        }
    }

    private static func launchVideoPath(from arguments: [String]) -> String? {
        arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-") }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    func cleanup() {
        player.pause()
        directPlaybackController?.shutdown()
        directPlaybackController = nil
        directPlaybackURL = nil
        playbackBackend = .avFoundation
        usesNativeVideoLayer = false
        knownPlaybackDuration = nil
        hlsPlaybackOffset = 0
        cachedSourceMetadataURL = nil
        cachedSourceStreams = []
        cachedSourceDuration = nil
        detachLegibleOutput()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
        hasVideo = false

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        conversionProcess?.terminate()
        conversionProcess = nil
        hlsSeekTask?.cancel()
        hlsSeekTask = nil
        hlsShouldResumePlayback = false
        itemStatusObservation = nil
        cleanupConvertedVideo()
    }

    func closeVideo() {
        Logger.playback.info("Closing video: \(self.fileName)")
        player.pause()
        directPlaybackController?.shutdown()
        directPlaybackController = nil
        directPlaybackURL = nil
        playbackBackend = .avFoundation
        usesNativeVideoLayer = false
        knownPlaybackDuration = nil
        hlsPlaybackOffset = 0
        cachedSourceMetadataURL = nil
        cachedSourceStreams = []
        cachedSourceDuration = nil
        detachLegibleOutput()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
        hasVideo = false
        conversionProcess?.terminate()
        conversionProcess = nil
        hlsSeekTask?.cancel()
        hlsSeekTask = nil
        hlsShouldResumePlayback = false
        itemStatusObservation = nil
        cleanupConvertedVideo()
    }

    func togglePlay() {
        if playbackBackend == .directFFmpeg {
            if isPlaying {
                directPlaybackController?.pause()
                isPlaying = false
            } else {
                directPlaybackController?.play()
                isPlaying = true
            }
            return
        }

        guard player.currentItem != nil else { return }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let boundedSeconds = duration > 0
            ? max(0, min(seconds, duration))
            : max(0, seconds)

        if playbackBackend == .directFFmpeg {
            directPlaybackController?.seek(to: boundedSeconds)
            currentTime = boundedSeconds
            return
        }

        if playbackSourceURL?.scheme?.lowercased().hasPrefix("http") == true {
            seekHLS(to: boundedSeconds)
            currentTime = boundedSeconds
            return
        }

        let time = CMTime(seconds: boundedSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = boundedSeconds
    }

    func seek(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func setVolume(_ value: Double) {
        volume = max(0, min(value, 1))
        directPlaybackController?.setVolume(volume)
        player.volume = Float(volume)
    }

    func cyclePlaybackRate() {
        // Cycles through the exact speed states requested by the UI spec.
        let currentIndex = rates.firstIndex(of: playbackRate) ?? 0
        playbackRate = rates[(currentIndex + 1) % rates.count]

        if playbackBackend == .directFFmpeg {
            directPlaybackController?.setPlaybackRate(playbackRate)
            return
        }

        if isPlaying {
            player.rate = playbackRate
        }
    }

    func cycleFPSMode() {
        withAnimation(.easeInOut(duration: 0.22)) {
            fpsMode = fpsMode.next
        }
    }

    func setInterpolationMode(_ mode: InterpolationMode) {
        if playbackBackend == .directFFmpeg {
            if mode == .disabled {
                interpolationMode = .disabled
                fpsMode = .native
                isArtificialInterpolationActive = false
                statusMessage = nil
            } else {
                switchDirectPlaybackToCompatible {
                    self.setInterpolationMode(mode)
                }
            }
            return
        }

        let requiresRIFE = mode == .rife2x || mode == .rife4x || mode == .rifeAdaptive
        guard mode == .disabled || mode == .motion2Intense || (requiresRIFE && isRIFELoaded) else {
            interpolationMode = .disabled
            rifeEnabled = false
            fpsMode = .native
            statusMessage = NSLocalizedString("RIFE not available: missing RIFE.mlpackage", comment: "")
            applyVisualCompositionIfNeeded()
            return
        }

        if mode == .disabled {
            stopFramePlusPreparation()
            restoreBaseVideoIfNeeded()
            currentRenderingFPS = 0
            isArtificialInterpolationActive = false
            fluxWorkingWidth = nil
            fluxOpticalFlowUsage = 0
            fluxBlendFallbackUsage = 0
            rifeEnabled = false
        }

        interpolationMode = mode
        rifeEnabled = requiresRIFE && isRIFELoaded
        fpsMode = mode == .disabled ? .native : .flux
        applyVisualCompositionIfNeeded()

        if mode == .motion2Intense {
            isFramePlusPreparing = false
            isFramePlusPreRendered = false
            statusMessage = nil
            startFramePlusPreparationForShortLowFPSClipIfUseful()
        }
    }

    func selectPipelineTrack(_ track: MediaTrack?) {
        guard let track else {
            selectedSubtitleTrack = nil
            if playbackBackend == .directFFmpeg {
                directPlaybackController?.selectSubtitleTrack(nil)
                return
            }
            applySubtitleSelection(nil)
            return
        }

        switch track.kind {
        case .audio:
            selectedAudioTrack = track
        case .subtitle:
            selectedSubtitleTrack = track
            if playbackBackend == .directFFmpeg {
                directPlaybackController?.selectSubtitleTrack(track.index)
                return
            }
            applySubtitleSelection(track)
        case .video:
            break
        }
    }

    func selectAudioTrack(_ index: Int) {
        audioTrackTask?.cancel()
        guard index < audioTracks.count else { return }
        if playbackBackend == .directFFmpeg {
            selectedAudioTrackIndex = index
            selectedAudioTrack = availableTracks.first { $0.kind == .audio && $0.index == index }
            directPlaybackController?.selectAudioTrack(index)
            return
        }

        guard let item = player.currentItem else { return }
        selectedAudioTrackIndex = index
        selectedAudioTrack = availableTracks.first { $0.kind == .audio && $0.index == index }

        if let audioSelectionGroup,
           let option = audioOptionsByIndex[index] {
            item.select(option, in: audioSelectionGroup)
            item.audioMix = nil
            return
        }

        audioTrackTask = Task {
            guard let allTracks = try? await item.asset.loadTracks(withMediaType: .audio) else { return }
            await MainActor.run {
                self.applyAudioMix(trackIndex: index, to: item, allTracks: allTracks)
            }
        }
    }

    func toggleVisualEnhancements() {
        if playbackBackend == .directFFmpeg {
            switchDirectPlaybackToCompatible {
                self.visualEnhancementsEnabled = true
                self.applyVisualCompositionIfNeeded()
            }
            return
        }

        visualEnhancementsEnabled.toggle()
        applyVisualCompositionIfNeeded()
    }

    func openVideo() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Open Video", comment: "")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url)
    }

    func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%02d:%02d", minutes, seconds)
    }

    func loadVideo(_ url: URL) {
        self.url = url
        originalVideoURL = url
        playbackSourceURL = nil
        attemptedCompatibleFallback = false
        directPlaybackController?.shutdown()
        directPlaybackURL = nil
        playbackBackend = .avFoundation
        usesNativeVideoLayer = false
        knownPlaybackDuration = nil
        hlsPlaybackOffset = 0
        cachedSourceMetadataURL = nil
        cachedSourceStreams = []
        cachedSourceDuration = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        isFramePlusPreparing = false
        isFramePlusPreRendered = false
        conversionProcess?.terminate()
        conversionProcess = nil
        hlsSeekTask?.cancel()
        hlsSeekTask = nil
        hlsShouldResumePlayback = false
        cleanupConvertedVideo()

        videoCodec = nil
        audioCodec = nil
        videoResolution = nil
        sourceFrameRate = nil
        currentRenderingFPS = 0.0
        isArtificialInterpolationActive = false
        fluxWorkingWidth = nil
        fluxOpticalFlowUsage = 0.0
        fluxBlendFallbackUsage = 0.0
        rifeStatus = NSLocalizedString("RIFE without model", comment: "")
        isRIFELoaded = false
        audioTracks = []
        selectedAudioTrackIndex = 0
        availableTracks = []
        selectedAudioTrack = nil
        selectedSubtitleTrack = nil
        currentSubtitleText = nil
        hdrMetadata = nil
        isHDRContent = false
        metrics = PlaybackMetrics()

        if !url.isFileURL || url.pathExtension.lowercased() == "m3u8" || url.scheme?.lowercased().hasPrefix("http") == true {
            // Skip validation for HLS streams and non-file URLs
        } else if !Self.isValidVideoFile(url) {
            Logger.playback.warning("Invalid video file rejected: \(url.path, privacy: .public)")
            statusMessage = NSLocalizedString("Invalid video file", comment: "")
            hasVideo = false
            return
        }

        if needsConversion(url) {
            Task { @MainActor in
                await convertAndLoadVideo(url)
            }
            return
        }

        statusMessage = NSLocalizedString("Inspecting file...", comment: "")
        Task { @MainActor in
            await prepareVideoMetadata(for: url)
            playVideo(url, displayName: url.lastPathComponent)
        }
    }

    private func loadDirectVideo(_ url: URL) {
        detachLegibleOutput()
        cleanupConvertedVideo()
        playbackBackend = .directFFmpeg
        directPlaybackURL = url
        playbackSourceURL = url
        fileName = url.lastPathComponent
        hasVideo = true
        isPlaying = false
        currentTime = 0
        duration = 0
        interpolationMode = .disabled
        fpsMode = .native
        visualEnhancementsEnabled = false
        statusMessage = NSLocalizedString("Opening MKV direct...", comment: "")

        Task { @MainActor in
            await prepareVideoMetadata(for: url)
        }
    }

    private func switchDirectPlaybackToCompatible(configure: @escaping () -> Void) {
        guard playbackBackend == .directFFmpeg,
              let sourceURL = directPlaybackURL ?? originalVideoURL else {
            configure()
            return
        }

        let resumeTime = currentTime
        let shouldResume = isPlaying

        statusMessage = NSLocalizedString("Switching to compatible mode...", comment: "")
        directPlaybackController?.shutdown()
        directPlaybackController = nil
        directPlaybackURL = nil
        playbackBackend = .avFoundation
        usesNativeVideoLayer = false
        playbackSourceURL = nil
        hlsShouldResumePlayback = shouldResume
        isPlaying = shouldResume

        configure()

        Task { @MainActor in
            await convertAndLoadVideo(sourceURL, allowFastRemux: true, startAt: resumeTime)
        }
    }

    func attachDirectPlaybackController(_ controller: DirectFFmpegPlaybackControlling) {
        directPlaybackController = controller
        controller.setVolume(volume)
        controller.setPlaybackRate(playbackRate)
    }

    func detachDirectPlaybackController(_ controller: DirectFFmpegPlaybackControlling) {
        if (directPlaybackController as AnyObject?) === controller {
            directPlaybackController = nil
        }
    }

    func directPlaybackDidLoadTracks(
        audioTracks: [AudioTrack],
        availableTracks: [MediaTrack],
        selectedAudioIndex: Int,
        selectedSubtitleTrack: MediaTrack?,
        nominalFrameRate: Float
    ) {
        guard playbackBackend == .directFFmpeg else { return }
        self.audioTracks = audioTracks
        self.availableTracks = availableTracks
        self.selectedAudioTrackIndex = selectedAudioIndex
        self.selectedAudioTrack = availableTracks.first { $0.kind == .audio && $0.index == selectedAudioIndex }
        self.selectedSubtitleTrack = selectedSubtitleTrack
        if nominalFrameRate > 0 {
            self.sourceFrameRate = Double(nominalFrameRate)
            self.currentRenderingFPS = Double(nominalFrameRate)
        }
    }

    func directPlaybackDidFail(_ message: String) {
        guard playbackBackend == .directFFmpeg, let sourceURL = directPlaybackURL else { return }
        statusMessage = "\(message) \(NSLocalizedString("Preparing compatible...", comment: ""))"
        directPlaybackController?.shutdown()
        directPlaybackController = nil
        directPlaybackURL = nil
        playbackBackend = .avFoundation

        Task { @MainActor in
            await convertAndLoadVideo(sourceURL)
        }
    }

    private func prepareVideoMetadata(for url: URL) async {
        let streams = await inspectCodecs(for: url)
        await MainActor.run {
            let videoStream = streams.first { $0.codecType == "video" }
            let audioStream = streams.first { $0.codecType == "audio" }
            
            self.videoCodec = videoStream?.codecName.uppercased()
            self.audioCodec = audioStream?.codecName.uppercased()
            
            if let w = videoStream?.width, let h = videoStream?.height {
                self.videoResolution = "\(w)x\(h)"
            } else {
                self.videoResolution = nil
            }
            self.sourceFrameRate = videoStream?.frameRate
        }
    }

    private func playVideo(_ url: URL, displayName: String) {
        detachLegibleOutput()
        playbackSourceURL = url
        usesNativeVideoLayer = false
        let item = AVPlayerItem(url: url)
        if url.scheme?.lowercased().hasPrefix("http") == true {
            item.preferredForwardBufferDuration = hlsPlaybackOffset > 0 ? 0.75 : 2.0
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        }
        configureLegibleOutput(for: item)
        applyVisualCompositionIfNeeded(to: item)
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }

                switch item.status {
                case .unknown:
                    break
                case .readyToPlay:
                    self.statusMessage = nil
                    self.loadFrameRateFallback(from: item.asset)
                    self.loadMediaTracks(from: item)
                    let isHLS = self.playbackSourceURL?.scheme?.lowercased().hasPrefix("http") == true
                    let shouldStartPlayback = !isHLS || self.hlsShouldResumePlayback
                    if shouldStartPlayback {
                        self.player.playImmediately(atRate: self.playbackRate)
                        self.isPlaying = true
                    } else {
                        self.isPlaying = false
                    }
                    if isHLS {
                        self.hlsShouldResumePlayback = false
                    }
                case .failed:
                    if self.retryCompatibleConversionIfNeeded() {
                        return
                    }
                    self.statusMessage = NSLocalizedString("Could not load converted video", comment: "")
                    self.isPlaying = false
                @unknown default:
                    break
                }
            }
        }

        player.replaceCurrentItem(with: item)
        player.volume = Float(volume)

        fileName = displayName.isEmpty ? "Video.mp4" : displayName
        currentTime = url.scheme?.lowercased().hasPrefix("http") == true ? hlsPlaybackOffset : 0
        duration = knownPlaybackDuration?.isFinite == true ? knownPlaybackDuration ?? 0 : 0
        isPlaying = false
        hasVideo = true
        statusMessage = nil

        Task {
            let loadedDuration = try? await item.asset.load(.duration)
            await MainActor.run {
                if let seconds = loadedDuration?.seconds, seconds.isFinite, seconds > 0 {
                    duration = seconds
                } else if duration <= 0, let knownPlaybackDuration, knownPlaybackDuration.isFinite {
                    duration = knownPlaybackDuration
                }
                startFramePlusPreparationForShortLowFPSClipIfUseful()
            }
        }
    }

    private func needsConversion(_ url: URL) -> Bool {
        containerFormatsNeedingConversion.contains(url.pathExtension.lowercased())
    }

    static func isValidVideoFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count >= 16 else { return false }

        let bytes = [UInt8](header)

        if bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 { return true }
        if bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x00 && bytes[3] == 0x1C { return true }
        if bytes[0] == 0x66 && bytes[1] == 0x74 && bytes[2] == 0x79 && bytes[3] == 0x70 { return true }
        if bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 { return true }
        if bytes[0] == 0x46 && bytes[1] == 0x4C && bytes[2] == 0x56 { return true }
        if bytes[0] == 0x30 && bytes[1] == 0x26 && bytes[2] == 0xB2 && bytes[3] == 0x75 { return true }
        if bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 { return true }
        if bytes[0] == 0x41 && bytes[1] == 0x56 && bytes[2] == 0x49 && bytes[3] == 0x20 { return true } // AVI2.0
        if bytes[0] == 0xA6 && bytes[1] == 0xD9 && bytes[2] == 0x00 && bytes[3] == 0xAA { return true } // ASF (WMV)

        return false
    }

    private static func cachedCompatibleVideoURL(for sourceURL: URL) -> URL? {
        guard let directory = compatibleVideoCacheDirectory(),
              let key = compatibleVideoCacheKey(for: sourceURL) else {
            return nil
        }

        return directory.appendingPathComponent(key).appendingPathExtension("mp4")
    }

    private static func compatibleVideoCacheDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Rift", isDirectory: true)
            .appendingPathComponent("CompatibleVideoCache", isDirectory: true)
    }

    private static func compatibleVideoCacheKey(for sourceURL: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path) else {
            return nil
        }

        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = "\(sourceURL.standardizedFileURL.path)|\(fileSize)|\(modifiedAt)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isUsableCachedVideo(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }

        return size.uint64Value > 1_048_576
    }

    private static func ensureCompatibleVideoCacheDirectoryExists(for cacheURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return true
        } catch {
            logger.error("Failed to create compatible-video cache directory: \(error.localizedDescription)")
            return false
        }
    }

    private static let maxCacheSizeBytes: UInt64 = 10 * 1024 * 1024 * 1024 // 10 GB

    private static func enforceCacheSizeLimit() {
        guard let cacheDir = compatibleVideoCacheDirectory() else { return }
        guard let enumerator = FileManager.default.enumerator(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsSubdirectoryDescendants
        ) else { return }

        var files: [(url: URL, size: UInt64, date: Date)] = []
        var totalSize: UInt64 = 0

        for case let fileURL as URL in enumerator {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value,
                  let date = attrs[.modificationDate] as? Date else { continue }
            files.append((fileURL, size, date))
            totalSize += size
        }

        guard totalSize > maxCacheSizeBytes else { return }

        files.sort { $0.date < $1.date }
        var excess = totalSize - maxCacheSizeBytes

        for file in files {
            guard excess > 0 else { break }
            try? FileManager.default.removeItem(at: file.url)
            excess -= min(excess, file.size)
        }

        Logger.playback.info("Cache limit enforced: removed \(files.count) files, freed \(totalSize - (totalSize - excess)) bytes")
    }

    struct AudioTrack: Identifiable {
        let id: Int
        let label: String
        let language: String?
    }

    struct StreamInfo {
        let index: Int
        let codecName: String
        let codecType: String
        let width: Int?
        let height: Int?
        let frameRate: Double?
        let language: String?
        let title: String?
    }

    struct PlaybackMetrics {
        var actualFPS: Double = 0
        var rifeLatencyMS: Double = 0
        var placeboLatencyMS: Double = 0
        var droppedFrames: Int = 0
        var interpolatedFrames: Int = 0
        var totalFrames: Int = 0
    }

    private func inspectCodecs(for url: URL) async -> [StreamInfo] {
        guard let ffprobeURL = findFFprobe() else {
            logger.warning("ffprobe not found in PATH; codec/track list will be empty")
            return []
        }

        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-show_entries", "stream=index,codec_name,codec_type,width,height,avg_frame_rate:stream_tags=language,title",
            "-of", "json",
            url.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()

            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let d = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: d)
                }
            }

            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return [] }

            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawStreams = root["streams"] as? [[String: Any]] else {
                return []
            }

            return rawStreams.compactMap { raw in
                guard let index = raw["index"] as? Int,
                      let codecName = raw["codec_name"] as? String,
                      let codecType = raw["codec_type"] as? String else {
                    return nil
                }
                let tags = raw["tags"] as? [String: Any]
                return StreamInfo(
                    index: index,
                    codecName: codecName.lowercased(),
                    codecType: codecType.lowercased(),
                    width: raw["width"] as? Int,
                    height: raw["height"] as? Int,
                    frameRate: (raw["avg_frame_rate"] as? String).flatMap(Self.parseFrameRate),
                    language: tags?["language"] as? String,
                    title: tags?["title"] as? String
                )
            }
        } catch {
            logger.error("ffprobe codec inspection failed: \(error.localizedDescription)")
            return []
        }
    }

    private func inspectDuration(for url: URL) async -> Double? {
        guard let ffprobeURL = findFFprobe() else {
            logger.warning("ffprobe not found in PATH; duration/codec info will be limited")
            if statusMessage == nil {
                statusMessage = NSLocalizedString("ffprobe not found — duration and codec info may be limited", comment: "")
            }
            return nil
        }

        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: pipe.fileHandleForReading.readDataToEndOfFile())
                }
            }
            process.waitUntilExit()

            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8),
                  let duration = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)),
                  duration.isFinite,
                  duration > 0 else {
                return nil
            }

            return duration
        } catch {
            return nil
        }
    }

    private func convertAndLoadVideo(_ sourceURL: URL, allowFastRemux: Bool = true, startAt: Double = 0) async {
        statusMessage = startAt > 0
            ? "\(NSLocalizedString("Seeking...", comment: "")) \(formattedTime(startAt))"
            : NSLocalizedString("Inspecting file...", comment: "")
        if startAt <= 0 {
            hasVideo = false
        }
        fileName = sourceURL.lastPathComponent

        if allowFastRemux,
           let cachedURL = Self.cachedCompatibleVideoURL(for: sourceURL),
           Self.isUsableCachedVideo(cachedURL) {
            statusMessage = NSLocalizedString("Opening cache...", comment: "")
            convertedVideoDirectoryURL = nil
            convertedVideoURL = cachedURL
            convertedVideoShouldCleanup = false
            playVideo(cachedURL, displayName: sourceURL.lastPathComponent)
            if startAt > 0 {
                seek(to: startAt)
            }
            return
        }

        guard let ffmpegURL = findFFmpeg() else {
            statusMessage = NSLocalizedString("This format requires FFmpeg", comment: "")
            hasVideo = false
            return
        }

        // Inspeccionar códecs y duración original para que los streams HLS tengan timeline real.
        let canReuseCachedMetadata = startAt > 0
            && cachedSourceMetadataURL?.standardizedFileURL == sourceURL.standardizedFileURL
            && !cachedSourceStreams.isEmpty
        let streams: [StreamInfo]
        let sourceDuration: Double?
        if canReuseCachedMetadata {
            streams = cachedSourceStreams
            sourceDuration = cachedSourceDuration ?? knownPlaybackDuration
        } else {
            streams = await inspectCodecs(for: sourceURL)
            sourceDuration = await inspectDuration(for: sourceURL)
            cachedSourceMetadataURL = sourceURL.standardizedFileURL
            cachedSourceStreams = streams
            cachedSourceDuration = sourceDuration
        }
        let videoStream = streams.first { $0.codecType == "video" }
        let audioStream = streams.first { $0.codecType == "audio" }
        
        let videoCodec = videoStream?.codecName
        let audioCodec = audioStream?.codecName

        let canFastRemuxVideo = ["h264", "hevc", "h265"].contains(videoCodec)
        let mp4VideoTagArgs = (videoCodec == "hevc" || videoCodec == "h265") ? ["-tag:v", "hvc1"] : []
        let textSubtitleStreams = streams.filter {
            $0.codecType == "subtitle" && Self.isMP4TextSubtitleCodec($0.codecName)
        }

        await MainActor.run {
            self.videoCodec = videoCodec?.uppercased()
            self.audioCodec = audioCodec?.uppercased()
            if let w = videoStream?.width, let h = videoStream?.height {
                self.videoResolution = "\(w)x\(h)"
            } else {
                self.videoResolution = nil
            }
            self.sourceFrameRate = videoStream?.frameRate
            if let sourceDuration {
                self.knownPlaybackDuration = sourceDuration
                self.duration = sourceDuration
            }
        }

        statusMessage = startAt > 0
            ? "\(NSLocalizedString("Seeking...", comment: "")) \(formattedTime(startAt))"
            : "\(NSLocalizedString("Preparing video", comment: "")) \(sourceURL.pathExtension.uppercased())..."

        let candidateCacheURL = allowFastRemux ? Self.cachedCompatibleVideoURL(for: sourceURL) : nil
        let finalCachedOutputURL: URL?
        let outputURL: URL
        if let cacheURL = candidateCacheURL,
           Self.ensureCompatibleVideoCacheDirectoryExists(for: cacheURL) {
            finalCachedOutputURL = cacheURL
            outputURL = cacheURL.deletingLastPathComponent()
                .appendingPathComponent(".\(cacheURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).partial.mp4")
        } else {
            finalCachedOutputURL = nil
            outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("Rift-\(UUID().uuidString).mp4")
        }

        let isAudioCopyable = ["aac", "mp3", "ac3", "eac3", "flac", "alac"].contains(audioCodec)
        let copyOrAACAudioArgs = isAudioCopyable
            ? ["-c:a", "copy"]
            : ["-c:a", "aac", "-b:a", "192k"]
        let compatibleAudioArgs = ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]

        var ffmpegArgs = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-dn"
        ] + Self.subtitleMapArgs(for: textSubtitleStreams)

        if allowFastRemux && canFastRemuxVideo {
            ffmpegArgs += [
                "-map_metadata", "0",
                "-c:v", "copy",
            ] + mp4VideoTagArgs + copyOrAACAudioArgs + [
                "-c:s", "mov_text",
                "-y", outputURL.path
            ]
            convertedVideoURL = outputURL
            convertedVideoShouldCleanup = true
            let success = await runFFmpegAsync(ffmpegURL, arguments: ffmpegArgs, phase: NSLocalizedString("Preparing video", comment: ""))
            if success {
                let playableURL = finalizePreparedVideo(outputURL, cachedOutputURL: finalCachedOutputURL)
                self.playVideo(playableURL, displayName: sourceURL.lastPathComponent)
                if startAt > 0 {
                    self.seek(to: startAt)
                }
                return
            }
        }

        // Transcodificar video usando GPU acelerada
        statusMessage = NSLocalizedString("Converting video (hardware)...", comment: "")
        var hwArgs = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-dn",
            "-c:v", "h264_videotoolbox",
            "-b:v", "8M",
            "-pix_fmt", "yuv420p",
            "-map_metadata", "0"
        ] + Self.subtitleMapArgs(for: textSubtitleStreams)
        hwArgs += compatibleAudioArgs + ["-c:s", "mov_text", "-y", outputURL.path]

        convertedVideoURL = outputURL
        convertedVideoShouldCleanup = true
        let hwSuccess = await runFFmpegAsync(ffmpegURL, arguments: hwArgs, phase: NSLocalizedString("Converting video", comment: ""))
        if hwSuccess {
            let playableURL = finalizePreparedVideo(outputURL, cachedOutputURL: finalCachedOutputURL)
            self.playVideo(playableURL, displayName: sourceURL.lastPathComponent)
            if startAt > 0 {
                self.seek(to: startAt)
            }
            return
        }

        // Fallback: transcodificación por software
        statusMessage = NSLocalizedString("Converting video (compatible)...", comment: "")
        var swArgs = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-dn",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "20",
            "-pix_fmt", "yuv420p",
            "-map_metadata", "0"
        ] + Self.subtitleMapArgs(for: textSubtitleStreams)
        swArgs += compatibleAudioArgs + ["-c:s", "mov_text", "-y", outputURL.path]

        let swSuccess = await runFFmpegAsync(ffmpegURL, arguments: swArgs, phase: NSLocalizedString("Converting video", comment: ""))
        if swSuccess {
            let playableURL = finalizePreparedVideo(outputURL, cachedOutputURL: finalCachedOutputURL)
            self.playVideo(playableURL, displayName: sourceURL.lastPathComponent)
            if startAt > 0 {
                self.seek(to: startAt)
            }
        } else {
            self.statusMessage = NSLocalizedString("Could not open video", comment: "")
            self.hasVideo = false
            self.cleanupConvertedVideo()
        }
    }

    private func finalizePreparedVideo(_ outputURL: URL, cachedOutputURL: URL?) -> URL {
        guard let cachedOutputURL else {
            convertedVideoURL = outputURL
            convertedVideoShouldCleanup = true
            return outputURL
        }

        do {
            try? FileManager.default.removeItem(at: cachedOutputURL)
            try FileManager.default.moveItem(at: outputURL, to: cachedOutputURL)
            convertedVideoURL = cachedOutputURL
            convertedVideoShouldCleanup = false
            Self.enforceCacheSizeLimit()
            return cachedOutputURL
        } catch {
            convertedVideoURL = outputURL
            convertedVideoShouldCleanup = true
            return outputURL
        }
    }

    private func retryCompatibleConversionIfNeeded() -> Bool {
        guard !attemptedCompatibleFallback,
              let sourceURL = originalVideoURL,
              needsConversion(sourceURL),
              playbackSourceURL == convertedVideoURL else {
            return false
        }

        attemptedCompatibleFallback = true
        statusMessage = NSLocalizedString("Retrying compatible conversion...", comment: "")
        isPlaying = false
        cleanupConvertedVideo()
        Task { @MainActor in
            await self.convertAndLoadVideo(sourceURL, allowFastRemux: false)
        }
        return true
    }

    private func startFramePlusPreparationIfUseful() {
        guard !isFramePlusPreparing,
              !isFramePlusPreRendered,
              shouldPrepareFramePlusVideo,
              let sourceURL = originalVideoURL else {
            return
        }

        Task { @MainActor in
            await prepareFramePlusVideo(from: sourceURL)
        }
    }

    private func startFramePlusPreparationForShortLowFPSClipIfUseful() {
        guard CommandLine.arguments.contains("--frameplus-hq"),
              interpolationMode == .motion2Intense,
              !isFramePlusPreparing,
              !isFramePlusPreRendered,
              let sourceFrameRate,
              sourceFrameRate.isFinite,
              sourceFrameRate > 0,
              sourceFrameRate < 16 else {
            return
        }

        let itemDuration = player.currentItem?.duration.seconds ?? 0
        let knownDuration = duration > 0 ? duration : itemDuration
        guard knownDuration.isFinite, knownDuration > 0, knownDuration <= 90 else { return }

        startFramePlusPreparationIfUseful()
    }

    private var shouldPrepareFramePlusVideo: Bool {
        guard let sourceFrameRate, sourceFrameRate.isFinite, sourceFrameRate > 0 else { return true }
        return sourceFrameRate < 55
    }

    private func stopFramePlusPreparation() {
        if isFramePlusPreparing {
            conversionProcess?.terminate()
            conversionProcess = nil
        }
        isFramePlusPreparing = false
        isFramePlusPreRendered = false
    }

    private func restoreBaseVideoIfNeeded() {
        guard let playbackSourceURL, playbackSourceURL == framePlusVideoURL else { return }
        let resumeTime = currentTime
        let baseURL = convertedVideoURL ?? originalVideoURL
        guard let baseURL else { return }
        playVideo(baseURL, displayName: originalVideoURL?.lastPathComponent ?? baseURL.lastPathComponent)
        seek(to: resumeTime)
    }

    private func prepareFramePlusVideo(from sourceURL: URL) async {
        guard !isFramePlusPreparing else { return }
        guard let ffmpegURL = findFFmpeg() else {
            statusMessage = NSLocalizedString("Frame⁺ HQ needs ffmpeg; using live Frame⁺.", comment: "")
            isFramePlusPreparing = false
            isFramePlusPreRendered = false
            return
        }

        isFramePlusPreparing = true
        isFramePlusPreRendered = false
        statusMessage = NSLocalizedString("Frame⁺ preparing 60fps...", comment: "")

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rift-FramePlus-\(UUID().uuidString).mp4")
        cleanupFramePlusVideo()
        framePlusVideoURL = outputURL

        let args = [
            "-hide_banner",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-sn",
            "-dn",
            "-vf", "minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1",
            "-c:v", "hevc_videotoolbox",
            "-tag:v", "hvc1",
            "-b:v", "18M",
            "-pix_fmt", "yuv420p",
            "-c:a", "copy",
            "-y", outputURL.path
        ]

        let success = await runFFmpegAsync(ffmpegURL, arguments: args, phase: NSLocalizedString("Preparing video", comment: ""))
        isFramePlusPreparing = false

        if success {
            guard interpolationMode == .motion2Intense else {
                cleanupFramePlusVideo()
                return
            }

            isFramePlusPreRendered = true
            fpsMode = .native
            sourceFrameRate = 60
            currentRenderingFPS = 60
            isArtificialInterpolationActive = true
            let resumeTime = duration > 0 && currentTime >= duration - 0.5 ? 0 : currentTime
            playVideo(outputURL, displayName: "\(fileName) · Frame⁺ 60fps")
            seek(to: resumeTime)
        } else {
            cleanupFramePlusVideo()
            if interpolationMode == .motion2Intense {
                statusMessage = NSLocalizedString("Frame⁺ HQ could not prepare 60fps; using live Frame⁺.", comment: "")
                isFramePlusPreRendered = false
            }
        }
    }

    private func runFFmpegAsync(_ executableURL: URL, arguments: [String], phase: String) async -> Bool {
        let process = Process()
        process.executableURL = executableURL
        let progressArgs = arguments + ["-progress", "pipe:1"]
        process.arguments = ["-nostdin"] + progressArgs
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        conversionProcess = process
        
        if let outputPath = arguments.last {
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        let startTime = Date()
        
        let progressTask = Task { @MainActor in
            let handle = outputPipe.fileHandleForReading
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let output = String(data: data, encoding: .utf8) else { return }
                for line in output.components(separatedBy: "\n") {
                    if line.hasPrefix("out_time_us="),
                       let micros = Int64(line.dropFirst(12).trimmingCharacters(in: .whitespacesAndNewlines)),
                       micros > 0 {
                        Task { @MainActor in
                            let total = max(self.duration, 1)
                            let elapsed = Double(micros) / 1_000_000
                            self.conversionProgress = min(elapsed / total, 1.0)
                        }
                    }
                }
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard process.isRunning else { break }
                let elapsedSeconds = Int(Date().timeIntervalSince(startTime))
                self.statusMessage = "\(phase)... \(elapsedSeconds)s"
            }
            handle.readabilityHandler = nil
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { [weak self] process in
                let success = process.terminationStatus == 0
                _ = errorPipe.fileHandleForReading.readDataToEndOfFile()

                Task { @MainActor in
                    progressTask.cancel()
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }
                    self.conversionProcess = nil
                    if success {
                        self.conversionProgress = nil
                    }
                    continuation.resume(returning: success)
                }
            }

            do {
                try process.run()
            } catch {
                progressTask.cancel()
                Task { @MainActor in
                    self.conversionProcess = nil
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private nonisolated func runFFmpegHLS(
        _ executableURL: URL,
        arguments: [String],
        playlistURL: URL,
        sourcePlaylistURL: URL,
        playbackPlaylistURL: URL,
        hlsDirectory: URL,
        displayName: String,
        phase: String,
        playbackOffset: Double
    ) async -> Bool {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-nostdin"] + arguments
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            await MainActor.run { [weak self] in self?.conversionProcess = nil }
            return false
        }

        let startTime = Date()
        let pollInterval = UInt64(100_000_000)

        return await Task.detached {
            let fileManager = FileManager.default

            while process.isRunning {
                let elapsedSeconds = Int(Date().timeIntervalSince(startTime))

                await MainActor.run { [weak self] in
                    guard let self else { return }
                self.statusMessage = String(format: NSLocalizedString("%@... %d s", comment: ""), phase, elapsedSeconds)
                }

                let startupDuration: TimeInterval = playbackOffset > 0 ? 0.75 : 2.5
                if await Self.hlsPlaylistDuration(at: sourcePlaylistURL) >= startupDuration,
                   Self.writeMirroredHLSPlaylist(
                    from: sourcePlaylistURL,
                    to: playbackPlaylistURL,
                    maxSegments: nil,
                    revealDuration: max(12, startupDuration)
                ) {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.hlsSourcePlaylistURL = sourcePlaylistURL
                        self.hlsPlaybackPlaylistURL = playbackPlaylistURL
                        self.hlsMinimumRevealDuration = 0
                        self.hlsPlaybackOffset = max(0, playbackOffset)
                        self.statusMessage = nil
                        self.playVideo(playlistURL, displayName: displayName)
                        self.startHLSPlaylistMirror(
                            sourcePlaylistURL: sourcePlaylistURL,
                            playbackPlaylistURL: playbackPlaylistURL
                        )
                        self.observeProgressiveFFmpegCompletion(process, playbackURL: playlistURL)
                    }
                    return true
                }

                if elapsedSeconds >= 12 {
                    process.terminate()
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.conversionProcess = nil
                        self.hlsServer?.stop()
                        self.hlsServer = nil
                    }
                    try? fileManager.removeItem(at: hlsDirectory)
                    return false
                }

                try? await Task.sleep(nanoseconds: pollInterval)
            }

            let success = process.terminationStatus == 0
            await MainActor.run { [weak self] in self?.conversionProcess = nil }
            let mirroredPlaylist = Self.writeMirroredHLSPlaylist(
                from: sourcePlaylistURL,
                to: playbackPlaylistURL,
                maxSegments: nil,
                revealDuration: nil
            )
            guard success, mirroredPlaylist, await Self.hlsPlaylistLooksPlayable(playlistURL) else {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.hlsServer?.stop()
                    self.hlsServer = nil
                }
                try? fileManager.removeItem(at: hlsDirectory)
                return false
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.hlsSourcePlaylistURL = sourcePlaylistURL
                self.hlsPlaybackPlaylistURL = playbackPlaylistURL
                self.hlsMinimumRevealDuration = 0
                self.hlsPlaybackOffset = max(0, playbackOffset)
                self.playVideo(playlistURL, displayName: displayName)
            }
            return true
        }.value
    }

    private func observeProgressiveFFmpegCompletion(_ process: Process, playbackURL: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            process.waitUntilExit()
            let success = process.terminationStatus == 0

            Task { @MainActor in
                guard let self else { return }
                if self.conversionProcess === process {
                    self.conversionProcess = nil
                }
                if !success, self.playbackSourceURL == playbackURL {
                    self.statusMessage = NSLocalizedString("Preparation stopped; you can reopen the file to retry.", comment: "")
                }
            }
        }
    }

    private func startHLSPlaylistMirror(sourcePlaylistURL: URL, playbackPlaylistURL: URL) {
        hlsPlaylistUpdateTask?.cancel()
        hlsSourcePlaylistURL = sourcePlaylistURL
        hlsPlaybackPlaylistURL = playbackPlaylistURL
        hlsMinimumRevealDuration = 0

        let source = sourcePlaylistURL
        let playback = playbackPlaylistURL

        hlsPlaylistUpdateTask = Task {
            let startedAt = Date()

            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startedAt)
                let automaticRevealDuration = max(12, elapsed + 45)

                let revealDuration: TimeInterval = await MainActor.run { [weak self] in
                    guard let self else { return automaticRevealDuration }
                    return max(automaticRevealDuration, self.hlsMinimumRevealDuration)
                }

                let isComplete = Self.writeMirroredHLSPlaylist(
                    from: source,
                    to: playback,
                    maxSegments: nil,
                    revealDuration: revealDuration
                )

                if isComplete,
                   let playlist = try? String(contentsOf: source, encoding: .utf8),
                   playlist.contains("#EXT-X-ENDLIST") {
                    let wrote = Self.writeMirroredHLSPlaylist(
                        from: source,
                        to: playback,
                        maxSegments: nil,
                        revealDuration: nil
                    )
                    if !wrote {
                        logger.error("HLS playlist completed but mirrored write failed; playback may be stale")
                        statusMessage = NSLocalizedString("HLS playlist write failed — playback may be out of date", comment: "")
                    }
                    break
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func seekHLS(to absoluteSeconds: Double) {
        let shouldResume = shouldResumeAfterHLSSeek()
        let relativeSeconds = absoluteSeconds - hlsPlaybackOffset
        let generatedDuration = generatedHLSDuration()
        if relativeSeconds >= 0, generatedDuration > 0, relativeSeconds <= max(0, generatedDuration - 0.25) {
            hlsSeekTask?.cancel()
            hlsShouldResumePlayback = shouldResume
            revealHLSPlaylist(upTo: relativeSeconds + 15)
            currentTime = absoluteSeconds

            let seekTime = CMTime(seconds: relativeSeconds, preferredTimescale: 600)
            let tolerance = CMTime(seconds: 0.35, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
                Task { @MainActor in
                    guard let self else { return }
                    guard finished else {
                        self.restartHLSPlayback(at: absoluteSeconds, shouldResume: shouldResume)
                        return
                    }

                    let landedTime = self.hlsPlaybackOffset + self.player.currentTime().seconds
                    if landedTime.isFinite, abs(landedTime - absoluteSeconds) <= 1.0 {
                        self.currentTime = absoluteSeconds
                        if shouldResume {
                            self.player.playImmediately(atRate: self.playbackRate)
                            self.isPlaying = true
                            self.hlsShouldResumePlayback = false
                        }
                    } else {
                        self.restartHLSPlayback(at: absoluteSeconds, shouldResume: shouldResume)
                    }
                }
            }
            return
        }

        // AVPlayer treats parts that are not in the generated local HLS playlist like an
        // unreachable live range. Restart there, but only for those far jumps.
        restartHLSPlayback(at: absoluteSeconds, shouldResume: shouldResume)
    }

    private func restartHLSPlayback(at absoluteSeconds: Double, shouldResume: Bool? = nil) {
        guard let sourceURL = originalVideoURL else { return }
        let targetSeconds = duration > 0
            ? max(0, min(absoluteSeconds, max(0, duration - 0.5)))
            : max(0, absoluteSeconds)

        hlsSeekTask?.cancel()
        hlsSeekTask = Task { @MainActor in
            let shouldResumePlayback = shouldResume ?? shouldResumeAfterHLSSeek()
            hlsShouldResumePlayback = shouldResumePlayback
            statusMessage = String(format: NSLocalizedString("Seeking to %@...", comment: ""), formattedTime(targetSeconds))
            currentTime = targetSeconds
            hlsPlaybackOffset = targetSeconds
            isPlaying = shouldResumePlayback
            player.pause()
            detachLegibleOutput()
            player.replaceCurrentItem(with: nil)
            playbackSourceURL = nil
            conversionProcess?.terminate()
            conversionProcess = nil
            cleanupConvertedVideo(keepingFramePlus: true)

            await convertAndLoadVideo(sourceURL, allowFastRemux: true, startAt: targetSeconds)
        }
    }

    private func shouldResumeAfterHLSSeek() -> Bool {
        isPlaying
            || player.rate > 0
            || player.timeControlStatus == .playing
            || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            || hlsShouldResumePlayback
    }

    private func visibleHLSDuration() -> TimeInterval {
        guard let hlsPlaybackPlaylistURL,
              let playlist = try? String(contentsOf: hlsPlaybackPlaylistURL, encoding: .utf8) else {
            return 0
        }

        return Self.parseHLSPlaylist(playlist).segments.reduce(0) { $0 + $1.duration }
    }

    private func generatedHLSDuration() -> TimeInterval {
        guard let hlsSourcePlaylistURL,
              let playlist = try? String(contentsOf: hlsSourcePlaylistURL, encoding: .utf8) else {
            return visibleHLSDuration()
        }

        return max(visibleHLSDuration(), Self.parseHLSPlaylist(playlist).segments.reduce(0) { $0 + $1.duration })
    }

    private func revealHLSPlaylist(upTo seconds: TimeInterval) {
        guard let hlsSourcePlaylistURL,
              let hlsPlaybackPlaylistURL,
              seconds.isFinite,
              seconds > 0 else {
            return
        }

        hlsMinimumRevealDuration = max(hlsMinimumRevealDuration, seconds)
        let wrote = Self.writeMirroredHLSPlaylist(
            from: hlsSourcePlaylistURL,
            to: hlsPlaybackPlaylistURL,
            maxSegments: nil,
            revealDuration: hlsMinimumRevealDuration
        )
        if !wrote {
            logger.error("HLS reveal update failed to write mirrored playlist")
            statusMessage = NSLocalizedString("HLS playlist update failed", comment: "")
        }
    }

    nonisolated private static func fileSize(at url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    nonisolated private static func hlsDirectoryHasSegments(_ directoryURL: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }

        return contents.contains { $0.pathExtension == "m4s" || $0.pathExtension == "ts" }
    }

    nonisolated private static func hlsPlaylistHasReadySegment(_ playlistURL: URL, in directoryURL: URL) -> Bool {
        guard let playlist = try? String(contentsOf: playlistURL, encoding: .utf8) else {
            return false
        }

        let segmentLines = playlist
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                !line.hasPrefix("#") && (line.hasSuffix(".ts") || line.hasSuffix(".m4s"))
            }

        guard !segmentLines.isEmpty else { return false }

        return segmentLines.contains { segmentLine in
            let segmentURL = directoryURL.appendingPathComponent(segmentLine)
            return fileSize(at: segmentURL) > 0
        }
    }

    nonisolated private static func hlsPlaylistDuration(at url: URL) -> TimeInterval {
        guard let playlist = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }

        return parseHLSPlaylist(playlist).segments.reduce(0) { $0 + $1.duration }
    }

    nonisolated private static func writeMirroredHLSPlaylist(
        from sourceURL: URL,
        to destinationURL: URL,
        maxSegments: Int?,
        revealDuration: TimeInterval?
    ) -> Bool {
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return false
        }

        let parsed = parseHLSPlaylist(source)
        guard !parsed.segments.isEmpty else { return false }

        let selectedCount: Int
        if let maxSegments {
            selectedCount = min(maxSegments, parsed.segments.count)
        } else if let revealDuration {
            var accumulated: TimeInterval = 0
            var count = 0
            for segment in parsed.segments {
                accumulated += segment.duration
                count += 1
                if accumulated >= revealDuration {
                    break
                }
            }
            selectedCount = max(1, min(count, parsed.segments.count))
        } else {
            selectedCount = parsed.segments.count
        }

        guard selectedCount > 0 else { return false }

        let selectedSegments = Array(parsed.segments.prefix(selectedCount))
        let targetDuration = max(1, Int(ceil(selectedSegments.map(\.duration).max() ?? 1)))
        var output = parsed.headerLines.filter { !$0.hasPrefix("#EXT-X-TARGETDURATION:") }
        let targetDurationLine = "#EXT-X-TARGETDURATION:\(targetDuration)"
        if let versionIndex = output.firstIndex(where: { $0.hasPrefix("#EXT-X-VERSION:") }) {
            output.insert(targetDurationLine, at: output.index(after: versionIndex))
        } else {
            output.append(targetDurationLine)
        }

        for segment in selectedSegments {
            output.append(contentsOf: segment.lines)
        }

        if parsed.hasEndList && selectedCount == parsed.segments.count {
            output.append("#EXT-X-ENDLIST")
        }

        do {
            try output.joined(separator: "\n")
                .appending("\n")
                .write(to: destinationURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            logger.error("Failed to write mirrored HLS playlist to \(destinationURL.path): \(error.localizedDescription)")
            return false
        }
    }

    private struct HLSPlaylistSegment {
        let duration: TimeInterval
        let lines: [String]
    }

    nonisolated private static func parseHLSPlaylist(_ source: String) -> (headerLines: [String], segments: [HLSPlaylistSegment], hasEndList: Bool) {
        let lines = source.split(whereSeparator: \.isNewline).map(String.init)
        var headerLines: [String] = []
        var segments: [HLSPlaylistSegment] = []
        var hasEndList = false
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if line == "#EXT-X-ENDLIST" {
                hasEndList = true
                index += 1
                continue
            }

            if line.hasPrefix("#EXTINF:") {
                let uriIndex = index + 1
                guard uriIndex < lines.count else { break }
                let uriLine = lines[uriIndex]
                let durationText = line
                    .dropFirst("#EXTINF:".count)
                    .split(separator: ",", maxSplits: 1)
                    .first
                    .map(String.init) ?? "0"
                let duration = TimeInterval(durationText) ?? 0

                if !uriLine.hasPrefix("#") {
                    segments.append(HLSPlaylistSegment(duration: duration, lines: [line, uriLine]))
                }

                index += 2
                continue
            }

            if segments.isEmpty, !line.isEmpty {
                headerLines.append(line)
            }

            index += 1
        }

        return (headerLines, segments, hasEndList)
    }

    private static func hlsPlaylistLooksPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            return try await asset.load(.isPlayable)
        } catch {
            return false
        }
    }

    private func configureLegibleOutput(for item: AVPlayerItem) {
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        output.setDelegate(self, queue: DispatchQueue.main)
        item.add(output)
        legibleOutput = output
    }

    private func detachLegibleOutput() {
        if let legibleOutput {
            legibleOutput.setDelegate(nil, queue: nil)
            player.currentItem?.remove(legibleOutput)
        }
        legibleOutput = nil
        audioSelectionGroup = nil
        audioOptionsByIndex.removeAll()
        subtitleSelectionGroup = nil
        subtitleOptionsByID.removeAll()
        currentSubtitleText = nil
    }

    private func loadMediaTracks(from item: AVPlayerItem) {
        loadAudioTracks(from: item)
        loadSubtitleTracks(from: item)
    }

    private func loadAudioTracks(from item: AVPlayerItem) {
        Task {
            // AVAssetTrack is the reliable API for local files (including FFmpeg-converted MP4s).
            // AVMediaSelectionGroup only works for HLS and some native containers.
            guard let allTracks = try? await item.asset.loadTracks(withMediaType: .audio),
                  !allTracks.isEmpty else {
                await MainActor.run {
                    self.audioTracks = []
                    self.audioSelectionGroup = nil
                    self.audioOptionsByIndex.removeAll()
                }
                return
            }

            let audibleGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
            let audibleOptions = audibleGroup?.options ?? []

            // Build label list using language metadata from each track.
            var result: [AudioTrack] = []
            if !audibleOptions.isEmpty {
                for (index, option) in audibleOptions.enumerated() {
                    let language = option.extendedLanguageTag ?? option.locale?.identifier
                    let label = Self.localizedMediaSelectionLabel(
                        fallbackPrefix: NSLocalizedString("Audio", comment: ""),
                        index: index,
                        displayName: option.displayName,
                        language: language
                    )
                    result.append(AudioTrack(id: index, label: label, language: language))
                }
            } else {
                for (index, track) in allTracks.enumerated() {
                    let rawLang  = (try? await track.load(.languageCode)) ?? ""
                    let extTag   = (try? await track.load(.extendedLanguageTag)) ?? ""
                    let effective = (rawLang.isEmpty || rawLang == "und") ? extTag : rawLang

                    let label: String
                    if !effective.isEmpty {
                        label = Locale.current.localizedString(forLanguageCode: effective)
                            ?? effective.uppercased()
                    } else {
                        label = String(format: NSLocalizedString("Track %d", comment: ""), index + 1)
                    }
                    result.append(AudioTrack(
                        id: index,
                        label: label,
                        language: effective.isEmpty ? nil : effective
                    ))
                }
            }

            await MainActor.run {
                // Only show picker when there are genuinely multiple tracks.
                if result.count > 1 {
                    self.audioTracks = result
                } else {
                    self.audioTracks = []
                }
                self.audioSelectionGroup = audibleGroup
                self.audioOptionsByIndex = Dictionary(uniqueKeysWithValues: audibleOptions.enumerated().map { ($0.offset, $0.element) })
                self.availableTracks.removeAll { $0.kind == .audio }
                self.availableTracks.append(contentsOf: result.map {
                    MediaTrack(
                        id: "audio-\($0.id)",
                        kind: .audio,
                        index: $0.id,
                        label: $0.label,
                        languageCode: $0.language
                    )
                })
                self.selectedAudioTrack = self.availableTracks.first { $0.kind == .audio }
                self.selectedAudioTrackIndex = 0
                if let audibleGroup, let firstOption = audibleOptions.first {
                    item.select(firstOption, in: audibleGroup)
                    item.audioMix = nil
                } else {
                    // Immediately mute all tracks except the first — fixes double-audio bug.
                    self.applyAudioMix(trackIndex: 0, to: item, allTracks: allTracks)
                }
            }
        }
    }

    private func loadSubtitleTracks(from item: AVPlayerItem) {
        Task {
            let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            var tracks: [MediaTrack] = []
            var optionsByID: [String: AVMediaSelectionOption] = [:]

            if let group {
                for (index, option) in group.options.enumerated() {
                    let id = "subtitle-\(index)"
                    let language = option.extendedLanguageTag ?? option.locale?.identifier
                    let label = Self.localizedMediaSelectionLabel(
                        fallbackPrefix: NSLocalizedString("Subtitle", comment: ""),
                        index: index,
                        displayName: option.displayName,
                        language: language
                    )

                    tracks.append(MediaTrack(
                        id: id,
                        kind: .subtitle,
                        index: index,
                        label: label,
                        languageCode: language
                    ))
                    optionsByID[id] = option
                }
            }

            await MainActor.run {
                self.subtitleSelectionGroup = group
                self.subtitleOptionsByID = optionsByID
                self.availableTracks.removeAll { $0.kind == .subtitle }
                self.availableTracks.append(contentsOf: tracks)
                self.selectedSubtitleTrack = nil
                self.currentSubtitleText = nil

                if let group {
                    item.select(nil, in: group)
                }
            }
        }
    }

    private func loadFrameRateFallback(from asset: AVAsset) {
        guard sourceFrameRate == nil || sourceFrameRate == 0 else { return }

        Task {
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            guard let track = tracks.first,
                  let nominalFrameRate = try? await track.load(.nominalFrameRate),
                  nominalFrameRate.isFinite,
                  nominalFrameRate > 1 else {
                return
            }

            await MainActor.run {
                if self.sourceFrameRate == nil || self.sourceFrameRate == 0 {
                    self.sourceFrameRate = Double(nominalFrameRate)
                }
            }
        }
    }

    private func applySubtitleSelection(_ track: MediaTrack?) {
        guard let item = player.currentItem, let group = subtitleSelectionGroup else {
            currentSubtitleText = nil
            return
        }

        guard let track, let option = subtitleOptionsByID[track.id] else {
            item.select(nil, in: group)
            currentSubtitleText = nil
            return
        }

        item.select(option, in: group)
        currentSubtitleText = nil
    }

    private func applyVisualCompositionIfNeeded() {
        guard let item = player.currentItem else { return }
        applyVisualCompositionIfNeeded(to: item)
    }

    private func applyVisualCompositionIfNeeded(to item: AVPlayerItem) {
        item.videoComposition = nil
    }

    private nonisolated static func visualEnhancementComposition(for asset: AVAsset) -> AVVideoComposition {
        AVMutableVideoComposition(asset: asset) { request in
            let image = applyVisualEnhancements(to: request.sourceImage)
            request.finish(with: image, context: nil)
        }
    }

    nonisolated static func applyVisualEnhancements(to image: CIImage) -> CIImage {
        let extent = image.extent
        let color = image
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 0.90,
                "inputShadowAmount": 0.48
            ])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.08,
                kCIInputContrastKey: 1.02,
                kCIInputBrightnessKey: 0.0
            ])
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.20
            ])

        return color.cropped(to: extent)
    }

    /// Applies an AVAudioMix that silences every track except `trackIndex`.
    /// This is instant and requires no re-conversion.
    private func applyAudioMix(trackIndex: Int, to item: AVPlayerItem, allTracks: [AVAssetTrack]) {
        let params: [AVAudioMixInputParameters] = allTracks.enumerated().map { index, track in
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(index == trackIndex ? 1.0 : 0.0, at: .zero)
            return p
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        item.audioMix = mix
    }

    private func findFFmpeg() -> URL? {
        if let path = try? Self.shell("which ffmpeg"), !path.isEmpty {
            let url = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return findExecutable(named: "ffmpeg", fallbackPaths: [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
            "\(NSHomeDirectory())/.local/bin/ffmpeg",
            "\(NSHomeDirectory())/.nix-profile/bin/ffmpeg",
        ])
    }

    private static func shell(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parseFrameRate(_ rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: "/")

        if pieces.count == 2,
           let numerator = Double(pieces[0]),
           let denominator = Double(pieces[1]),
           denominator != 0 {
            return numerator / denominator
        }

        return Double(trimmed)
    }

    private static func isMP4TextSubtitleCodec(_ codecName: String) -> Bool {
        [
            "ass",
            "mov_text",
            "ssa",
            "srt",
            "subrip",
            "text",
            "webvtt"
        ].contains(codecName.lowercased())
    }

    private static func subtitleMapArgs(for streams: [StreamInfo]) -> [String] {
        streams.flatMap { ["-map", "0:\($0.index)"] }
    }

    private func findFFprobe() -> URL? {
        findExecutable(named: "ffprobe", fallbackPaths: [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ])
    }

    private func findExecutable(named name: String, fallbackPaths: [String]) -> URL? {
        let bundledCandidates = bundledExecutableCandidates(named: name)
        let fallbackCandidates = fallbackPaths.map(URL.init(fileURLWithPath:))
        var seenPaths = Set<String>()

        return (bundledCandidates + fallbackCandidates).first { url in
            guard seenPaths.insert(url.path).inserted else { return false }
            return FileManager.default.isExecutableFile(atPath: url.path)
        }
    }

    private func bundledExecutableCandidates(named name: String) -> [URL] {
        var roots: [URL] = []

        for bundle in executableSearchBundles() {
            if let resourceURL = bundle.resourceURL {
                roots.append(resourceURL)
                roots.append(resourceURL.appendingPathComponent("bin", isDirectory: true))
                roots.append(resourceURL.appendingPathComponent("Tools", isDirectory: true))
                roots.append(resourceURL.appendingPathComponent("FFmpeg", isDirectory: true))
            }

            if let executableURL = bundle.executableURL?.deletingLastPathComponent() {
                roots.append(executableURL)
                roots.append(executableURL.appendingPathComponent("bin", isDirectory: true))
                roots.append(executableURL.appendingPathComponent("Tools", isDirectory: true))
                roots.append(executableURL.appendingPathComponent("Helpers", isDirectory: true))
            }
        }

        let contentsURL = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        roots.append(contentsURL.appendingPathComponent("MacOS", isDirectory: true))
        roots.append(contentsURL.appendingPathComponent("Helpers", isDirectory: true))
        roots.append(contentsURL.appendingPathComponent("Resources", isDirectory: true))
        roots.append(contentsURL.appendingPathComponent("Resources/bin", isDirectory: true))
        roots.append(contentsURL.appendingPathComponent("Resources/Tools", isDirectory: true))
        roots.append(contentsURL.appendingPathComponent("Resources/FFmpeg", isDirectory: true))

        return roots.map { $0.appendingPathComponent(name, isDirectory: false) }
    }

    private func executableSearchBundles() -> [Bundle] {
        [Bundle.main]
    }

    nonisolated func legibleOutput(
        _ output: AVPlayerItemLegibleOutput,
        didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers: [Any],
        forItemTime itemTime: CMTime
    ) {
        let text = strings
            .map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        Task { @MainActor [weak self] in
            self?.currentSubtitleText = text.isEmpty ? nil : text
        }
    }

    private static func localizedMediaSelectionLabel(
        fallbackPrefix: String,
        index: Int,
        displayName: String,
        language: String?
    ) -> String {
        let fallback = localizedTrackLabel(prefix: fallbackPrefix, index: index, language: language)
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedDisplayName.isEmpty else {
            return fallback
        }

        return trimmedDisplayName
    }

    private static func localizedTrackLabel(prefix: String, index: Int, language: String?) -> String {
        guard let language, !language.isEmpty, language != "und" else {
            return String(format: NSLocalizedString("%@ %d", comment: ""), prefix, index + 1)
        }

        let localized = Locale.current.localizedString(forLanguageCode: language) ?? language.uppercased()
        return String(format: NSLocalizedString("%@ %d · %@", comment: ""), prefix, index + 1, localized)
    }

    private func cleanupConvertedVideo(keepingFramePlus: Bool = false) {
        hlsPlaylistUpdateTask?.cancel()
        hlsPlaylistUpdateTask = nil
        hlsSourcePlaylistURL = nil
        hlsPlaybackPlaylistURL = nil
        hlsMinimumRevealDuration = 0
        hlsServer?.stop()
        hlsServer = nil

        if let convertedVideoDirectoryURL {
            try? FileManager.default.removeItem(at: convertedVideoDirectoryURL)
        } else if let convertedVideoURL, convertedVideoURL.isFileURL, convertedVideoShouldCleanup {
            try? FileManager.default.removeItem(at: convertedVideoURL)
        }

        convertedVideoDirectoryURL = nil
        self.convertedVideoURL = nil
        convertedVideoShouldCleanup = true
        if !keepingFramePlus {
            cleanupFramePlusVideo()
        }
    }

    private func cleanupFramePlusVideo() {
        if let framePlusVideoURL {
            try? FileManager.default.removeItem(at: framePlusVideoURL)
        }
        framePlusVideoURL = nil
    }

    private func addTimeObserver() {
        // Keeps sliders, labels, and play state synchronized with AVPlayer playback.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }

                let rawSeconds = time.seconds.isFinite ? time.seconds : 0
                let displaySeconds = self.playbackSourceURL?.scheme?.lowercased().hasPrefix("http") == true
                    ? self.hlsPlaybackOffset + rawSeconds
                    : rawSeconds
                self.currentTime = self.duration > 0
                    ? min(max(0, displaySeconds), self.duration)
                    : max(0, displaySeconds)

                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite,
                   itemDuration > 0,
                   self.playbackSourceURL?.scheme?.lowercased().hasPrefix("http") != true {
                    self.duration = itemDuration
                }

                let isWaitingToResume = self.playbackSourceURL?.scheme?.lowercased().hasPrefix("http") == true
                    && self.hlsShouldResumePlayback
                    && self.player.currentItem != nil
                self.isPlaying = self.player.timeControlStatus == .playing
                    || self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    || isWaitingToResume
            }
        }
    }

}

enum FPSMode: String, CaseIterable {
    case native = "Native FPS"
    case flux = "Flux"

    var next: FPSMode {
        switch self {
        case .native: .flux
        case .flux: .native
        }
    }

    var isActive: Bool {
        self == .flux
    }

    func renderFramesPerSecond(sourceFrameRate: Double?) -> Int {
        switch self {
        case .native:
            guard let sourceFrameRate, sourceFrameRate.isFinite, sourceFrameRate > 0 else { return 60 }
            return max(1, min(240, Int(sourceFrameRate.rounded())))
        case .flux:
            return 60
        }
    }
}
