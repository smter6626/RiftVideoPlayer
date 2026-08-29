import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - App icon from SVG

private struct RiftLogo: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "rift-logo", withExtension: "svg")
            ?? Bundle.main.url(forResource: "rift-logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 160, height: 160)
        }
    }
}

// MARK: - Ambient particle for cinematic atmosphere

private struct AmbientParticle: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var speed: CGFloat
    var opacity: Double
    var delay: Double
}

struct ContentView: View {
    @StateObject private var state = PlayerState()
    @State private var isDropTargeted = false

    @State private var keyboardEventMonitor: Any? = nil
    @State private var mouseMonitor: Any? = nil
    @State private var windowSize: CGSize = .zero
    @State private var interactiveReady = false

    @State private var particles: [AmbientParticle] = []
    @State private var promptPulse: CGFloat = 0

    @State private var controlsPosition: CGPoint = .zero
    @State private var controlsDrag: CGSize = .zero
    @State private var controlsSize: CGSize = .zero
    @State private var isPositionInitialized = false
    @State private var isDraggingControls = false

    var body: some View {
        ZStack {
            appBackdrop

            if !state.hasVideo {
                ambientParticles
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if state.hasVideo {
                Group {
                    if state.playbackBackend == .directFFmpeg, let directPlaybackURL = state.directPlaybackURL {
                        DirectFFmpegPlayerView(url: directPlaybackURL, state: state)
                    } else if usesMetalRenderer {
                        RiftPlayerView(
                            player: state.player,
                            fpsMode: state.fpsMode,
                            interpolationMode: state.interpolationMode,
                            sourceFrameRate: state.sourceFrameRate,
                            visualEnhancementsEnabled: state.visualEnhancementsEnabled,
                            isHDRContent: state.isHDRContent
                        ) { stats in
                            state.currentRenderingFPS = stats.renderingFPS
                            state.isArtificialInterpolationActive = stats.isArtificialInterpolationActive
                            state.fluxWorkingWidth = stats.fluxWorkingWidth
                            state.fluxOpticalFlowUsage = stats.opticalFlowUsage
                            state.fluxBlendFallbackUsage = stats.blendFallbackUsage
                            state.rifeStatus = stats.rifeStatus
                            state.isRIFELoaded = stats.isRIFELoaded
                            state.rifeEnabled = stats.isRIFELoaded && state.interpolationMode != .disabled && state.interpolationMode != .motion2Intense
                            if !stats.isRIFELoaded && state.interpolationMode != .disabled && state.interpolationMode != .motion2Intense {
                                state.interpolationMode = .disabled
                                state.fpsMode = .native
                            }
                        }
                    } else {
                        NativeVideoPlayerView(player: state.player)
                    }
                }
                .ignoresSafeArea()
                .overlay(videoVignette)
                .transition(.opacity.combined(with: .scale(scale: 1.01)))
            }

            if state.hasVideo, let subtitleText = state.currentSubtitleText, !subtitleText.isEmpty {
                subtitleOverlay(subtitleText)
                    .transition(.opacity)
            }

            if !state.hasVideo, interactiveReady {
                openVideoPrompt
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }

            if !state.hasVideo {
                filmGrainOverlay
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if interactiveReady {
            GeometryReader { geometry in
                ZStack {
                    PlayerControlsView(state: state)
                }
                .opacity(state.areControlsVisible ? 1.0 : 0.0)
                .scaleEffect(state.areControlsVisible ? 1 : 0.96)
                .background {
                    GeometryReader { proxy in
                        Color.clear.onAppear { controlsSize = proxy.size }
                    }
                }
                .position(
                    x: controlsPosition.x + controlsDrag.width,
                    y: controlsPosition.y + controlsDrag.height
                )
                .scaleEffect(isDraggingControls ? 0.98 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isDraggingControls)
                .onAppear {
                    guard !isPositionInitialized else { return }
                    controlsPosition = CGPoint(x: geometry.size.width / 2, y: geometry.size.height - 82)
                    windowSize = geometry.size
                    isPositionInitialized = true
                }
                .onChange(of: geometry.size) { _, newSize in
                    guard windowSize.width > 0, windowSize.height > 0 else { return }
                    let ratioX = controlsPosition.x / windowSize.width
                    let ratioY = controlsPosition.y / windowSize.height
                    controlsPosition = CGPoint(x: ratioX * newSize.width, y: ratioY * newSize.height)
                    windowSize = newSize
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            controlsDrag = value.translation
                            isDraggingControls = true
                        }
                        .onEnded { value in
                            let margin: CGFloat = 8
                            let halfW = controlsSize.width / 2
                            let halfH = controlsSize.height / 2
                            let w = geometry.size.width
                            let h = geometry.size.height
                            var newX = controlsPosition.x + value.translation.width
                            var newY = controlsPosition.y + value.translation.height
                            newX = max(halfW + margin, min(w - halfW - margin, newX))
                            newY = max(halfH + margin, min(h - halfH - margin, newY))
                            controlsPosition = CGPoint(x: newX, y: newY)
                            controlsDrag = .zero
                            isDraggingControls = false
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            let w = geometry.size.width
                            let h = geometry.size.height
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                controlsPosition = CGPoint(x: w / 2, y: h - 82)
                                controlsDrag = .zero
                            }
                        }
                )
            }
            }
        }
        .background(appBackdrop)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: state.hasVideo)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isDropTargeted)
        .onAppear {
            state.startHideTimer()
            setupKeyboardMonitor()
            handleOpenURLs(AppDelegate.takePendingOpenURLs())
            generateParticles()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                interactiveReady = true
            }
            if !state.hasVideo {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    promptPulse = 1.0
                }
            }
        }
        .onDisappear {
            state.stopHideTimer()
            NSCursor.unhide()
            cleanupKeyboardMonitor()
            state.cleanup()
        }
        .onChange(of: state.isPlaying) {
            state.resetHideTimer()
        }
        .onChange(of: state.hasVideo) { hasVideo in
            if hasVideo {
                withAnimation(.interactiveSpring) {
                    promptPulse = 0
                }
                state.resetHideTimer()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .riftOpenURLs)) { notification in
            let urls = notification.userInfo?["urls"] as? [URL] ?? []
            handleOpenURLs(urls)
        }
        .onReceive(NotificationCenter.default.publisher(for: .riftOpenVideo)) { _ in
            state.openVideo()
        }
        .focusedValue(\.playerState, state)
    }

    private var usesMetalRenderer: Bool {
        guard !state.usesNativeVideoLayer else { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }

    private func setupKeyboardMonitor() {
        cleanupKeyboardMonitor()
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [state] event in
                state.resetHideTimer()
                return event
            }
        }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [state] event in
            guard state.hasVideo else { return event }

            switch event.keyCode {
            case 123: // Left arrow
                state.seek(by: event.modifierFlags.contains(.shift) ? -60 : -10)
                return nil
            case 124: // Right arrow
                state.seek(by: event.modifierFlags.contains(.shift) ? 60 : 10)
                return nil
            case 125: // Down arrow
                state.setVolume(state.volume - 0.05)
                return nil
            case 126: // Up arrow
                state.setVolume(state.volume + 0.05)
                return nil
            case 53: // Escape
                state.closeVideo()
                NSCursor.unhide()
                return nil
            case 3: // F
                if !event.modifierFlags.contains(.command) { return event }
                if let window = NSApp.keyWindow {
                    window.toggleFullScreen(nil)
                }
                return nil
            case 46: // M
                if !event.modifierFlags.contains(.command) { return event }
                state.setVolume(state.volume > 0 ? 0 : 0.72)
                return nil
            case 4: // H - toggle controls
                withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
                    state.areControlsVisible.toggle()
                }
                return nil
            case 18...21: // Number keys 1-4
                let speeds: [Float] = [1.0, 1.5, 2.0, 0.5]
                let idx = Int(event.keyCode - 18)
                guard idx < speeds.count else { return event }
                let rate = speeds[idx]
                state.playbackRate = rate
                if state.isPlaying {
                    state.player.rate = rate
                }
                return nil
            default:
                return event
            }
        }
        keyboardEventMonitor = monitor
    }

    private func cleanupKeyboardMonitor() {
        if let monitor = keyboardEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardEventMonitor = nil
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func generateParticles() {
        var newParticles: [AmbientParticle] = []
        for _ in 0..<96 {
            newParticles.append(AmbientParticle(
                x: CGFloat.random(in: 0...1),
                y: CGFloat.random(in: 0...1),
                size: CGFloat.random(in: 1.5...5.0),
                speed: CGFloat.random(in: 0.08...0.35),
                opacity: Double.random(in: 0.12...0.55),
                delay: Double.random(in: 0...20)
            ))
        }
        particles = newParticles
    }

    private var ambientParticles: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for p in particles {
                    let drift = sin(time * 0.25 + p.delay * 1.7) * 28
                    let rise = fmod(time * p.speed + p.delay * 25, size.height * 1.4)
                    let xPos = (p.x * size.width * 0.9 + size.width * 0.05) + drift
                    let yPos = size.height - rise + size.height * 0.2
                    let breathe = 0.5 + 0.5 * sin(time * 0.4 + p.delay * 2.3)
                    let particleOpacity = p.opacity * breathe

                    var dotContext = context
                    dotContext.opacity = particleOpacity
                    dotContext.fill(
                        Path(ellipseIn: CGRect(x: xPos, y: yPos, width: p.size, height: p.size)),
                        with: .color(Color(red: 0.55, green: 0.78, blue: 1.0))
                    )
                }
            }
        }
        .drawingGroup()
    }

    private var appBackdrop: some View {
        ZStack {
            Color(red: 0.010, green: 0.035, blue: 0.095)
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color(red: 0.22, green: 0.42, blue: 0.88).opacity(0.12),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 60,
                endRadius: 680
            )

            RadialGradient(
                colors: [
                    Color(red: 0.03, green: 0.14, blue: 0.42).opacity(0.18),
                    .clear
                ],
                center: .center,
                startRadius: 100,
                endRadius: 720
            )
        }
        .ignoresSafeArea()
    }

    private var filmGrainOverlay: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 6)) { timeline in
            let seed = Int(timeline.date.timeIntervalSinceReferenceDate * 6)
            Canvas { context, size in
                for row in 0..<Int(size.height / 4) {
                    for col in 0..<Int(size.width / 3) {
                        let hash = seed ^ (row * 137) ^ (col * 251)
                        let gray = Double((hash & 0xFF)) / 512.0
                        let rect = CGRect(
                            x: CGFloat(col) * 3,
                            y: CGFloat(row) * 4,
                            width: 2.5,
                            height: 3.5
                        )
                        context.fill(
                            Path(rect),
                            with: .color(.white.opacity(gray * 0.06))
                        )
                    }
                }
            }
            .blendMode(.overlay)
        }
    }

    private var openVideoPrompt: some View {
        Button {
            state.openVideo()
        } label: {
            VStack(spacing: 40) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 0.25, green: 0.50, blue: 1.0).opacity(0.20 + promptPulse * 0.15),
                                    Color(red: 0.10, green: 0.22, blue: 0.70).opacity(0.06 + promptPulse * 0.06),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 10 + promptPulse * 20,
                                endRadius: 110 + promptPulse * 30
                            )
                        )
                        .frame(width: 220 + promptPulse * 30, height: 220 + promptPulse * 30)
                        .blur(radius: 6)
                        .scaleEffect(isDropTargeted ? 1.35 : 1)

                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.50, green: 0.75, blue: 1.0).opacity(0.30 + promptPulse * 0.20),
                                    Color(red: 0.20, green: 0.44, blue: 0.90).opacity(0.06 + promptPulse * 0.06),
                                    Color(red: 0.50, green: 0.75, blue: 1.0).opacity(0.15 + promptPulse * 0.15)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2 + promptPulse * 1.0
                        )
                        .frame(width: 180 + promptPulse * 16, height: 180 + promptPulse * 16)

                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.40, green: 0.65, blue: 1.0).opacity(0.08 + promptPulse * 0.10),
                                    .clear,
                                    Color(red: 0.40, green: 0.65, blue: 1.0).opacity(0.04 + promptPulse * 0.06)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5 + promptPulse * 0.6
                        )
                        .frame(width: 240 + promptPulse * 20, height: 240 + promptPulse * 20)

                    RiftLogo()

                    RoundedRectangle(cornerRadius: 60, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.50, green: 0.75, blue: 1.0).opacity(isDropTargeted ? 0.30 : 0.06),
                                    Color(red: 0.20, green: 0.44, blue: 0.90).opacity(isDropTargeted ? 0.15 : 0.02),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isDropTargeted ? 2 : 1
                        )
                        .frame(width: 112, height: 76)
                        .offset(y: 78)
                        .opacity(isDropTargeted ? 1 : 0.5)
                }
                .frame(width: 280, height: 280)
                .shadow(color: Color(red: 0.20, green: 0.45, blue: 0.95).opacity(0.15), radius: 50, x: 0, y: 20)

                VStack(spacing: 10) {
                    Text("Open Video")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))

                    Text("Drop a file here or click to browse")
                        .font(.system(size: 15, weight: .regular))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .foregroundStyle(.white.opacity(0.48))

                    if let statusMessage = state.statusMessage {
                        Text(statusMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(red: 0.45, green: 0.70, blue: 1.0))
                            .padding(.top, 4)
                    }

                    if let progress = state.conversionProgress {
                        ProgressView(value: progress, total: 1.0)
                            .tint(Color(red: 0.36, green: 0.66, blue: 1.0))
                            .frame(width: 200)
                            .padding(.top, 2)
                    }
                }
            }
            .scaleEffect(isDropTargeted ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 80)
    }

    private var videoVignette: some View {
        LinearGradient(
            colors: [
                .black.opacity(0.18),
                .clear,
                .black.opacity(0.55)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func subtitleOverlay(_ text: String) -> some View {
        VStack {
            Spacer()

            Text(text)
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.95), radius: 4, x: 0, y: 1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.black.opacity(0.48))
                }
                .frame(maxWidth: 920)
                .padding(.horizontal, 34)
                .padding(.bottom, state.areControlsVisible ? 154 : 58)
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: state.areControlsVisible)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let droppedURL: URL?

            if let data = item as? Data {
                droppedURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                droppedURL = url
            } else if let string = item as? String {
                droppedURL = URL(string: string)
            } else {
                droppedURL = nil
            }

            guard let droppedURL else { return }

            Task { @MainActor in
                state.loadVideo(droppedURL)
            }
        }

        return true
    }

    private func handleOpenURLs(_ urls: [URL]) {
        guard let url = urls.first else { return }
        state.loadVideo(url)
        AppDelegate.bringPlayerWindowToFront()
    }
}
