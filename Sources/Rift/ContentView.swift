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

private enum ControlsResizeEdge: Equatable {
    case top
    case bottom
    case leading
    case trailing

    var cursor: NSCursor {
        switch self {
        case .top, .bottom:
            return .resizeUpDown
        case .leading, .trailing:
            return .resizeLeftRight
        }
    }

    func scaleDelta(for translation: CGSize, baseSize: CGSize) -> CGFloat {
        switch self {
        case .top:
            return -translation.height / max(baseSize.height, 1)
        case .bottom:
            return translation.height / max(baseSize.height, 1)
        case .leading:
            return -translation.width / max(baseSize.width, 1)
        case .trailing:
            return translation.width / max(baseSize.width, 1)
        }
    }

    func centerOffset(forScaleDelta scaleDelta: CGFloat, baseSize: CGSize) -> CGSize {
        switch self {
        case .top:
            return CGSize(width: 0, height: -scaleDelta * baseSize.height / 2)
        case .bottom:
            return CGSize(width: 0, height: scaleDelta * baseSize.height / 2)
        case .leading:
            return CGSize(width: -scaleDelta * baseSize.width / 2, height: 0)
        case .trailing:
            return CGSize(width: scaleDelta * baseSize.width / 2, height: 0)
        }
    }
}

private enum ControlsInteraction: Equatable {
    case move
    case resize(ControlsResizeEdge)
}

private struct ControlsResizeHandle: View {
    let edge: ControlsResizeEdge
    let onChanged: (ControlsInteraction, CGSize) -> Void
    let onEnded: (ControlsInteraction, CGSize) -> Void

    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    edge.cursor.set()
                } else if !isDragging {
                    NSCursor.arrow.set()
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        isDragging = true
                        edge.cursor.set()
                        onChanged(.resize(edge), value.translation)
                    }
                    .onEnded { value in
                        isDragging = false
                        onEnded(.resize(edge), value.translation)
                        if !isHovered {
                            NSCursor.arrow.set()
                        }
                    }
            )
            .accessibilityHidden(true)
    }
}

private struct ControlsMoveHandle: View {
    let onChanged: (ControlsInteraction, CGSize) -> Void
    let onEnded: (ControlsInteraction, CGSize) -> Void

    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        ZStack {
            Color.clear

            Capsule()
                .fill(.white.opacity(isHovered || isDragging ? 0.42 : 0.16))
                .frame(width: 44, height: 3)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                (isDragging ? NSCursor.closedHand : NSCursor.openHand).set()
            } else if !isDragging {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    isDragging = true
                    NSCursor.closedHand.set()
                    onChanged(.move, value.translation)
                }
                .onEnded { value in
                    isDragging = false
                    onEnded(.move, value.translation)
                    (isHovered ? NSCursor.openHand : NSCursor.arrow).set()
                }
        )
        .accessibilityLabel(NSLocalizedString("Move Controls", comment: ""))
        .help(NSLocalizedString("Drag to move controls", comment: ""))
    }
}

private struct ControlsInteractionHandles: View {
    let onChanged: (ControlsInteraction, CGSize) -> Void
    let onEnded: (ControlsInteraction, CGSize) -> Void

    private let hitWidth: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width.isFinite ? max(proxy.size.width, 0) : 0
            let height = proxy.size.height.isFinite ? max(proxy.size.height, 0) : 0

            ZStack {
                ControlsResizeHandle(edge: .top, onChanged: onChanged, onEnded: onEnded)
                    .frame(width: width, height: hitWidth)
                    .position(x: width / 2, y: hitWidth / 2)

                ControlsResizeHandle(edge: .bottom, onChanged: onChanged, onEnded: onEnded)
                    .frame(width: width, height: hitWidth)
                    .position(x: width / 2, y: max(hitWidth / 2, height - hitWidth / 2))

                ControlsResizeHandle(edge: .leading, onChanged: onChanged, onEnded: onEnded)
                    .frame(width: hitWidth, height: height)
                    .position(x: hitWidth / 2, y: height / 2)

                ControlsResizeHandle(edge: .trailing, onChanged: onChanged, onEnded: onEnded)
                    .frame(width: hitWidth, height: height)
                    .position(x: max(hitWidth / 2, width - hitWidth / 2), y: height / 2)

                ControlsMoveHandle(onChanged: onChanged, onEnded: onEnded)
                    .frame(width: 60, height: 8)
                    .position(x: width / 2, y: 12)
            }
        }
    }
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
    @State private var controlsSize: CGSize = .zero
    @State private var isPositionInitialized = false
    @State private var controlsScale: CGFloat = 1
    @State private var controlsInteraction: ControlsInteraction?
    @State private var controlsInteractionStartPosition: CGPoint = .zero
    @State private var controlsInteractionStartScale: CGFloat = 1

    private let controlsBoundaryMargin: CGFloat = 8
    private let controlsScaleRange: ClosedRange<CGFloat> = 0.65...1.35
    private let controlsResizeKeepsOppositeEdgeFixed = false

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
                PlayerControlsView(state: state)
                    .overlay {
                        ControlsInteractionHandles(
                            onChanged: { interaction, translation in
                                updateControlsInteraction(
                                    interaction,
                                    translation: translation,
                                    in: geometry.size
                                )
                            },
                            onEnded: { interaction, translation in
                                finishControlsInteraction(
                                    interaction,
                                    translation: translation,
                                    in: geometry.size
                                )
                            }
                        )
                    }
                    .opacity(state.areControlsVisible ? 1.0 : 0.0)
                    .scaleEffect(controlsScale)
                    .scaleEffect(state.areControlsVisible ? 1 : 0.96)
                    .allowsHitTesting(state.areControlsVisible)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { updateControlsSize(proxy.size, in: geometry.size) }
                                .onChange(of: proxy.size) { _, newSize in
                                    updateControlsSize(newSize, in: geometry.size)
                                }
                        }
                    }
                    .position(
                        x: controlsPosition.x,
                        y: controlsPosition.y
                    )
                    .scaleEffect(controlsInteraction == .move ? 0.98 : 1)
                    .animation(.spring(response: 0.2, dampingFraction: 0.8), value: controlsInteraction)
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
                        let proposedPosition = CGPoint(x: ratioX * newSize.width, y: ratioY * newSize.height)
                        controlsPosition = clampedControlsPosition(
                            proposedPosition,
                            in: newSize,
                            scale: controlsScale
                        )
                        windowSize = newSize
                    }
                    .simultaneousGesture(
                        TapGesture(count: 2)
                            .onEnded {
                                let w = geometry.size.width
                                let h = geometry.size.height
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                    controlsPosition = clampedControlsPosition(
                                        CGPoint(x: w / 2, y: h - 82),
                                        in: geometry.size,
                                        scale: controlsScale
                                    )
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
        .onReceive(NotificationCenter.default.publisher(for: .riftOpenURLs)) { _ in
            handleOpenURLs(AppDelegate.takePendingOpenURLs())
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

    private func updateControlsSize(_ newSize: CGSize, in windowSize: CGSize) {
        guard newSize.width > 0,
              newSize.height > 0,
              newSize.width.isFinite,
              newSize.height.isFinite else {
            return
        }
        controlsSize = newSize
        guard isPositionInitialized else { return }
        controlsPosition = clampedControlsPosition(
            controlsPosition,
            in: windowSize,
            scale: controlsScale
        )
    }

    private func updateControlsInteraction(
        _ interaction: ControlsInteraction,
        translation: CGSize,
        in windowSize: CGSize
    ) {
        guard controlsSize.width > 0,
              controlsSize.height > 0,
              controlsSize.width.isFinite,
              controlsSize.height.isFinite,
              windowSize.width.isFinite,
              windowSize.height.isFinite,
              translation.width.isFinite,
              translation.height.isFinite else {
            return
        }

        if controlsInteraction == nil {
            controlsInteraction = interaction
            controlsInteractionStartPosition = controlsPosition
            controlsInteractionStartScale = controlsScale
            state.setControlsInteractionActive(true)
        }

        guard controlsInteraction == interaction else { return }
        state.resetHideTimer()

        switch interaction {
        case .move:
            let proposedPosition = CGPoint(
                x: controlsInteractionStartPosition.x + translation.width,
                y: controlsInteractionStartPosition.y + translation.height
            )
            controlsPosition = clampedControlsPosition(
                proposedPosition,
                in: windowSize,
                scale: controlsScale
            )

        case let .resize(edge):
            let scaleSensitivity: CGFloat = controlsResizeKeepsOppositeEdgeFixed ? 1 : 2
            let requestedScale = controlsInteractionStartScale
                + edge.scaleDelta(for: translation, baseSize: controlsSize) * scaleSensitivity
            let maximumFittingScale = min(
                (windowSize.width - controlsBoundaryMargin * 2) / controlsSize.width,
                (windowSize.height - controlsBoundaryMargin * 2) / controlsSize.height
            )
            let maximumScale = max(
                controlsScaleRange.lowerBound,
                min(controlsScaleRange.upperBound, maximumFittingScale)
            )
            let newScale = max(
                controlsScaleRange.lowerBound,
                min(maximumScale, requestedScale)
            )
            let appliedScaleDelta = newScale - controlsInteractionStartScale
            let centerOffset = controlsResizeKeepsOppositeEdgeFixed
                ? edge.centerOffset(
                    forScaleDelta: appliedScaleDelta,
                    baseSize: controlsSize
                )
                : .zero
            let proposedPosition = CGPoint(
                x: controlsInteractionStartPosition.x + centerOffset.width,
                y: controlsInteractionStartPosition.y + centerOffset.height
            )

            controlsScale = newScale
            controlsPosition = clampedControlsPosition(
                proposedPosition,
                in: windowSize,
                scale: newScale
            )
        }
    }

    private func finishControlsInteraction(
        _ interaction: ControlsInteraction,
        translation: CGSize,
        in windowSize: CGSize
    ) {
        updateControlsInteraction(interaction, translation: translation, in: windowSize)
        guard controlsInteraction == interaction else { return }

        controlsPosition = clampedControlsPosition(
            controlsPosition,
            in: windowSize,
            scale: controlsScale
        )
        controlsInteraction = nil
        controlsInteractionStartPosition = .zero
        controlsInteractionStartScale = controlsScale
        state.setControlsInteractionActive(false)
    }

    private func clampedControlsPosition(
        _ proposedPosition: CGPoint,
        in windowSize: CGSize,
        scale: CGFloat
    ) -> CGPoint {
        guard proposedPosition.x.isFinite,
              proposedPosition.y.isFinite,
              windowSize.width.isFinite,
              windowSize.height.isFinite,
              controlsSize.width.isFinite,
              controlsSize.height.isFinite,
              scale.isFinite else {
            return CGPoint(
                x: controlsPosition.x.isFinite ? controlsPosition.x : 0,
                y: controlsPosition.y.isFinite ? controlsPosition.y : 0
            )
        }

        let halfWidth = controlsSize.width * scale / 2
        let halfHeight = controlsSize.height * scale / 2
        let minimumX = halfWidth + controlsBoundaryMargin
        let maximumX = windowSize.width - halfWidth - controlsBoundaryMargin
        let minimumY = halfHeight + controlsBoundaryMargin
        let maximumY = windowSize.height - halfHeight - controlsBoundaryMargin

        let x = minimumX <= maximumX
            ? max(minimumX, min(maximumX, proposedPosition.x))
            : windowSize.width / 2
        let y = minimumY <= maximumY
            ? max(minimumY, min(maximumY, proposedPosition.y))
            : windowSize.height / 2
        return CGPoint(x: x, y: y)
    }

    private var subtitleBottomPadding: CGFloat {
        let defaultPadding: CGFloat = 58
        guard state.areControlsVisible,
              controlsSize.height > 0,
              windowSize.height > 0 else {
            return defaultPadding
        }

        let scaledHalfHeight = controlsSize.height * controlsScale / 2
        let controlsTop = controlsPosition.y - scaledHalfHeight
        let controlsBottom = controlsPosition.y + scaledHalfHeight
        guard controlsBottom > windowSize.height / 2 else {
            return defaultPadding
        }

        return max(defaultPadding, windowSize.height - controlsTop + 16)
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
                .padding(.bottom, subtitleBottomPadding)
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
