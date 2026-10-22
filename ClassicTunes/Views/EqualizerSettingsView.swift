import SwiftUI

// The "Equalizer" tab of the Settings window: an on/off toggle, a preset menu,
// and ten vertical band sliders from 32 Hz to 16 kHz (±12 dB each).
struct EqualizerSettingsView: View {
    @ObservedObject private var equalizer = Equalizer.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable Equalizer", isOn: $equalizer.isEnabled)

                Picker("Preset", selection: presetBinding) {
                    if equalizer.currentPreset == nil {
                        Text("Custom").tag("Custom")
                    }
                    ForEach(Equalizer.presets) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
            }

            Section {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Equalizer.frequencies.indices, id: \.self) { index in
                        bandSlider(index)
                    }
                }
                .frame(maxWidth: .infinity)
                .disabled(!equalizer.isEnabled)
                .opacity(equalizer.isEnabled ? 1 : 0.5)

                HStack {
                    Text("Drag a slider to adjust that frequency band (-12 to +12 dB).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { equalizer.reset() }
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }

    // Maps the preset picker to the equalizer's gains.
    private var presetBinding: Binding<String> {
        Binding(
            get: { equalizer.currentPreset?.name ?? "Custom" },
            set: { name in
                if let preset = Equalizer.presets.first(where: { $0.name == name }) {
                    equalizer.apply(preset)
                }
            }
        )
    }

    // One vertical slider with its dB readout above and frequency label below.
    private func bandSlider(_ index: Int) -> some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.0f", equalizer.gains[index]))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            VerticalSlider(value: $equalizer.gains[index], range: Equalizer.gainRange)
                .frame(width: 24, height: 130)

            Text(frequencyLabel(Equalizer.frequencies[index]))
                .font(.system(size: 10))
        }
        .frame(maxWidth: .infinity)
    }

    private func frequencyLabel(_ hz: Double) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }
}

// A vertical slider driven by a drag gesture. A rotated `Slider` can't be used on
// macOS because the underlying NSSlider still tracks the mouse horizontally.
private struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private let thumbSize: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.height - thumbSize, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            // Top of the track is the maximum value.
            let thumbCenterY = thumbSize / 2 + travel * (1 - fraction)

            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity)

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: thumbSize, height: thumbSize)
                    .position(x: proxy.size.width / 2, y: thumbCenterY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { drag in
                        let clamped = min(max(drag.location.y - thumbSize / 2, 0), travel)
                        let newFraction = 1 - clamped / travel
                        value = range.lowerBound + newFraction * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }
}
