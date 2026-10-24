import SwiftUI

// The original iTunes-style "Classic Visualizer": glowing, hue-shifting ribbons that ripple
// with the waveform over a mirrored spectrum, drawn on black.
struct VisualizerView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, date: timeline.date)
            }
        }
        .background(Color.black)
        .onAppear { AudioAnalyzer.shared.isActive = true }
        .onDisappear {
            AudioAnalyzer.shared.isActive = false
            AudioAnalyzer.shared.reset()
        }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, date: Date) {
        let snap = AudioAnalyzer.shared.snapshot()
        let t = date.timeIntervalSinceReferenceDate
        let midY = size.height / 2
        let level = CGFloat(min(1, snap.level * 4))

        // Soft pulsing glow behind everything.
        let glowHue = (t * 0.03).truncatingRemainder(dividingBy: 1)
        let glow = Gradient(colors: [
            Color(hue: glowHue, saturation: 0.9, brightness: 0.5, opacity: 0.35 * level + 0.05),
            .clear
        ])
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(glow, center: CGPoint(x: size.width / 2, y: midY),
                                  startRadius: 0, endRadius: max(size.width, size.height) * 0.6)
        )

        // Mirrored spectrum bars.
        let bandCount = snap.bands.count
        let barWidth = size.width / CGFloat(bandCount)
        for (i, value) in snap.bands.enumerated() {
            let h = CGFloat(value) * size.height * 0.45
            let hue = (Double(i) / Double(bandCount) * 0.8 + t * 0.05).truncatingRemainder(dividingBy: 1)
            let color = Color(hue: hue, saturation: 0.85, brightness: 1, opacity: 0.55)
            let rect = CGRect(x: CGFloat(i) * barWidth + 1, y: midY - h, width: barWidth - 2, height: h * 2)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 3), with: .color(color))
        }

        // Layered waveform ribbons with additive blending for the glow.
        context.blendMode = .plusLighter
        let ribbonCount = 5
        let points = snap.waveform.count
        for r in 0..<ribbonCount {
            let offset = Double(r) / Double(ribbonCount)
            let hue = (t * 0.06 + offset * 0.5).truncatingRemainder(dividingBy: 1)
            var path = Path()
            for i in 0..<points {
                let x = size.width * CGFloat(i) / CGFloat(points - 1)
                let progress = Double(i) / Double(points - 1)
                let swirl = sin(progress * .pi * 2 * (1.5 + offset) + t * (0.8 + offset)) * 0.15
                let amplitude = CGFloat(snap.waveform[i]) * size.height * 1.4
                let y = midY + amplitude * CGFloat(1 - offset * 0.5) + CGFloat(swirl) * size.height * (0.2 + level * 0.5)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            let color = Color(hue: hue, saturation: 0.8, brightness: 1)
            context.stroke(path, with: .color(color.opacity(0.25)), lineWidth: 8 + level * 6)
            context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1.5)
        }
    }
}
