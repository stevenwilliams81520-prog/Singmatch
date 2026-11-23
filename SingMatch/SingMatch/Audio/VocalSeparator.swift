import Foundation
import Accelerate
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings      // Swift Package Manager module name
#elseif canImport(onnxruntime_objc)
import onnxruntime_objc         // CocoaPods module name
#endif

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
    case setupFailed, noOutput
    var errorDescription: String? {
        switch self {
        case .setupFailed: return "Couldn't set up the audio processor."
        case .noOutput: return "The separation model returned no output."
        }
    }
}

/// Runs the MDX-Net vocal model over the whole song in chunks.
final class VocalSeparator {
    private let env: ORTEnv
    private let session: ORTSession
    private let inputName: String
    private let outputName: String
    private let compensate: Float = 1.021

    init(modelURL: URL) throws {
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount))))
        try options.setGraphOptimizationLevel(.all)
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        inputName = (try? session.inputNames().first) ?? "input"
        outputName = (try? session.outputNames().first) ?? "output"
    }

    /// Returns the vocal stem (same length as the input).
    func separate(left: [Float], right: [Float],
                  progress: (Double) -> Void,
                  isCancelled: () -> Bool) throws -> (left: [Float], right: [Float]) {
        guard let spectral = MDXSpectral(),
              let tensorData = NSMutableData(length: MDXSpectral.tensorCount * MemoryLayout<Float>.size) else {
            throw SeparationError.setupFailed
        }
        let n = left.count
        let gen = MDXSpectral.gen, trim = MDXSpectral.trim, chunk = MDXSpectral.chunk
        let total = n % gen == 0 ? n : n + (gen - n % gen)
        let chunks = max(1, total / gen)
        let shape: [NSNumber] = [1, 4, NSNumber(value: MDXSpectral.dimF), NSNumber(value: MDXSpectral.dimT)]

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
                // Chunk covers padded positions start ..< start+chunk, i.e. song samples start-trim ..< start-trim+chunk
                for i in 0..<chunk {
                    let s = start - trim + i
                    if s >= 0 && s < n { chunkL[i] = left[s]; chunkR[i] = right[s] }
                    else { chunkL[i] = 0; chunkR[i] = 0 }
                }
                let tp = tensorData.mutableBytes.assumingMemoryBound(to: Float.self)
                chunkL.withUnsafeBufferPointer { spectral.forward($0.baseAddress!, into: tp, reChannel: 0, imChannel: 1) }
                chunkR.withUnsafeBufferPointer { spectral.forward($0.baseAddress!, into: tp, reChannel: 2, imChannel: 3) }

                let input = try ORTValue(tensorData: tensorData, elementType: .float, shape: shape)
                let outputs = try session.run(withInputs: [inputName: input],
                                              outputNames: [outputName], runOptions: nil)
                guard let value = outputs[outputName] else { throw SeparationError.noOutput }
                let outData = try value.tensorData()
                let op = outData.bytes.assumingMemoryBound(to: Float.self)
                spectral.inverse(op, reChannel: 0, imChannel: 1, into: &outL)
                spectral.inverse(op, reChannel: 2, imChannel: 3, into: &outR)

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
}

/// Finds the separation model: bundled with the app, or downloaded once on first use.
enum ModelProvider {
    static let fileName = "vocals.onnx"
    static let downloadURL = URL(string:
        "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/UVR-MDX-NET-Voc_FT.onnx")!

    static var downloadedURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    static var availableURL: URL? {
        if let b = Bundle.main.url(forResource: "vocals", withExtension: "onnx") { return b }
        let d = downloadedURL
        if let size = (try? FileManager.default.attributesOfItem(atPath: d.path))?[.size] as? NSNumber,
           size.intValue > 50_000_000 { return d }
        return nil
    }

    static func ensureModel(progress: @escaping (Double) -> Void) async throws -> URL {
        if let url = availableURL { return url }
        let downloader = ModelDownloader(destination: downloadedURL, progress: progress)
        return try await downloader.download(from: downloadURL)
    }
}

final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    init(destination: URL, progress: @escaping (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = s
            s.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        session.finishTasksAndInvalidate()
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }
}
