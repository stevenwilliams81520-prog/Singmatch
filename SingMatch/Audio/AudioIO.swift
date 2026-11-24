import AVFoundation

enum AudioIOError: LocalizedError {
    case unreadable, conversionFailed, tooLong
    var errorDescription: String? {
        switch self {
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
