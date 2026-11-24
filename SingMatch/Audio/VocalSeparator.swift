import Foundation
import Accelerate
import CoreML

/// STFT / iSTFT matching the MDX-Net (UVR-MDX-NET-Voc_FT) training setup:
/// n_fft 7680, hop 1024, 3072 frequency bins, 256 frames per chunk, periodic Hann,
/// centred frames with reflect padding (same as torch.stft(center=True)).
final class MDXSpectral {
    static let nFFT = 7680
    static let hop = 1024
    static let dimF = 3072
    static let dimT = 256
    static let chunk = hop * (dimT - 1)      // 261 120 samples
    static let trim = nFFT / 2               // 3 840
    static let gen = chunk - 2 * trim        // 253 440 useful samples per chunk
    static let tensorCount = 4 * dimF * dimT

    private let n = MDXSpectral.nFFT
    private let window: [Float]
    private let windowSumInv: [Float]          // 1 / overlap-added window², centre region
    private let fwd: vDSP_DFT_Setup
    private let inv: vDSP_DFT_Setup
    private var padded: [Float]
    private var inR: [Float], inI: [Float], outR: [Float], outI: [Float]
    private var ola: [Float]

    init?() {
        let n = MDXSpectral.nFFT
        guard let f = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD),
              let i = vDSP_DFT_zop_CreateSetup(f, vDSP_Length(n), .INVERSE) else { return nil }
        let win: [Float] = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }
        var wsum = [Float](repeating: 0, count: MDXSpectral.chunk + n)
        for t in 0..<MDXSpectral.dimT {
            let o = t * MDXSpectral.hop
            for k in 0..<n { wsum[o + k] += win[k] * win[k] }
        }
        let p = n / 2
        fwd = f; inv = i
        window = win
        windowSumInv = (0..<MDXSpectral.chunk).map { 1 / max(wsum[$0 + p], 1e-8) }
        padded = [Float](repeating: 0, count: MDXSpectral.chunk + n)
        inR = [Float](repeating: 0, count: n); inI = inR; outR = inR; outI = inR
        ola = [Float](repeating: 0, count: MDXSpectral.chunk + n)
    }

    deinit {
        vDSP_DFT_DestroySetup(fwd)
        vDSP_DFT_DestroySetup(inv)
    }

    /// x must hold `chunk` samples. Writes real/imag spectrogram into tensor channels.
    func forward(_ x: UnsafePointer<Float>, into tensor: UnsafeMutablePointer<Float>, reChannel: Int, imChannel: Int) {
        let p = n / 2, len = MDXSpectral.chunk
        let F = MDXSpectral.dimF, T = MDXSpectral.dimT
        // reflect pad
        for i in 0..<p { padded[i] = x[p - i] }
        for i in 0..<len { padded[p + i] = x[i] }
        for j in 0..<p { padded[p + len + j] = x[len - 2 - j] }

        let reBase = reChannel * F * T, imBase = imChannel * F * T
        padded.withUnsafeBufferPointer { pad in
            for t in 0..<T {
                vDSP_vmul(pad.baseAddress! + t * MDXSpectral.hop, 1, window, 1, &inR, 1, vDSP_Length(n))
                vDSP_vclr(&inI, 1, vDSP_Length(n))
                vDSP_DFT_Execute(fwd, inR, inI, &outR, &outI)
                for f in 0..<F {
                    tensor[reBase + f * T + t] = outR[f]
                    tensor[imBase + f * T + t] = outI[f]
                }
            }
        }
    }

    /// Inverse of `forward`; writes `chunk` samples into out.
    func inverse(_ tensor: UnsafePointer<Float>, reChannel: Int, imChannel: Int, into out: inout [Float]) {
        let F = MDXSpectral.dimF, T = MDXSpectral.dimT
        let reBase = reChannel * F * T, imBase = imChannel * F * T
        let half = n / 2
        let scale = 1 / Float(n)
        vDSP_vclr(&ola, 1, vDSP_Length(ola.count))
        for t in 0..<T {
            vDSP_vclr(&inR, 1, vDSP_Length(n))
            vDSP_vclr(&inI, 1, vDSP_Length(n))
            for f in 0..<F {
                inR[f] = tensor[reBase + f * T + t]
                inI[f] = tensor[imBase + f * T + t]
            }
            // Hermitian mirror so the inverse is real
            for k in (half + 1)..<n {
                inR[k] = inR[n - k]
                inI[k] = -inI[n - k]
            }
            vDSP_DFT_Execute(inv, inR, inI, &outR, &outI)
            let o = t * MDXSpectral.hop
            for k in 0..<n { ola[o + k] += outR[k] * scale * window[k] }
        }
        for i in 0..<MDXSpectral.chunk { out[i] = ola[i + half] * windowSumInv[i] }
    }
}

enum SeparationError: LocalizedError {
    case setupFailed, noOutput, modelMissing
    var errorDescription: String? {
        switch self {
        case .setupFailed: return "Couldn't set up the audio processor."
        case .noOutput: return "The separation model returned no output."
        case .modelMissing: return "The vocal separation model is missing from the app."
        }
    }
}

/// Runs the MDX-Net vocal model (Core ML) over the whole song in chunks.
final class VocalSeparator {
    private let model: MLModel
    private let compensate: Float = 1.021

    init(modelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU     // fp32 model: GPU/CPU
        model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    /// Returns the vocal stem (same length as the input).
    func separate(left: [Float], right: [Float],
                  progress: (Double) -> Void,
                  isCancelled: () -> Bool) throws -> (left: [Float], right: [Float]) {
        guard let spectral = MDXSpectral() else { throw SeparationError.setupFailed }
        let F = MDXSpectral.dimF, T = MDXSpectral.dimT
        let count = MDXSpectral.tensorCount
        let tensor = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { tensor.deallocate() }
        let outBuf = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { outBuf.deallocate() }

        let shape: [NSNumber] = [1, 4, NSNumber(value: F), NSNumber(value: T)]
        let strides: [NSNumber] = [NSNumber(value: 4 * F * T), NSNumber(value: F * T), NSNumber(value: T), 1]
        let inputArray = try MLMultiArray(dataPointer: tensor, shape: shape, dataType: .float32,
                                          strides: strides, deallocator: nil)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: inputArray)])

        let n = left.count
        let gen = MDXSpectral.gen, trim = MDXSpectral.trim, chunk = MDXSpectral.chunk
        let total = n % gen == 0 ? n : n + (gen - n % gen)
        let chunks = max(1, total / gen)

        var vocalsL = [Float](repeating: 0, count: n)
        var vocalsR = [Float](repeating: 0, count: n)
        var chunkL = [Float](repeating: 0, count: chunk)
        var chunkR = [Float](repeating: 0, count: chunk)
        var outL = [Float](repeating: 0, count: chunk)
        var outR = [Float](repeating: 0, count: chunk)

        for ci in 0..<chunks {
            if isCancelled() { throw CancellationError() }
            try autoreleasepool {
                let start = ci * gen
                // Chunk covers song samples start-trim ..< start-trim+chunk (zero outside the song)
                for i in 0..<chunk {
                    let s = start - trim + i
                    if s >= 0 && s < n { chunkL[i] = left[s]; chunkR[i] = right[s] }
                    else { chunkL[i] = 0; chunkR[i] = 0 }
                }
                chunkL.withUnsafeBufferPointer { spectral.forward($0.baseAddress!, into: tensor, reChannel: 0, imChannel: 1) }
                chunkR.withUnsafeBufferPointer { spectral.forward($0.baseAddress!, into: tensor, reChannel: 2, imChannel: 3) }

                let result = try model.prediction(from: provider)
                guard let out = result.featureValue(for: "output")?.multiArrayValue else {
                    throw SeparationError.noOutput
                }
                try Self.copyContiguous(out, into: outBuf, shape: [4, F, T])
                spectral.inverse(outBuf, reChannel: 0, imChannel: 1, into: &outL)
                spectral.inverse(outBuf, reChannel: 2, imChannel: 3, into: &outR)

                for i in 0..<gen {
                    let s = start + i
                    if s >= n { break }
                    vocalsL[s] = outL[trim + i] * compensate
                    vocalsR[s] = outR[trim + i] * compensate
                }
            }
            progress(Double(ci + 1) / Double(chunks))
        }
        return (vocalsL, vocalsR)
    }

    /// Copies a [1,4,F,T] MLMultiArray into a packed float buffer, honouring its strides
    /// (Core ML may pad rows) and converting from float16/double if needed.
    private static func copyContiguous(_ a: MLMultiArray, into dst: UnsafeMutablePointer<Float>, shape: [Int]) throws {
        let st = a.strides.map(\.intValue)
        guard st.count == 4 else { throw SeparationError.noOutput }
        let (C, F, T) = (shape[0], shape[1], shape[2])
        let packed = st[3] == 1 && st[2] == T && st[1] == F * T
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: 1)
            if packed { dst.update(from: p, count: C * F * T); return }
            for c in 0..<C { for f in 0..<F { for t in 0..<T {
                dst[c * F * T + f * T + t] = p[c * st[1] + f * st[2] + t * st[3]]
            } } }
        case .double:
            let p = a.dataPointer.bindMemory(to: Double.self, capacity: 1)
            for c in 0..<C { for f in 0..<F { for t in 0..<T {
                dst[c * F * T + f * T + t] = Float(p[c * st[1] + f * st[2] + t * st[3]])
            } } }
        default:
            // float16 or other: go through the NSNumber accessor (slow, but correct)
            for c in 0..<C { for f in 0..<F { for t in 0..<T {
                dst[c * F * T + f * T + t] = a[[0, c, f, t] as [NSNumber]].floatValue
            } } }
        }
    }
}

/// The Core ML model is compiled at build time and bundled with the app.
enum ModelProvider {
    static var bundledURL: URL? {
        Bundle.main.url(forResource: "VocalsModel", withExtension: "mlmodelc")
    }

    static func ensureModel() throws -> URL {
        guard let url = bundledURL else { throw SeparationError.modelMissing }
        return url
    }
}
