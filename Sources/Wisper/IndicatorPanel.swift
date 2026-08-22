import AppKit

/// The Wispr-style floating pill at the bottom-center of the screen.
/// Three modes: live waveform while recording, gentle pulse while processing,
/// and transient text messages ("Copied — paste anywhere").
final class IndicatorPanel {
    private var panel: NSPanel?
    private var container: NSVisualEffectView?
    private let waveform = WaveformView(frame: NSRect(x: 0, y: 0, width: 120, height: 28))
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    private let pillHeight: CGFloat = 36

    // MARK: - Public modes

    func showRecording() {
        hideWork?.cancel()
        label.isHidden = true
        waveform.isHidden = false
        waveform.mode = .live
        present(width: 148)
        waveform.start()
    }

    func setLevel(_ level: Float) {
        waveform.setLevel(CGFloat(level))
    }

    func showProcessing() {
        hideWork?.cancel()
        label.isHidden = true
        waveform.isHidden = false
        waveform.mode = .pulse
    }

    func showMessage(_ message: String, for seconds: TimeInterval = 1.6) {
        hideWork?.cancel()
        waveform.stop()
        waveform.isHidden = true
        label.stringValue = message
        label.isHidden = false
        label.sizeToFit()
        present(width: label.frame.width + 28)
        label.frame.origin = NSPoint(
            x: ((panel?.frame.width ?? 0) - label.frame.width) / 2,
            y: (pillHeight - label.frame.height) / 2
        )
        scheduleHide(after: seconds)
    }

    func hide() {
        hideWork?.cancel()
        waveform.stop()
        dismiss()
    }

    // MARK: - Panel management

    private func present(width: CGFloat) {
        let size = NSSize(width: width, height: pillHeight)
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            container.material = .hudWindow
            container.state = .active
            container.wantsLayer = true
            container.layer?.masksToBounds = true

            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .white
            container.addSubview(waveform)
            container.addSubview(label)
            panel.contentView = container

            self.panel = panel
            self.container = container
        }

        guard let panel, let container else { return }
        panel.setContentSize(size)
        container.frame = NSRect(origin: .zero, size: size)
        container.layer?.cornerRadius = pillHeight / 2
        waveform.frame = NSRect(
            x: (size.width - waveform.frame.width) / 2,
            y: (pillHeight - waveform.frame.height) / 2,
            width: waveform.frame.width,
            height: waveform.frame.height
        )

        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.minY + 48
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
    }

    private func scheduleHide(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }
}

/// Animated vertical bars. `.live` follows the mic level; `.pulse` is a calm
/// travelling sine wave used while transcribing.
final class WaveformView: NSView {
    enum Mode { case live, pulse }
    var mode: Mode = .live

    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let minBarHeight: CGFloat = 3

    private var heights: [CGFloat]
    private var jitter: [CGFloat]
    private var level: CGFloat = 0
    private var phase: CGFloat = 0
    private var timer: Timer?
    private var ticks = 0

    override init(frame frameRect: NSRect) {
        heights = Array(repeating: minBarHeight, count: barCount)
        jitter = (0..<barCount).map { _ in CGFloat.random(in: 0.4...1.0) }
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError() }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        level = 0
        heights = Array(repeating: minBarHeight, count: barCount)
    }

    func setLevel(_ newLevel: CGFloat) {
        // Fast attack, slow release — speech looks lively, pauses settle.
        level = newLevel > level ? newLevel : level * 0.75 + newLevel * 0.25
    }

    private func tick() {
        ticks += 1
        phase += 0.35
        let maxHeight = bounds.height

        for i in 0..<barCount {
            // Refresh each bar's random character a few times a second.
            if (ticks + i) % 4 == 0 { jitter[i] = CGFloat.random(in: 0.35...1.0) }

            let target: CGFloat
            switch mode {
            case .live:
                // Center-weighted envelope so the pill reads as a voice wave.
                let centerBias = 1.0 - abs(CGFloat(i) - CGFloat(barCount - 1) / 2) / (CGFloat(barCount) / 2) * 0.6
                target = minBarHeight + min(1, level) * (maxHeight - minBarHeight) * jitter[i] * centerBias
            case .pulse:
                target = minBarHeight + (maxHeight * 0.28) * (0.5 + 0.5 * sin(phase + CGFloat(i) * 0.45))
            }
            heights[i] += (target - heights[i]) * 0.45
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let spacing = (bounds.width - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1)
        NSColor.white.withAlphaComponent(0.92).setFill()
        for i in 0..<barCount {
            let h = max(minBarHeight, min(heights[i], bounds.height))
            let rect = NSRect(
                x: CGFloat(i) * (barWidth + spacing),
                y: (bounds.height - h) / 2,
                width: barWidth,
                height: h
            )
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
