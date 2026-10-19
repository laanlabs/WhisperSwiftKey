import AVFoundation
import Foundation

/// Handles microphone capture and returns raw Float samples at 16kHz for WhisperKit
class AudioService {
    private var audioEngine: AVAudioEngine?
    private var collectedSamples: [Float] = []
    private var isRecording = false
    private let sampleLock = NSLock()
    
    func startRecording() {
        sampleLock.lock()
        collectedSamples.removeAll(keepingCapacity: true)
        isRecording = false
        sampleLock.unlock()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        
        // WhisperKit needs 16kHz mono
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            print("[AudioService] Failed to create 16kHz format")
            return
        }
        
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            print("[AudioService] Failed to create audio converter")
            return
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            let frameCount = AVAudioFrameCount(targetFormat.sampleRate * Double(buffer.frameLength) / nativeFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
            
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            if status == .haveData, let channelData = convertedBuffer.floatChannelData?[0] {
                let count = Int(convertedBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
                self.sampleLock.lock()
                if self.isRecording {
                    self.collectedSamples.append(contentsOf: samples)
                }
                self.sampleLock.unlock()
            }
        }
        
        do {
            try engine.start()
            audioEngine = engine
            sampleLock.lock()
            isRecording = true
            sampleLock.unlock()
            print("[AudioService] Recording started (16kHz mono)")
        } catch {
            print("[AudioService] Failed to start: \(error)")
        }
    }
    
    /// Stop recording and return raw 16kHz Float samples for WhisperKit
    func stopRecording() -> [Float]? {
        sampleLock.lock()
        let wasRecording = isRecording
        isRecording = false
        sampleLock.unlock()

        guard let engine = audioEngine, wasRecording else { return nil }
        
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil

        sampleLock.lock()
        let samples = collectedSamples
        collectedSamples.removeAll(keepingCapacity: true)
        sampleLock.unlock()
        
        let duration = Double(samples.count) / 16000.0
        print("[AudioService] Captured \(samples.count) samples (\(String(format: "%.1f", duration))s)")
        
        return samples.isEmpty ? nil : samples
    }

    func currentSamplesSnapshot() -> [Float] {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return collectedSamples
    }

    var currentSampleCount: Int {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return collectedSamples.count
    }

    var recordingActive: Bool {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return isRecording
    }
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }
}

/// Lightweight speech gate used before decoding. It adapts to the current microphone's
/// noise floor instead of treating common words as hallucinations.
///
/// Whisper invents closing phrases such as "Thank you." when a window ends in room noise
/// or the key click that stopped the recording, and WhisperKit never populates the
/// no-speech probability that would normally flag those segments. The detector therefore
/// also answers two audio-grounded questions: where does the speech in a capture start
/// and end, and did the microphone record speech inside a decoded segment's time span.
enum SpeechActivityDetector {
    static let sampleRate = 16_000
    static let frameSize = 320 // 20 ms at Whisper's 16 kHz sample rate

    /// Frames above the threshold needed before audio counts as speech (~80 ms), so
    /// clicks and pops are ignored.
    private static let minimumVoicedFrames = 4
    /// Consecutive voiced frames needed before a region anchors the speech bounds. Even
    /// short words last this long (~80 ms); a key click or pop rarely does.
    private static let minimumRunFrames = 4
    /// Audio kept ahead of the first voiced run so word onsets survive trimming.
    static let leadingMarginSamples = 4_800 // 300 ms
    /// Audio kept after the last voiced run so trailing consonants survive trimming.
    static let trailingMarginSamples = 8_000 // 500 ms
    /// WhisperKit decodes nothing from a clip shorter than its one-second window padding,
    /// so trimmed speech is extended with digital silence to at least this length.
    static let minimumDecodeSamples = 24_000 // 1.5 s

    enum SpeechEvidence: Equatable {
        /// The microphone recorded sustained energy inside the span.
        case present
        /// The span is silent, lies past the end of the captured audio, or holds only clicks.
        case absent
        /// No audio was available, or the span is malformed, so it cannot be judged.
        case unknown
    }

    static func containsSpeech(_ samples: [Float]) -> Bool {
        voicedFrameMask(samples).filter { $0 }.count >= minimumVoicedFrames
    }

    /// RMS energy of each 20 ms frame.
    static func frameEnergies(_ samples: [Float]) -> [Float] {
        var energies: [Float] = []
        energies.reserveCapacity(samples.count / frameSize)

        var offset = 0
        while offset + frameSize <= samples.count {
            var sumSquares: Float = 0
            for sample in samples[offset..<(offset + frameSize)] {
                sumSquares += sample * sample
            }
            energies.append(sqrt(sumSquares / Float(frameSize)))
            offset += frameSize
        }
        return energies
    }

    /// Marks each 20 ms frame as voiced or not, relative to this capture's own noise floor.
    static func voicedFrameMask(_ samples: [Float]) -> [Bool] {
        let energies = frameEnergies(samples)
        guard energies.count >= minimumVoicedFrames else {
            return Array(repeating: false, count: energies.count)
        }
        let threshold = voicedThreshold(forFrameEnergies: energies)
        return energies.map { $0 >= threshold }
    }

    /// The quietest fifth of the capture estimates the noise floor; voiced audio must rise
    /// well above it. The result never drops below the level of digital silence and never
    /// rises above an absolute floor, because a sustained voice can occupy the whole
    /// capture and push the local noise estimate as high as the speech itself.
    private static func voicedThreshold(forFrameEnergies energies: [Float]) -> Float {
        let sorted = energies.sorted()
        let noiseFloor = sorted[min(sorted.count - 1, max(0, sorted.count / 5))]
        return min(max(0.0025, noiseFloor * 3), 0.006)
    }

    /// The sample range from the start of the first sustained voiced run to the end of the
    /// last one, or nil when the capture never contains one. Isolated loud frames such as
    /// the Fn key click at the end of a recording do not extend the range.
    static func speechBounds(in samples: [Float]) -> Range<Int>? {
        let mask = voicedFrameMask(samples)
        var firstRunStart: Int?
        var lastRunEnd: Int?
        var runLength = 0

        for (frame, voiced) in mask.enumerated() {
            guard voiced else {
                runLength = 0
                continue
            }
            runLength += 1
            guard runLength >= minimumRunFrames else { continue }
            if firstRunStart == nil {
                firstRunStart = frame - runLength + 1
            }
            lastRunEnd = frame + 1
        }

        guard let firstRunStart, let lastRunEnd else { return nil }
        return (firstRunStart * frameSize)..<min(samples.count, lastRunEnd * frameSize)
    }

    /// The capture reduced to its speech plus short margins, extended with digital silence
    /// when the result is too short for WhisperKit to decode. Returns nil when the capture
    /// contains no sustained speech.
    static func trimmedToSpeech(_ samples: [Float]) -> [Float]? {
        guard let bounds = speechBounds(in: samples) else { return nil }
        let start = max(0, bounds.lowerBound - leadingMarginSamples)
        let end = min(samples.count, bounds.upperBound + trailingMarginSamples)
        var trimmed = Array(samples[start..<end])
        if trimmed.count < minimumDecodeSamples {
            trimmed.append(contentsOf: repeatElement(0, count: minimumDecodeSamples - trimmed.count))
        }
        return trimmed
    }

    /// Whether the microphone recorded speech between two timestamps of the audio that
    /// produced `voicedFrames`. A span that starts past the end of that audio is one Whisper
    /// stamped into the zero padding after the recording, so it counts as absent.
    static func speechEvidence(voicedFrames: [Bool], from startSeconds: Float, to endSeconds: Float) -> SpeechEvidence {
        guard !voicedFrames.isEmpty, startSeconds.isFinite, endSeconds.isFinite else { return .unknown }

        let framesPerSecond = Float(sampleRate) / Float(frameSize)
        let audioSeconds = Float(voicedFrames.count) / framesPerSecond
        guard startSeconds < audioSeconds else { return .absent }
        guard endSeconds > startSeconds else { return .unknown }

        let firstFrame = max(0, Int((startSeconds * framesPerSecond).rounded(.down)))
        let endFrame = min(voicedFrames.count, Int((min(endSeconds, audioSeconds) * framesPerSecond).rounded(.up)))
        guard firstFrame < endFrame else { return .absent }

        let voicedCount = voicedFrames[firstFrame..<endFrame].filter { $0 }.count
        return voicedCount >= minimumVoicedFrames ? .present : .absent
    }

    /// Picks a sample index at which a long capture can be split without cutting
    /// through a word: the middle of the quietest 300 ms window inside the
    /// trailing `searchWindow` samples. Falls back to the end of the buffer.
    static func quietestCutIndex(in samples: [Float], searchingLast searchWindow: Int) -> Int {
        let windowSize = 4_800 // 300 ms at 16 kHz
        let hop = windowSize / 2
        guard samples.count > windowSize else { return samples.count }

        let searchStart = max(0, samples.count - max(searchWindow, windowSize))
        var bestIndex = samples.count
        var bestEnergy = Float.greatestFiniteMagnitude

        var offset = searchStart
        while offset + windowSize <= samples.count {
            var sumSquares: Float = 0
            for sample in samples[offset..<(offset + windowSize)] {
                sumSquares += sample * sample
            }
            if sumSquares < bestEnergy {
                bestEnergy = sumSquares
                bestIndex = offset + windowSize / 2
            }
            offset += hop
        }
        return bestIndex
    }
}
