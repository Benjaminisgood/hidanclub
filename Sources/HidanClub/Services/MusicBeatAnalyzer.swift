import Accelerate
import AVFoundation
import Foundation
import HidanCore

enum MusicBeatAnalysisError: LocalizedError {
    case unreadable(String)
    case noAudio

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "无法读取音频：\(detail)"
        case .noAudio: return "文件里没有可分析的音频。"
        }
    }
}

struct MusicBeatAnalysis: Sendable, Equatable {
    let estimate: TempoEstimate
    /// Seconds of audio that fed the envelope, from the start of the file.
    let analyzedSeconds: Double
    let envelopeRate: Double
    let method: String
}

/// Local tempo estimation for imported tracks. The file is streamed through a
/// Hann-windowed STFT; positive log-magnitude differences per hop form the onset
/// envelope (spectral flux) that `TempoEstimator` turns into one BPM. Nothing is
/// uploaded and the file is never rewritten.
enum MusicBeatAnalyzer {
    static let method = "spectral-flux-autocorrelation-v1"
    static let frameSize = 2048
    static let hop = 256
    /// Tempo rarely changes across a dance track; the opening minutes are enough.
    static let maxSeconds = 240.0

    /// CPU-bound and synchronous: call from a detached task. Honors task cancellation.
    static func analyze(url: URL) throws -> MusicBeatAnalysis {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw MusicBeatAnalysisError.unreadable(error.localizedDescription) }
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32 else { throw MusicBeatAnalysisError.noAudio }
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let framesToRead = min(file.length, AVAudioFramePosition(maxSeconds * sampleRate))
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw MusicBeatAnalysisError.noAudio }
        let flux = SpectralFlux(frameSize: frameSize, hop: hop)
        var mono = [Float](repeating: 0, count: Int(chunk))
        var remaining = framesToRead
        while remaining > 0 {
            try Task.checkCancellation()
            buffer.frameLength = 0
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))) }
            catch { throw MusicBeatAnalysisError.unreadable(error.localizedDescription) }
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            remaining -= AVAudioFramePosition(count)
            let length = vDSP_Length(count)
            mono.withUnsafeMutableBufferPointer { out in
                vDSP_vclr(out.baseAddress!, 1, length)
                for channel in 0..<channels { vDSP_vadd(out.baseAddress!, 1, data[channel], 1, out.baseAddress!, 1, length) }
                var scale = 1 / Float(channels)
                vDSP_vsmul(out.baseAddress!, 1, &scale, out.baseAddress!, 1, length)
            }
            flux.append(mono, count: count)
        }
        let analyzed = Double(framesToRead - remaining) / sampleRate
        let envelopeRate = sampleRate / Double(hop)
        let estimate = try TempoEstimator.estimate(onsetEnvelope: flux.envelope, framesPerSecond: envelopeRate)
        return MusicBeatAnalysis(estimate: estimate, analyzedSeconds: analyzed, envelopeRate: envelopeRate, method: method)
    }
}

/// Streaming spectral flux: one envelope value per hop, first frame contributes 0.
private final class SpectralFlux {
    private let frameSize: Int
    private let hop: Int
    private let bins: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var pending: [Float] = []
    private var previous: [Float]
    private var hasPrevious = false
    private var real: [Float]
    private var imaginary: [Float]
    private var windowed: [Float]
    private var magnitudes: [Float]
    private var logMagnitudes: [Float]
    private(set) var envelope: [Double] = []

    init(frameSize: Int, hop: Int) {
        self.frameSize = frameSize
        self.hop = hop
        bins = frameSize / 2
        log2n = vDSP_Length(log2(Double(frameSize)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
        previous = [Float](repeating: 0, count: bins)
        real = previous; imaginary = previous; magnitudes = previous; logMagnitudes = previous
        windowed = [Float](repeating: 0, count: frameSize)
        pending.reserveCapacity(frameSize + 32_768)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func append(_ samples: [Float], count: Int) {
        pending.append(contentsOf: samples[0..<count])
        var start = 0
        while start + frameSize <= pending.count {
            process(from: start)
            start += hop
        }
        if start > 0 { pending.removeFirst(start) }
    }

    private func process(from start: Int) {
        let n = vDSP_Length(frameSize)
        pending.withUnsafeBufferPointer { source in
            window.withUnsafeBufferPointer { w in
                windowed.withUnsafeMutableBufferPointer { out in
                    vDSP_vmul(source.baseAddress! + start, 1, w.baseAddress!, 1, out.baseAddress!, 1, n)
                }
            }
        }
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { source in
                    source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { vDSP_zvabs(&split, 1, $0.baseAddress!, 1, vDSP_Length(bins)) }
            }
        }
        // Element 0 packs DC and Nyquist; neither carries onset information.
        magnitudes[0] = 0
        var scale: Float = 0.5
        magnitudes.withUnsafeMutableBufferPointer { vDSP_vsmul($0.baseAddress!, 1, &scale, $0.baseAddress!, 1, vDSP_Length(bins)) }
        var count = Int32(bins)
        logMagnitudes.withUnsafeMutableBufferPointer { out in
            magnitudes.withUnsafeBufferPointer { vvlog1pf(out.baseAddress!, $0.baseAddress!, &count) }
        }
        if hasPrevious {
            let rise = vDSP.threshold(vDSP.subtract(logMagnitudes, previous), to: 0, with: .zeroFill)
            envelope.append(Double(vDSP.sum(rise)))
        } else {
            envelope.append(0)
            hasPrevious = true
        }
        swap(&previous, &logMagnitudes)
    }
}
