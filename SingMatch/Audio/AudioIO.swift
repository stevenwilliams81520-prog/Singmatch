import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

enum AudioIOError: LocalizedError {
    case unreadable, conversionFailed, tooLong, noAudioTrack
    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "That video doesn't have any sound to use."
        case .unreadable: return "That file couldn't be opened as audio."
        case .conversionFailed: return "The audio couldn't be converted."
        case .tooLong: return "Songs longer than 10 minutes aren't supported."
        }
    }
}

enum AudioIO {
    static let sampleRate: Double = 44100
    static let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 44100, channels: 2, interleaved: false)!

    /// Decodes an audio OR video file. Video files (mp4, mov, m4v…) have their soundtrack extracted.
    static func decodeAny(url: URL) async throws -> (left: [Float], right: [Float]) {
        let isVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
        if !isVideo {
            do { return try decode(url: url) }
            catch AudioIOError.tooLong { throw AudioIOError.tooLong }
            catch { /* fall through: let AVFoundation's media reader try */ }
        }
        return try await decodeMedia(url: url)
    }

    /// Reads the first audio track of any media file (including videos) as 44.1 kHz stereo float.
    static func decodeMedia(url: URL) async throws -> (left: [Float], right: [Float]) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioIOError.noAudioTrack
        }
        let seconds = try await asset.load(.duration).seconds
        if seconds.isFinite && seconds > 600 { throw AudioIOError.tooLong }

        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: layoutData,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioIOError.conversionFailed }
        reader.add(output)
        guard reader.startReading() else {
            if let e = reader.error { throw e }
            throw AudioIOError.conversionFailed
        }

        let expected = seconds.isFinite ? Int(seconds * sampleRate) + 4096 : 0
        var left = [Float](); left.reserveCapacity(expected)
        var right = [Float](); right.reserveCapacity(expected)
        var scratch = [Float]()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
            let status = scratch.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                           destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            let frames = count / 2
            for i in 0..<frames {
                left.append(scratch[2 * i])
                right.append(scratch[2 * i + 1])
            }
        }
        if reader.status == .failed {
            if let e = reader.error { throw e }
            throw AudioIOError.conversionFailed
        }
        if left.isEmpty { throw AudioIOError.noAudioTrack }
        return (left, right)
    }

    /// Decodes any file AVFoundation can read (mp3, m4a, aac, wav, aiff, caf, flac…)
    /// into 44.1 kHz stereo float arrays.
    static func decode(url: URL) throws -> (left: [Float], right: [Float]) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioIOError.unreadable }
        let inFormat = file.processingFormat
        let seconds = Double(file.length) / inFormat.sampleRate
        if seconds > 600 { throw AudioIOError.tooLong }

        guard let converter = AVAudioConverter(from: inFormat, to: stereoFormat) else {
            throw AudioIOError.conversionFailed
        }
        if inFormat.channelCount == 1 { converter.channelMap = [0, 0] }

        let expected = Int(seconds * sampleRate) + 4096
        var left = [Float](); left.reserveCapacity(expected)
        var right = [Float](); right.reserveCapacity(expected)

        let blockSize: AVAudioFrameCount = 32768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: blockSize) else {
            throw AudioIOError.conversionFailed
        }
        final class EndFlag { var value = false }
        let end = EndFlag()

        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: blockSize) else {
                throw AudioIOError.conversionFailed
            }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if end.value { outStatus.pointee = .endOfStream; return nil }
                do { try file.read(into: inBuf, frameCount: blockSize) } catch {
                    end.value = true; outStatus.pointee = .endOfStream; return nil
                }
                if inBuf.frameLength == 0 {
                    end.value = true; outStatus.pointee = .endOfStream; return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if status == .error { throw convError ?? AudioIOError.conversionFailed }
            let n = Int(outBuf.frameLength)
            if n > 0, let ch = outBuf.floatChannelData {
                left.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                right.append(contentsOf: UnsafeBufferPointer(start: ch[1], count: n))
            }
            if status == .endOfStream || (n == 0 && end.value) { break }
        }
        if left.isEmpty { throw AudioIOError.unreadable }
        return (left, right)
    }

    /// Writes stereo float audio as AAC (.m4a).
    static func writeM4A(left: [Float], right: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        // Scope the file so it is closed (finalised) when this function returns.
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = left.count
        let block = 32768
        var pos = 0
        while pos < n {
            let len = min(block, n - pos)
            guard let buf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(len)),
                  let ch = buf.floatChannelData else { throw AudioIOError.conversionFailed }
            buf.frameLength = AVAudioFrameCount(len)
            for i in 0..<len {
                ch[0][i] = max(-1, min(1, left[pos + i]))
                ch[1][i] = max(-1, min(1, right[pos + i]))
            }
            try file.write(from: buf)
            pos += len
        }
    }
}
