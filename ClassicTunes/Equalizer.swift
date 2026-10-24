import Foundation
import AVFoundation
import MediaToolbox
import Combine

/// A 10-band graphic equalizer applied to `AVPlayer` playback.
///
/// `AVPlayer` has no built-in EQ, so each `AVPlayerItem` gets an
/// `MTAudioProcessingTap` that runs a chain of peaking biquad filters over the
/// decoded audio. Band gains and the enabled flag are persisted in UserDefaults.
final class Equalizer: ObservableObject {
    static let shared = Equalizer()

    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let gainRange: ClosedRange<Double> = -12...12

    struct Preset: Identifiable {
        let name: String
        let gains: [Double]
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Bass Booster", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Bass Reducer", gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Treble Booster", gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 6]),
        Preset(name: "Vocal Booster", gains: [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        Preset(name: "Rock", gains: [5, 4, 2, -1, -2, -1, 2, 4, 5, 5]),
        Preset(name: "Pop", gains: [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
        Preset(name: "Classical", gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
        Preset(name: "Electronic", gains: [5, 4, 1, 0, -2, 2, 1, 1, 4, 5]),
    ]

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "eqEnabled")
            publish()
        }
    }

    @Published var gains: [Double] {
        didSet {
            UserDefaults.standard.set(gains, forKey: "eqGains")
            publish()
        }
    }

    // State shared with the audio thread. Guarded by `lock`; the audio thread only ever try-locks.
    fileprivate let lock = NSLock()
    fileprivate var sharedEnabled = false
    fileprivate var sharedGains = [Double](repeating: 0, count: 10)
    fileprivate var version = 0

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "eqEnabled")
        let saved = UserDefaults.standard.array(forKey: "eqGains") as? [Double]
        gains = (saved?.count == Self.frequencies.count) ? saved! : [Double](repeating: 0, count: Self.frequencies.count)
        publish()
    }

    var currentPreset: Preset? {
        Self.presets.first { $0.gains == gains }
    }

    func apply(_ preset: Preset) {
        gains = preset.gains
    }

    func reset() {
        gains = [Double](repeating: 0, count: Self.frequencies.count)
    }

    private func publish() {
        lock.lock()
        sharedEnabled = isEnabled
        sharedGains = gains
        version += 1
        lock.unlock()
    }

    // MARK: - Attaching to playback

    /// Installs the EQ tap on the item's audio track. Safe to call before the track has loaded.
    func attach(to item: AVPlayerItem) {
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
                  let tap = Self.makeTap() else { return }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            await MainActor.run { item.audioMix = mix }
        }
    }

    private static func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(TapContext()).toOpaque(),
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        return status == noErr ? tap : nil
    }
}

// MARK: - Audio-thread DSP

/// Per-tap filter state: coefficients plus a transposed direct-form II delay line per band and channel.
private final class TapContext {
    struct Coefficients {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    }

    var sampleRate = 44100.0
    var channelCount = 2
    var isInterleaved = false
    var isFloat = true

    var enabled = false
    var gains = [Double](repeating: 0, count: Equalizer.frequencies.count)
    var preamp = 1.0
    var coefficients = [Coefficients](repeating: Coefficients(), count: Equalizer.frequencies.count)
    var state: [Double] = []
    var version = -1

    func resetState() {
        state = [Double](repeating: 0, count: Equalizer.frequencies.count * channelCount * 2)
    }

    /// Pulls the latest settings without ever blocking the audio thread.
    func refresh(from eq: Equalizer) {
        guard eq.lock.try() else { return }
        defer { eq.lock.unlock() }
        guard eq.version != version else { return }
        version = eq.version
        enabled = eq.sharedEnabled
        gains = eq.sharedGains
        // Back off by the largest boost so stacked bands don't clip.
        preamp = pow(10, -max(0, gains.max() ?? 0) / 20)
        for (index, frequency) in Equalizer.frequencies.enumerated() {
            coefficients[index] = Self.peakingFilter(frequency: frequency, gainDB: gains[index], sampleRate: sampleRate)
        }
    }

    /// RBJ peaking-EQ biquad, normalized so a0 == 1. Q of 1.4 gives roughly octave-wide bands.
    static func peakingFilter(frequency: Double, gainDB: Double, sampleRate: Double) -> Coefficients {
        guard gainDB != 0, frequency < sampleRate / 2 else { return Coefficients() }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * 1.4)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha / a
        return Coefficients(
            b0: (1 + alpha * a) / a0,
            b1: (-2 * cosW0) / a0,
            b2: (1 - alpha * a) / a0,
            a1: (-2 * cosW0) / a0,
            a2: (1 - alpha / a) / a0
        )
    }

    /// Filters `count` samples of one channel in place. `stride` is 1 for planar audio, channel count for interleaved.
    func process(_ samples: UnsafeMutablePointer<Float>, count: Int, stride: Int, channel: Int) {
        for band in 0..<coefficients.count where gains[band] != 0 {
            let c = coefficients[band]
            let stateIndex = (band * channelCount + channel) * 2
            var z1 = state[stateIndex]
            var z2 = state[stateIndex + 1]
            for i in 0..<count {
                let x = Double(samples[i * stride])
                let y = c.b0 * x + z1
                z1 = c.b1 * x - c.a1 * y + z2
                z2 = c.b2 * x - c.a2 * y
                samples[i * stride] = Float(y)
            }
            state[stateIndex] = z1
            state[stateIndex + 1] = z2
        }
        if preamp != 1 {
            let gain = Float(preamp)
            for i in 0..<count { samples[i * stride] *= gain }
        }
    }
}

private func tapContext(_ tap: MTAudioProcessingTap) -> TapContext {
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}

private func tapInit(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer?, _ storageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    storageOut.pointee = clientInfo
}

private func tapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func tapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount, _ format: UnsafePointer<AudioStreamBasicDescription>) {
    let context = tapContext(tap)
    let asbd = format.pointee
    context.sampleRate = asbd.mSampleRate
    context.channelCount = max(1, Int(asbd.mChannelsPerFrame))
    context.isInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    context.isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
    context.resetState()
    context.version = -1
}

private func tapUnprepare(_ tap: MTAudioProcessingTap) {}

private func tapProcess(
    _ tap: MTAudioProcessingTap,
    _ frameCount: CMItemCount,
    _ flags: MTAudioProcessingTapFlags,
    _ bufferList: UnsafeMutablePointer<AudioBufferList>,
    _ frameCountOut: UnsafeMutablePointer<CMItemCount>,
    _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    guard MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, frameCountOut) == noErr else { return }

    let context = tapContext(tap)
    context.refresh(from: .shared)
    guard context.isFloat else { return }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    let frames = frameCountOut.pointee

    // Feed the visualizer with the final (post-EQ) signal, first channel only.
    defer {
        if AudioAnalyzer.shared.isActive {
            if context.isInterleaved, let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
                AudioAnalyzer.shared.analyze(data, count: frames, stride: context.channelCount)
            } else if let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
                AudioAnalyzer.shared.analyze(data, count: frames, stride: 1)
            }
        }
    }
    guard context.enabled else { return }

    if context.isInterleaved {
        guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        for channel in 0..<context.channelCount {
            context.process(data + channel, count: frames, stride: context.channelCount, channel: channel)
        }
    } else {
        for (channel, buffer) in buffers.enumerated() where channel < context.channelCount {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            context.process(data, count: frames, stride: 1, channel: channel)
        }
    }
}
