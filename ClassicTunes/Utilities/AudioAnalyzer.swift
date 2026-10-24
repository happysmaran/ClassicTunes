import Foundation
import Accelerate

// Real-time spectrum and waveform analysis fed from the playback audio tap.
//
// The tap calls `analyze` on the audio thread (only while `isActive`); the visualizer
// reads the latest smoothed values from the main thread with `snapshot()`.
final class AudioAnalyzer {
    static let shared = AudioAnalyzer()

    static let bandCount = 48
    static let waveformCount = 128
    private static let fftSize = 1024
    private static let log2Size = vDSP_Length(10)

    // Set by the visualizer view; the tap skips all analysis work while this is false.
    var isActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isActive }
        set { lock.lock(); _isActive = newValue; lock.unlock() }
    }

    struct Snapshot {
        var bands: [Float]
        var waveform: [Float]
        var level: Float
    }

    private let lock = NSLock()
    private var _isActive = false

    // Output, guarded by `lock`.
    private var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var waveform = [Float](repeating: 0, count: AudioAnalyzer.waveformCount)
    private var level: Float = 0

    // Scratch buffers preallocated so the audio thread never allocates.
    private let fftSetup: FFTSetup?
    private var window = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    private var input = [Float](repeating: 0, count: AudioAnalyzer.fftSize)
    private var real = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
    private var imag = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
    private var magnitudes = [Float](repeating: 0, count: AudioAnalyzer.fftSize / 2)
    private var bandEdges: [Int] = []

    private init() {
        fftSetup = vDSP_create_fftsetup(Self.log2Size, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))

        // Log-spaced bin edges from ~40 Hz upward (assuming 44.1 kHz; close enough for display).
        let binCount = Self.fftSize / 2
        let minBin = 2.0, maxBin = Double(binCount - 1)
        bandEdges = (0...Self.bandCount).map { i in
            let t = Double(i) / Double(Self.bandCount)
            return Int(minBin * pow(maxBin / minBin, t))
        }
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(bands: bands, waveform: waveform, level: level)
    }

    // Clears the display, e.g. when playback stops.
    func reset() {
        lock.lock()
        bands = [Float](repeating: 0, count: Self.bandCount)
        waveform = [Float](repeating: 0, count: Self.waveformCount)
        level = 0
        lock.unlock()
    }

    // Analyzes one channel of float samples. Called from the audio thread; never blocks.
    func analyze(_ samples: UnsafePointer<Float>, count: Int, stride: Int) {
        guard let fftSetup, count > 0, lock.try() else { return }
        defer { lock.unlock() }
        guard _isActive else { return }

        let n = Self.fftSize
        let available = min(count, n)
        for i in 0..<available { input[i] = samples[i * stride] }
        if available < n { for i in available..<n { input[i] = 0 } }

        // Waveform: downsample the raw samples and smooth toward the new values.
        let step = max(1, available / Self.waveformCount)
        for i in 0..<Self.waveformCount {
            let value = input[min(i * step, n - 1)]
            waveform[i] = waveform[i] * 0.4 + value * 0.6
        }

        var rms: Float = 0
        vDSP_rmsqv(input, 1, &rms, vDSP_Length(available))
        level = max(rms, level * 0.85)

        vDSP_vmul(input, 1, window, 1, &input, 1, vDSP_Length(n))

        // Real FFT: pack even/odd samples into split complex, transform, take magnitudes.
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                input.withUnsafeBufferPointer { inPtr in
                    inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, Self.log2Size, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        // Group bins into log-spaced bands, convert to a 0...1 dB-scaled height, and apply
        // fast-attack / slow-decay smoothing.
        for b in 0..<Self.bandCount {
            let lo = bandEdges[b]
            let hi = max(lo + 1, bandEdges[b + 1])
            var peak: Float = 0
            for k in lo..<min(hi, n / 2) { peak = max(peak, magnitudes[k]) }
            let db = 20 * log10(max(peak / Float(n), 1e-7))
            let normalized = min(1, max(0, (db + 80) / 70))
            bands[b] = normalized > bands[b] ? normalized : bands[b] * 0.88 + normalized * 0.12
        }
    }
}
