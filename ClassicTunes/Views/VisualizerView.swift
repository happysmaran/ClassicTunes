import SwiftUI

/// The visualizers available from the View menu and the picker in the visualizer itself.
enum VisualizerStyle: String, CaseIterable, Identifiable {
    case classic, spectrum, jelly, particles
    // Homages to the visualizers that shipped with (or ran inside) WinAmp.
    case analyzerBars, oscilloscope, kaleidoscope, tunnel
    // Designed for deaf and hard-of-hearing users: they show what the music is doing (beat,
    // pitch range, melody over time) with labels, large shapes, and colorblind-safe colors.
    case rhythmPulse, frequencyMeters, spectrogram

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .classic: return "visualizer.style.classic"
        case .spectrum: return "visualizer.style.spectrum"
        case .jelly: return "visualizer.style.jelly"
        case .particles: return "visualizer.style.particles"
        case .analyzerBars: return "visualizer.style.analyzerBars"
        case .oscilloscope: return "visualizer.style.oscilloscope"
        case .kaleidoscope: return "visualizer.style.kaleidoscope"
        case .tunnel: return "visualizer.style.tunnel"
        case .rhythmPulse: return "visualizer.style.rhythmPulse"
        case .frequencyMeters: return "visualizer.style.frequencyMeters"
        case .spectrogram: return "visualizer.style.spectrogram"
        }
    }
}

/// Per-frame smoothed audio data plus particle state.
///
/// The analyzer publishes raw values at audio-buffer rate; this runs once per display frame and
/// eases toward them using the real elapsed time, so motion stays fluid at any refresh rate
/// (including 120 Hz ProMotion) with a fast attack and a gentle decay.
private final class VisualizerState {
    struct Particle {
        var x: CGFloat, y: CGFloat
        var vx: CGFloat, vy: CGFloat
        var life: Double
        var hue: Double
    }

    var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    var peaks = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    var waveform = [Float](repeating: 0, count: AudioAnalyzer.waveformCount)
    var level: Float = 0
    var bass: Float = 0
    var particles: [Particle] = []
    /// Tunnel travel, integrated from the speed each frame so rings don't jump when loudness changes.
    var tunnelPosition: Double = 0

    // Accessibility visualizers
    /// Smoothed 0...1 energy in the bass (<~250 Hz), mid, and treble (>~4 kHz) ranges.
    var bassLevel: Float = 0, midLevel: Float = 0, trebleLevel: Float = 0
    /// 1 right after a detected beat, decaying toward 0.
    var beatPulse: Float = 0
    var beatTimes: [TimeInterval] = []
    var bpm: Double = 0
    /// Recent band snapshots (oldest first) and the sub-column scroll progress for the spectrogram.
    var history: [[Float]] = []
    var historyProgress: Double = 0
    static let historyColumns = 120
    static let historyRate = 30.0

    private var beatAverage: Float = 0
    private var lastBeat: TimeInterval = -10
    private var beatIntervals: [Double] = []

    private var lastTime: TimeInterval?
    private var emitRemainder: Double = 0
    private static let maxParticles = 700

    /// Frame-rate independent exponential easing factor.
    private func ease(_ rate: Float, _ dt: Float) -> Float { 1 - exp(-rate * dt) }

    func advance(to time: TimeInterval, size: CGSize, style: VisualizerStyle) {
        let dt = Float(min(0.1, max(0.001, time - (lastTime ?? time - 1.0 / 60))))
        lastTime = time

        let snap = AudioAnalyzer.shared.snapshot()
        let attack = ease(45, dt), decay = ease(7, dt), wave = ease(40, dt)

        for i in 0..<bands.count {
            let target = snap.bands[i]
            bands[i] += (target - bands[i]) * (target > bands[i] ? attack : decay)
            // Peak caps hold briefly, then fall with a little gravity.
            peaks[i] = max(bands[i], peaks[i] - dt * 0.35)
        }
        for i in 0..<waveform.count {
            waveform[i] += (snap.waveform[i] - waveform[i]) * wave
        }
        let levelTarget = min(1, snap.level * 4)
        level += (levelTarget - level) * (levelTarget > level ? attack : ease(5, dt))
        let bassTarget = bands.prefix(8).reduce(0, +) / 8
        bass = bassTarget
        tunnelPosition = (tunnelPosition + (0.12 + Double(level) * 0.5) * Double(dt)).truncatingRemainder(dividingBy: 1)

        if style == .particles { advanceParticles(dt: Double(dt), size: size) }

        if style == .rhythmPulse || style == .frequencyMeters {
            bassLevel = groupLevel(0..<10)
            midLevel = groupLevel(10..<33)
            trebleLevel = groupLevel(33..<bands.count)
        }
        if style == .rhythmPulse { detectBeat(raw: snap.bands[0..<10].reduce(0, +) / 10, time: time, dt: dt) }
        if style == .spectrogram { advanceHistory(dt: Double(dt)) }
    }

    private func groupLevel(_ range: Range<Int>) -> Float {
        min(1, bands[range].reduce(0, +) / Float(range.count) * 1.3)
    }

    /// Onset detection on bass energy: a beat is a jump well above the recent average, with a
    /// refractory gap so the pulse can never flash faster than about 3 times per second.
    private func detectBeat(raw: Float, time: TimeInterval, dt: Float) {
        if beatAverage == 0 { beatAverage = raw }
        if raw > 0.15, raw > beatAverage * 1.3 + 0.04, time - lastBeat > 0.34 {
            let interval = time - lastBeat
            lastBeat = time
            beatPulse = 1
            beatTimes.append(time)
            if interval < 1.5 {
                beatIntervals.append(interval)
                if beatIntervals.count > 8 { beatIntervals.removeFirst() }
            } else {
                beatIntervals.removeAll()
            }
            if beatIntervals.count >= 4 {
                bpm = 60 / beatIntervals.sorted()[beatIntervals.count / 2]
            }
        }
        beatAverage += (raw - beatAverage) * ease(1.5, dt)
        beatPulse *= exp(-5 * dt)
        beatTimes.removeAll { time - $0 > 1.2 }
        if time - lastBeat > 2.5 { bpm = 0; beatIntervals.removeAll() }
    }

    private func advanceHistory(dt: Double) {
        historyProgress += dt * Self.historyRate
        while historyProgress >= 1 {
            historyProgress -= 1
            history.append(bands)
            if history.count > Self.historyColumns { history.removeFirst() }
        }
    }

    private func advanceParticles(dt: Double, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        emitRemainder += (40 + Double(level) * 700 + Double(bass) * 300) * dt
        while emitRemainder >= 1, particles.count < Self.maxParticles {
            emitRemainder -= 1
            let angle = Double.random(in: 0..<(2 * .pi))
            let speed = CGFloat(Double.random(in: 40...160) * (1 + Double(bass) * 3))
            particles.append(Particle(
                x: center.x, y: center.y,
                vx: cos(angle) * speed, vy: sin(angle) * speed,
                life: 1, hue: Double.random(in: 0...1)
            ))
        }
        emitRemainder = min(emitRemainder, 1)

        let cdt = CGFloat(dt)
        for i in particles.indices {
            particles[i].x += particles[i].vx * cdt
            particles[i].y += particles[i].vy * cdt
            particles[i].life -= dt * 0.45
        }
        particles.removeAll { $0.life <= 0 }
    }
}

/// Audio visualizers modeled on the ones that shipped with iTunes.
struct VisualizerView: View {
    @AppStorage("visualizerStyle") private var styleRaw: String = VisualizerStyle.classic.rawValue
    @State private var state = VisualizerState()
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var style: VisualizerStyle { VisualizerStyle(rawValue: styleRaw) ?? .classic }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                state.advance(to: t, size: size, style: style)
                switch style {
                case .classic: drawClassic(&context, size, t)
                case .spectrum: drawSpectrum(&context, size)
                case .jelly: drawJelly(&context, size, t)
                case .particles: drawParticles(&context, size, t)
                case .analyzerBars: drawAnalyzerBars(&context, size)
                case .oscilloscope: drawOscilloscope(&context, size)
                case .kaleidoscope: drawKaleidoscope(&context, size, t)
                case .tunnel: drawTunnel(&context, size, t)
                case .rhythmPulse: drawRhythmPulse(&context, size, t)
                case .frequencyMeters: drawFrequencyMeters(&context, size)
                case .spectrogram: drawSpectrogram(&context, size)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("visualizer.accessibility.label")
        .background(Color.black)
        .overlay(alignment: .topTrailing) { stylePicker }
        .onHover { isHovering = $0 }
        .onAppear { AudioAnalyzer.shared.isActive = true }
        .onDisappear {
            AudioAnalyzer.shared.isActive = false
            AudioAnalyzer.shared.reset()
        }
    }

    private var stylePicker: some View {
        Picker("menu.visualizerStyle", selection: $styleRaw) {
            ForEach(VisualizerStyle.allCases) { style in
                Text(style.titleKey).tag(style.rawValue)
            }
        }
        .labelsHidden()
        .frame(width: 130)
        .padding(10)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
    }

    // MARK: - Shared helpers

    /// Smooth curve through points using midpoint quadratic segments (no visible corners).
    private func smoothPath(_ points: [CGPoint], closed: Bool = false) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }

        if closed {
            path.move(to: mid(points[points.count - 1], points[0]))
            for i in 0..<points.count {
                path.addQuadCurve(to: mid(points[i], points[(i + 1) % points.count]), control: points[i])
            }
            path.closeSubpath()
        } else {
            path.move(to: points[0])
            for i in 1..<(points.count - 1) {
                path.addQuadCurve(to: mid(points[i], points[i + 1]), control: points[i])
            }
            path.addLine(to: points[points.count - 1])
        }
        return path
    }

    private func hueColor(_ hue: Double, saturation: Double = 0.85, brightness: Double = 1, opacity: Double = 1) -> Color {
        Color(hue: hue - floor(hue), saturation: saturation, brightness: brightness, opacity: opacity)
    }

    // MARK: - Classic

    /// Glowing, hue-shifting ribbons riding the waveform over a mirrored spectrum.
    private func drawClassic(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let midY = size.height / 2
        let level = CGFloat(state.level)

        let glow = Gradient(colors: [hueColor(t * 0.03, saturation: 0.9, brightness: 0.5, opacity: 0.35 * Double(level) + 0.05), .clear])
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(glow, center: CGPoint(x: size.width / 2, y: midY),
                                  startRadius: 0, endRadius: max(size.width, size.height) * 0.6)
        )

        let bandCount = state.bands.count
        let barWidth = size.width / CGFloat(bandCount)
        for (i, value) in state.bands.enumerated() {
            let h = CGFloat(value) * size.height * 0.45
            let color = hueColor(Double(i) / Double(bandCount) * 0.8 + t * 0.05, opacity: 0.55)
            let rect = CGRect(x: CGFloat(i) * barWidth + 1, y: midY - h, width: barWidth - 2, height: h * 2)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 3), with: .color(color))
        }

        context.blendMode = .plusLighter
        let ribbonCount = 5
        let points = state.waveform.count
        for r in 0..<ribbonCount {
            let offset = Double(r) / Double(ribbonCount)
            let pts: [CGPoint] = (0..<points).map { i in
                let progress = Double(i) / Double(points - 1)
                let swirl = sin(progress * .pi * 2 * (1.5 + offset) + t * (0.8 + offset)) * 0.15
                let amplitude = CGFloat(state.waveform[i]) * size.height * 1.4
                return CGPoint(
                    x: size.width * CGFloat(progress),
                    y: midY + amplitude * CGFloat(1 - offset * 0.5) + CGFloat(swirl) * size.height * (0.2 + level * 0.5)
                )
            }
            let path = smoothPath(pts)
            let color = hueColor(t * 0.06 + offset * 0.5, saturation: 0.8)
            context.stroke(path, with: .color(color.opacity(0.25)), lineWidth: 8 + level * 6)
            context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1.5)
        }
    }

    // MARK: - Spectrum

    /// Green-to-red analyzer bars with falling peak caps.
    private func drawSpectrum(_ context: inout GraphicsContext, _ size: CGSize) {
        let count = state.bands.count
        let slot = size.width / CGFloat(count)
        let gradient = Gradient(stops: [
            .init(color: .green, location: 0),
            .init(color: .yellow, location: 0.65),
            .init(color: .red, location: 1)
        ])
        // Absolute gradient so a bar's color depends on its height, like a VU meter.
        let shading = GraphicsContext.Shading.linearGradient(
            gradient, startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: 0, y: size.height * 0.05)
        )
        let usable = size.height * 0.9

        for i in 0..<count {
            let x = CGFloat(i) * slot + slot * 0.12
            let width = slot * 0.76
            let h = max(2, CGFloat(state.bands[i]) * usable)
            let bar = CGRect(x: x, y: size.height - h, width: width, height: h)
            context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: shading)

            let capY = size.height - max(2, CGFloat(state.peaks[i]) * usable) - 4
            context.fill(Path(CGRect(x: x, y: capY, width: width, height: 2)), with: .color(.white.opacity(0.9)))
        }
    }

    // MARK: - Jelly

    /// A wobbling, glowing blob that swells with the music.
    private func drawJelly(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let base = min(size.width, size.height) * 0.22
        let count = 120
        let bands = state.bands

        context.blendMode = .plusLighter
        for layer in 0..<4 {
            let l = Double(layer)
            let scale = 1 + CGFloat(layer) * 0.18
            let pts: [CGPoint] = (0..<count).map { i in
                let theta = Double(i) / Double(count) * 2 * .pi
                // Mirror the spectrum around the circle so the shape is left/right symmetric.
                let pos = abs(Double(i) / Double(count) - 0.5) * 2 * Double(bands.count - 1)
                let lo = Int(pos), hi = min(lo + 1, bands.count - 1)
                let value = CGFloat(bands[lo] + (bands[hi] - bands[lo]) * Float(pos - Double(lo)))
                let wobble = 1 + 0.06 * sin(theta * 3 + t * (1.2 + l * 0.3)) + 0.04 * sin(theta * 5 - t * 0.9)
                let r = base * scale * CGFloat(wobble) * (1 + value * 1.1 + CGFloat(state.level) * 0.35)
                return CGPoint(x: center.x + CGFloat(cos(theta)) * r, y: center.y + CGFloat(sin(theta)) * r)
            }
            let path = smoothPath(pts, closed: true)
            let color = hueColor(t * 0.05 + l * 0.12)
            context.fill(path, with: .color(color.opacity(layer == 0 ? 0.35 : 0.07)))
            context.stroke(path, with: .color(color.opacity(0.35)), lineWidth: 7)
            context.stroke(path, with: .color(color.opacity(0.95)), lineWidth: 1.5)
        }
    }

    // MARK: - Analyzer Bars (WinAmp main-window analyzer)

    /// Chunky segmented bars with the classic green-to-red palette and floating peak markers.
    private func drawAnalyzerBars(_ context: inout GraphicsContext, _ size: CGSize) {
        let barCount = 19
        let group = state.bands.count / barCount + 1
        let segment: CGFloat = 5          // segment height including the gap
        let gap: CGFloat = 1.5
        let rows = max(1, Int(size.height * 0.9 / segment))
        let slot = size.width / CGFloat(barCount)
        let barWidth = slot * 0.8

        var bars = Path()
        var caps = Path()
        for i in 0..<barCount {
            let lo = i * state.bands.count / barCount
            let hi = min(state.bands.count, lo + group)
            let slice = state.bands[lo..<hi]
            let value = (slice.reduce(0, +) / Float(slice.count)) * 1.15
            let peak = (state.peaks[lo..<hi].reduce(0, +) / Float(hi - lo)) * 1.15
            let x = CGFloat(i) * slot + (slot - barWidth) / 2
            let lit = min(rows, Int(value * Float(rows)))
            for r in 0..<lit {
                let y = size.height - CGFloat(r + 1) * segment
                bars.addRect(CGRect(x: x, y: y, width: barWidth, height: segment - gap))
            }
            let peakRow = min(rows - 1, Int(peak * Float(rows)))
            let py = size.height - CGFloat(peakRow + 1) * segment
            caps.addRect(CGRect(x: x, y: py, width: barWidth, height: segment - gap))
        }

        let palette = Gradient(stops: [
            .init(color: Color(red: 0.1, green: 0.8, blue: 0.1), location: 0),
            .init(color: Color(red: 0.8, green: 0.85, blue: 0.1), location: 0.5),
            .init(color: Color(red: 0.95, green: 0.55, blue: 0.05), location: 0.75),
            .init(color: Color(red: 0.95, green: 0.1, blue: 0.1), location: 1)
        ])
        context.fill(bars, with: .linearGradient(
            palette, startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: 0, y: size.height * 0.1)))
        context.fill(caps, with: .color(Color(white: 0.85)))
    }

    // MARK: - Oscilloscope

    /// A single phosphor-green scope trace over a faint graticule.
    private func drawOscilloscope(_ context: inout GraphicsContext, _ size: CGSize) {
        var grid = Path()
        for i in 1..<8 {
            let x = size.width * CGFloat(i) / 8
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for i in 1..<6 {
            let y = size.height * CGFloat(i) / 6
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(Color(red: 0.1, green: 0.4, blue: 0.1).opacity(0.35)), lineWidth: 0.5)

        let points = state.waveform.count
        let amplitude = size.height * 0.45
        let pts: [CGPoint] = (0..<points).map { i in
            CGPoint(x: size.width * CGFloat(i) / CGFloat(points - 1),
                    y: size.height / 2 - CGFloat(max(-1, min(1, state.waveform[i] * 1.6))) * amplitude)
        }
        let path = smoothPath(pts)
        // Winamp colored the trace by height: bright near the extremes, green through the middle.
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [.red, .yellow, Color(red: 0.2, green: 1, blue: 0.2), .yellow, .red]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height))
        context.blendMode = .plusLighter
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
        context.opacity = 0.9
        context.stroke(path, with: shading, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Kaleidoscope (Milkdrop-style)

    /// A mirrored, rotating spirograph whose arms are driven by the spectrum.
    private func drawKaleidoscope(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) * 0.48
        let slices = 8
        let count = state.bands.count

        // Build one arm; the rest are rotated/mirrored copies of it.
        let arm: [CGPoint] = (0..<count).map { i in
            let p = Double(i) / Double(count - 1)
            let band = CGFloat(state.bands[i])
            let radius = maxR * CGFloat(0.08 + 0.92 * p) * (0.35 + band * 0.85)
            let angle = p * .pi / Double(slices) * 2 + sin(p * 7 + t * 0.9) * 0.35
            return CGPoint(x: CGFloat(cos(angle)) * radius, y: CGFloat(sin(angle)) * radius)
        }
        let path = smoothPath(arm)
        let spin = t * (0.15 + Double(state.level) * 0.4)

        context.blendMode = .plusLighter
        context.translateBy(x: center.x, y: center.y)
        for k in 0..<slices {
            for mirrored in [false, true] {
                var c = context
                c.rotate(by: .radians(spin + Double(k) * 2 * .pi / Double(slices)))
                if mirrored { c.scaleBy(x: 1, y: -1) }
                let color = hueColor(t * 0.07 + Double(k) / Double(slices) * 0.4)
                c.stroke(path, with: .color(color.opacity(0.22)), lineWidth: 6 + CGFloat(state.level) * 6)
                c.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1.4)
            }
        }
    }

    // MARK: - Tunnel

    /// Concentric rings rushing toward the viewer, warped by the spectrum.
    private func drawTunnel(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let maxR = hypot(size.width, size.height) * 0.55
        let ringCount = 22
        let segments = 72
        let bands = state.bands
        let travel = state.tunnelPosition
        let center = CGPoint(x: size.width / 2 + CGFloat(sin(t * 0.5)) * size.width * 0.06,
                             y: size.height / 2 + CGFloat(cos(t * 0.37)) * size.height * 0.06)

        context.blendMode = .plusLighter
        for r in 0..<ringCount {
            let z = (Double(r) / Double(ringCount) + travel).truncatingRemainder(dividingBy: 1)
            let radius = maxR * CGFloat(z * z)
            guard radius > 2 else { continue }
            let twist = t * 0.4 + z * 3
            let pts: [CGPoint] = (0..<segments).map { i in
                let theta = Double(i) / Double(segments) * 2 * .pi
                let pos = abs(Double(i) / Double(segments) - 0.5) * 2 * Double(bands.count - 1)
                let lo = Int(pos), hi = min(lo + 1, bands.count - 1)
                let value = CGFloat(bands[lo] + (bands[hi] - bands[lo]) * Float(pos - Double(lo)))
                let warp = 1 + value * 0.45 * CGFloat(1 - z) + CGFloat(sin(theta * 3 + twist)) * 0.04
                return CGPoint(x: center.x + CGFloat(cos(theta)) * radius * warp,
                               y: center.y + CGFloat(sin(theta)) * radius * warp)
            }
            let path = smoothPath(pts, closed: true)
            let color = hueColor(t * 0.05 + z * 0.6)
            let fade = min(1, z * 2.5)
            context.stroke(path, with: .color(color.opacity(0.9 * fade)), lineWidth: 0.8 + CGFloat(z) * 3.5)
        }
    }

    // MARK: - Accessibility palette

    /// Okabe-Ito colors, distinguishable under the common forms of color blindness.
    private enum Access {
        static let blue = Color(red: 0, green: 0.447, blue: 0.698)
        static let skyBlue = Color(red: 0.337, green: 0.706, blue: 0.914)
        static let vermillion = Color(red: 0.835, green: 0.369, blue: 0)
        static let yellow = Color(red: 0.941, green: 0.894, blue: 0.259)
        static let panel = Color(white: 0.12)
    }

    // MARK: - Rhythm Pulse

    /// A large circle that swells on every beat, with expanding rings, a beat label, and tempo.
    /// Beats are rate-limited to ~3/s and the screen-edge glow is skipped under Reduce Motion.
    private func drawRhythmPulse(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let minDim = min(size.width, size.height)
        let pulse = CGFloat(state.beatPulse)

        if !reduceMotion, pulse > 0.02 {
            let edge = Path(CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6))
            context.stroke(edge, with: .color(Access.yellow.opacity(Double(pulse) * 0.7)), lineWidth: 12)
        }

        for born in state.beatTimes {
            let age = (t - born) / 1.2
            guard age >= 0, age < 1 else { continue }
            let r = minDim * (0.2 + CGFloat(reduceMotion ? age * 0.15 : age) * 0.35)
            let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            context.stroke(ring, with: .color(Access.skyBlue.opacity(1 - age)), lineWidth: 6)
        }

        let scale: CGFloat = reduceMotion ? 0.12 : 0.3
        let r = minDim * 0.18 * (1 + pulse * scale + CGFloat(state.level) * 0.1)
        let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        context.fill(circle, with: .color(Access.yellow.opacity(0.15 + Double(pulse) * 0.85)))
        context.stroke(circle, with: .color(Access.yellow), lineWidth: 8)

        let onYellow = pulse > 0.5
        context.draw(
            Text("visualizer.label.beat").font(.system(size: max(18, minDim * 0.06), weight: .heavy))
                .foregroundColor(onYellow ? Color.black : Color.white),
            at: center, anchor: .center
        )

        if state.bpm > 0 {
            context.draw(
                Text(verbatim: "\(Int(state.bpm.rounded())) BPM")
                    .font(.system(size: max(16, minDim * 0.05), weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white),
                at: CGPoint(x: center.x, y: min(size.height - 24, center.y + minDim * 0.4)), anchor: .center
            )
        }
    }

    // MARK: - Bass / Mid / Treble meters

    /// Three big labeled meters with percentages, so it's clear which part of the sound is active.
    private func drawFrequencyMeters(_ context: inout GraphicsContext, _ size: CGSize) {
        let columns: [(label: LocalizedStringKey, hint: LocalizedStringKey, value: Float, color: Color)] = [
            ("visualizer.label.bass", "visualizer.hint.bass", state.bassLevel, Access.blue),
            ("visualizer.label.mid", "visualizer.hint.mid", state.midLevel, Access.vermillion),
            ("visualizer.label.treble", "visualizer.hint.treble", state.trebleLevel, Access.yellow)
        ]
        let gap = size.width * 0.04
        let totalWidth = size.width * 0.8
        let colWidth = (totalWidth - gap * 2) / 3
        let left = (size.width - totalWidth) / 2
        let top = size.height * 0.14
        let meterHeight = size.height * 0.6
        let fontSize = max(16, min(size.width, size.height) * 0.045)

        for (i, col) in columns.enumerated() {
            let x = left + CGFloat(i) * (colWidth + gap)
            let box = CGRect(x: x, y: top, width: colWidth, height: meterHeight)
            context.fill(Path(roundedRect: box, cornerRadius: 14), with: .color(Access.panel))

            let fill = meterHeight * CGFloat(col.value)
            let fillRect = CGRect(x: x, y: top + meterHeight - fill, width: colWidth, height: fill)
            context.fill(Path(roundedRect: fillRect, cornerRadius: 14), with: .color(col.color))
            context.stroke(Path(roundedRect: box, cornerRadius: 14), with: .color(.white), lineWidth: 3)

            context.draw(
                Text(verbatim: "\(Int((col.value * 100).rounded()))%")
                    .font(.system(size: fontSize, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white),
                at: CGPoint(x: box.midX, y: top - fontSize * 0.9), anchor: .center
            )
            context.draw(
                Text(col.label).font(.system(size: fontSize * 1.2, weight: .heavy)).foregroundColor(.white),
                at: CGPoint(x: box.midX, y: box.maxY + fontSize * 1.1), anchor: .center
            )
            context.draw(
                Text(col.hint).font(.system(size: fontSize * 0.8)).foregroundColor(Color(white: 0.8)),
                at: CGPoint(x: box.midX, y: box.maxY + fontSize * 2.3), anchor: .center
            )
        }
    }

    // MARK: - Spectrogram

    /// Scrolling history of the spectrum (low pitches at the bottom, newest on the right), so
    /// melodies, rhythms and song structure can be followed by eye.
    private func drawSpectrogram(_ context: inout GraphicsContext, _ size: CGSize) {
        // Viridis-like sequential palette: ordered by brightness, so it also reads in grayscale.
        let palette: [Color] = [
            Color(red: 0.267, green: 0.005, blue: 0.329), Color(red: 0.275, green: 0.196, blue: 0.494),
            Color(red: 0.212, green: 0.361, blue: 0.553), Color(red: 0.153, green: 0.498, blue: 0.557),
            Color(red: 0.122, green: 0.631, blue: 0.529), Color(red: 0.290, green: 0.757, blue: 0.427),
            Color(red: 0.624, green: 0.855, blue: 0.227), Color(red: 0.992, green: 0.906, blue: 0.145)
        ]
        let plot = CGRect(x: size.width * 0.12, y: 12, width: size.width * 0.86, height: size.height - 24)
        context.fill(Path(plot), with: .color(palette[0]))

        let columns = VisualizerState.historyColumns
        let colWidth = plot.width / CGFloat(columns - 1)
        let rows = state.bands.count
        let rowHeight = plot.height / CGFloat(rows)
        // Slide smoothly between the discrete columns instead of stepping.
        let shift = CGFloat(state.historyProgress) * colWidth

        var paths = [Path](repeating: Path(), count: palette.count)
        let history = state.history
        for (c, column) in history.enumerated() {
            let x = plot.maxX - CGFloat(history.count - 1 - c) * colWidth - shift
            guard x + colWidth > plot.minX else { continue }
            for r in 0..<rows {
                let level = Int(min(0.999, max(0, column[r])) * Float(palette.count))
                if level == 0 { continue }
                let y = plot.maxY - CGFloat(r + 1) * rowHeight
                paths[level].addRect(CGRect(x: x, y: y, width: colWidth + 0.5, height: rowHeight + 0.5))
            }
        }
        // Clip only the heat map, so the border and labels aren't cut off.
        var clipped = context
        clipped.clip(to: Path(plot))
        for level in 1..<palette.count { clipped.fill(paths[level], with: .color(palette[level])) }

        context.stroke(Path(plot), with: .color(.white.opacity(0.8)), lineWidth: 2)

        let font = Font.system(size: max(13, min(size.width, size.height) * 0.032), weight: .semibold)
        context.draw(Text("visualizer.label.highPitch").font(font).foregroundColor(.white),
                     at: CGPoint(x: plot.minX - 8, y: plot.minY + 8), anchor: .topTrailing)
        context.draw(Text("visualizer.label.lowPitch").font(font).foregroundColor(.white),
                     at: CGPoint(x: plot.minX - 8, y: plot.maxY - 8), anchor: .bottomTrailing)
        context.draw(Text("visualizer.label.now").font(font).foregroundColor(.white),
                     at: CGPoint(x: plot.maxX - 8, y: plot.minY + 8), anchor: .topTrailing)
    }

    // MARK: - Particles

    /// A starfield of glowing sparks thrown outward on the beat.
    private func drawParticles(_ context: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let coreRadius = 20 + CGFloat(state.bass) * 60
        let core = Gradient(colors: [hueColor(t * 0.05, saturation: 0.6, opacity: 0.6 * Double(state.bass) + 0.15), .clear])
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - coreRadius * 3, y: center.y - coreRadius * 3, width: coreRadius * 6, height: coreRadius * 6)),
            with: .radialGradient(core, center: center, startRadius: 0, endRadius: coreRadius * 3)
        )

        context.blendMode = .plusLighter
        let sizeBoost = 1 + CGFloat(state.level) * 1.5
        for p in state.particles {
            let radius = (1.5 + CGFloat(1 - p.life) * 3) * sizeBoost
            let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(hueColor(p.hue + t * 0.05, opacity: min(1, p.life) * 0.9)))
        }
    }
}
