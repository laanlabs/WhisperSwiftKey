import Foundation
import WhisperKit

/// Wraps WhisperKit for on-device speech-to-text
@MainActor
class WhisperService: ObservableObject {
    private var whisperKit: WhisperKit?
    private var realtimeTranscriber: AudioStreamTranscriber?
    private var realtimeTranscriberTask: Task<Void, Never>?
    private var realtimeSessionID = UUID()
    private var realtimeCaptureActive = false
    private var realtimeStartFailure: String?
    private var realtimeVoicedFrames: [Bool] = []

    @Published var isModelLoaded = false
    @Published var isModelAsleep = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var loadingPhase: String = ""
    @Published var currentModelName: String?

    struct ModelInfo: Identifiable {
        var id: String { name }
        let name: String
        let displayName: String
        let sizeBytes: Int64
        let qualityRating: Int
        let speedRating: Int
        let recommended: Bool
    }

    static let availableModels: [ModelInfo] = [
        ModelInfo(name: "openai_whisper-tiny", displayName: "Tiny", sizeBytes: 75_000_000, qualityRating: 2, speedRating: 5, recommended: false),
        ModelInfo(name: "openai_whisper-base", displayName: "Base", sizeBytes: 142_000_000, qualityRating: 3, speedRating: 4, recommended: false),
        ModelInfo(name: "openai_whisper-small", displayName: "Small", sizeBytes: 466_000_000, qualityRating: 3, speedRating: 3, recommended: false),
        ModelInfo(name: "openai_whisper-large-v3-v20240930_626MB", displayName: "Large V3 (Compressed)", sizeBytes: 626_000_000, qualityRating: 5, speedRating: 4, recommended: false),
        ModelInfo(name: "openai_whisper-large-v3-v20240930_turbo", displayName: "Large V3 Turbo", sizeBytes: 800_000_000, qualityRating: 5, speedRating: 5, recommended: true),
    ]

    static let legacyModelAliases = [
        "openai_whisper-large-v3_turbo": "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-large-v3": "openai_whisper-large-v3-v20240930_626MB",
    ]

    static func currentModelName(for storedName: String) -> String {
        legacyModelAliases[storedName] ?? storedName
    }

    // MARK: - Model Storage

    /// Base directory where WhisperKit/HuggingFace stores downloaded models
    var modelStorageURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
    }

    /// Returns the on-disk folder URL for a specific model variant, or nil if not found
    func modelFolderURL(for modelName: String) -> URL? {
        let url = modelStorageURL.appendingPathComponent(modelName)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return nil
    }

    /// Whether a model's files exist on disk
    func isModelDownloaded(_ modelName: String) -> Bool {
        modelFolderURL(for: modelName) != nil
    }

    /// Actual disk usage in bytes for a downloaded model, or nil if not downloaded
    func downloadedModelSize(_ modelName: String) -> Int64? {
        guard let folder = modelFolderURL(for: modelName) else { return nil }
        return Self.directorySize(folder)
    }

    /// Remove a downloaded model from disk
    func deleteModel(_ modelName: String) throws {
        guard let folder = modelFolderURL(for: modelName) else { return }
        // If this is the currently loaded model, unload it
        if currentModelName == modelName {
            whisperKit = nil
            isModelLoaded = false
            isModelAsleep = false
        }
        try FileManager.default.removeItem(at: folder)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Model Loading (split download + init)

    func loadModel(_ modelName: String) async throws {
        print("[WhisperService] Loading model: \(modelName)")
        isDownloading = true
        downloadProgress = 0
        loadingPhase = "Downloading model..."

        do {
            // Phase 1: Download (with progress)
            let modelFolder: String
            if let existingFolder = modelFolderURL(for: modelName) {
                print("[WhisperService] Model already downloaded at: \(existingFolder.path)")
                downloadProgress = 1.0
                modelFolder = existingFolder.path
            } else {
                print("[WhisperService] Downloading model: \(modelName)")
                let downloadedURL = try await WhisperKit.download(
                    variant: modelName,
                    progressCallback: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.downloadProgress = progress.fractionCompleted
                        }
                    }
                )
                downloadProgress = 1.0
                modelFolder = downloadedURL.path
                print("[WhisperService] Download complete: \(modelFolder)")
            }

            // Phase 2: Initialize from local files
            loadingPhase = "Initializing model..."
            let config = WhisperKitConfig(
                modelFolder: modelFolder,
                verbose: true,
                prewarm: true,
                download: false
            )
            whisperKit = try await WhisperKit(config)
            isModelLoaded = true
            currentModelName = modelName
            isDownloading = false
            downloadProgress = 1.0
            loadingPhase = ""
            print("[WhisperService] Model loaded: \(modelName)")
        } catch {
            isDownloading = false
            isModelLoaded = false
            loadingPhase = ""
            print("[WhisperService] Failed to load model: \(error)")
            throw error
        }
    }

    func sleepModel() {
        guard isModelLoaded else { return }
        print("[WhisperService] Sleeping model to reclaim VRAM")
        whisperKit = nil
        isModelLoaded = false
        isModelAsleep = true
    }

    func wakeModel() async throws {
        guard isModelAsleep, let modelName = currentModelName else { return }
        print("[WhisperService] Waking model: \(modelName)")
        isModelAsleep = false
        try await loadModel(modelName)
    }

    /// Ensures a model is loaded and ready, handling all states:
    /// already loaded, asleep, currently downloading, or never loaded.
    func ensureModelLoaded(_ modelName: String) async throws {
        if isModelLoaded, currentModelName == modelName { return }
        if isModelAsleep {
            if currentModelName == modelName {
                try await wakeModel()
                if isModelLoaded { return }
            } else {
                isModelAsleep = false
            }
        }
        // If a download is already in progress (e.g. from app launch), wait for it
        if isDownloading {
            print("[WhisperService] Waiting for in-progress model download...")
            while isDownloading {
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if isModelLoaded { return }
        }
        try await loadModel(modelName)
    }

    func transcribe(
        samples: [Float],
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> String {
        guard let kit = whisperKit else {
            throw WhisperSwiftKeyError.modelNotLoaded
        }

        // Whisper invents closing phrases ("Thank you.", "Bye.") when a window ends in
        // room noise or the key click that stopped the recording. Decode only the stretch
        // that contains speech; WhisperKit pads the rest with digital silence, which the
        // model was trained on and rarely misreads.
        guard let speechSamples = SpeechActivityDetector.trimmedToSpeech(samples) else {
            print("[WhisperService] No sustained speech in \(samples.count) samples, skipping decode")
            return ""
        }
        if speechSamples.count != samples.count {
            print("[WhisperService] Trimmed capture from \(samples.count) to \(speechSamples.count) samples around speech")
        }

        // Build prompt tokens from custom dictionary string
        var promptTokens: [Int]? = nil
        if let prompt = prompt, let tokenizer = kit.tokenizer {
            let encoded = tokenizer.encode(text: prompt)
            if !encoded.isEmpty {
                promptTokens = encoded
            }
        }

        let options = Self.decodingOptions(language: language, promptTokens: promptTokens)
        let results = await kit.transcribe(audioArrays: [speechSamples], decodeOptions: options)

        // Filter segment-by-segment against the audio that was actually decoded, so a
        // hallucinated phrase stamped over a silent stretch is dropped while real speech
        // in the same recording is kept.
        let voicedFrames = SpeechActivityDetector.voicedFrameMask(speechSamples)
        let specialTokenBegin = kit.tokenizer?.specialTokens.specialTokenBegin
        let segmentTexts = results
            .compactMap { $0 }
            .flatMap { $0 }
            .flatMap { $0.segments }
            .compactMap { segment in
                Self.acceptedSegmentText(
                    segment,
                    voicedFrames: voicedFrames,
                    specialTokenBegin: specialTokenBegin,
                    logRejections: true
                )
            }

        let text = segmentTexts
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("[WhisperService] Transcribed: \(text.prefix(100))")
        return text
    }

    private static func decodingOptions(language: String?, promptTokens: [Int]?) -> DecodingOptions {
        DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            promptTokens: promptTokens
        )
    }

    /// The segment's cleaned text, or nil when it is empty or judged a hallucination.
    private static func acceptedSegmentText(
        _ segment: TranscriptionSegment,
        voicedFrames: [Bool],
        specialTokenBegin: Int?,
        logRejections: Bool
    ) -> String? {
        let cleaned = stripWhisperTokens(segment.text)
        guard !cleaned.isEmpty else { return nil }

        let evidence = SpeechActivityDetector.speechEvidence(
            voicedFrames: voicedFrames,
            from: segment.start,
            to: segment.end
        )
        let avgLogprob = segmentAverageLogprob(
            tokenLogProbs: segment.tokenLogProbs,
            specialTokenBegin: specialTokenBegin,
            fallback: segment.avgLogprob
        )
        if isLikelyHallucination(
            text: cleaned,
            noSpeechProb: segment.noSpeechProb,
            avgLogprob: avgLogprob,
            speechEvidence: evidence
        ) {
            if logRejections {
                print("[WhisperService] Dropped likely hallucinated segment \"\(cleaned)\" (\(segment.start)s-\(segment.end)s, speech=\(evidence), avgLogprob=\(avgLogprob), noSpeechProb=\(segment.noSpeechProb))")
            }
            return nil
        }
        return cleaned
    }

    /// Average log probability of a segment's own text tokens. WhisperKit copies the whole
    /// 30-second window's average onto every segment in it, so a hallucinated tail inherits
    /// the confidence of the real speech decoded before it; the per-token values are the
    /// only per-segment confidence signal available.
    static func segmentAverageLogprob(tokenLogProbs: [[Int: Float]], specialTokenBegin: Int?, fallback: Float) -> Float {
        var sum: Float = 0
        var count = 0
        for entry in tokenLogProbs {
            for (token, logprob) in entry {
                if let specialTokenBegin, token >= specialTokenBegin { continue }
                guard logprob.isFinite else { continue }
                sum += logprob
                count += 1
            }
        }
        guard count > 0 else { return fallback }
        return sum / Float(count)
    }

    func startRealtimeTranscription(
        language: String? = nil,
        prompt: String? = nil,
        onTextUpdate: @escaping @MainActor (_ confirmedText: String, _ displayText: String) -> Void
    ) async throws {
        guard let kit = whisperKit else {
            throw WhisperSwiftKeyError.modelNotLoaded
        }
        guard let tokenizer = kit.tokenizer else {
            throw WhisperSwiftKeyError.modelNotLoaded
        }

        await stopRealtimeTranscription()

        kit.audioProcessor.stopRecording()
        kit.audioProcessor.purgeAudioSamples(keepingLast: 0)
        realtimeCaptureActive = false
        realtimeStartFailure = nil
        realtimeVoicedFrames = []

        var promptTokens: [Int]? = nil
        if let prompt, !prompt.isEmpty {
            let encoded = tokenizer.encode(text: prompt)
            if !encoded.isEmpty {
                promptTokens = encoded
            }
        }

        let options = Self.decodingOptions(language: language, promptTokens: promptTokens)
        let specialTokenBegin = tokenizer.specialTokens.specialTokenBegin

        let sessionID = UUID()
        realtimeSessionID = sessionID

        let transcriber = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            decodingOptions: options
        ) { [weak self] oldState, newState in
            guard let self else { return }
            let segmentsChanged = oldState.unconfirmedSegments != newState.unconfirmedSegments ||
                oldState.confirmedSegments != newState.confirmedSegments
            guard oldState.currentText != newState.currentText ||
                    segmentsChanged ||
                    oldState.isRecording != newState.isRecording
            else {
                return
            }

            Task { @MainActor in
                guard self.realtimeSessionID == sessionID else { return }
                self.realtimeCaptureActive = newState.isRecording
                // Segment filtering is grounded in the captured audio. Refresh the voiced
                // frame mask only when the decoder produced new segments; token-by-token
                // hypothesis updates reuse it.
                if segmentsChanged || self.realtimeVoicedFrames.isEmpty {
                    self.realtimeVoicedFrames = SpeechActivityDetector.voicedFrameMask(
                        self.currentRealtimeCapturedSamples() ?? []
                    )
                }
                let (confirmed, display) = Self.realtimeTranscriptTexts(
                    from: newState,
                    voicedFrames: self.realtimeVoicedFrames,
                    specialTokenBegin: specialTokenBegin
                )
                if !display.isEmpty {
                    onTextUpdate(confirmed, display)
                }
            }
        }

        realtimeTranscriber = transcriber
        realtimeTranscriberTask = Task { [weak self] in
            var failure: String?
            do {
                try await transcriber.startStreamTranscription()
            } catch {
                failure = error.localizedDescription
                print("[WhisperService] Realtime transcription failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                guard let self else { return }
                if self.realtimeSessionID == sessionID {
                    self.realtimeCaptureActive = false
                    self.realtimeStartFailure = failure ?? "Microphone recording did not start."
                    self.realtimeTranscriberTask = nil
                }
            }
        }

        // AudioStreamTranscriber starts recording from its long-running task. Do not
        // report success until its state callback confirms that capture is actually live.
        for _ in 0..<50 {
            if realtimeCaptureActive { return }
            if realtimeTranscriberTask == nil {
                throw WhisperSwiftKeyError.realtimeCaptureUnavailable(
                    realtimeStartFailure ?? "Microphone recording did not start."
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        await stopRealtimeTranscription()
        throw WhisperSwiftKeyError.realtimeCaptureUnavailable("Microphone recording timed out while starting.")
    }

    func stopRealtimeTranscription() async {
        let sessionID = UUID()
        realtimeSessionID = sessionID
        realtimeCaptureActive = false
        realtimeVoicedFrames = []

        if let transcriber = realtimeTranscriber {
            await transcriber.stopStreamTranscription()
        }
        realtimeTranscriber = nil
        realtimeTranscriberTask?.cancel()
        realtimeTranscriberTask = nil
    }

    func stopRealtimeTranscriptionAndCaptureSamples() async -> [Float]? {
        await stopRealtimeTranscription()
        return currentRealtimeCapturedSamples()
    }

    func currentRealtimeCapturedSamples() -> [Float]? {
        guard let kit = whisperKit else { return nil }
        let samples = Array(kit.audioProcessor.audioSamples)
        return samples.isEmpty ? nil : samples
    }

    func currentRealtimeContainsSpeech() -> Bool {
        guard let kit = whisperKit else { return false }
        let samples = kit.audioProcessor.audioSamples
        let lookback = min(samples.count, 64_000) // Last four seconds at 16 kHz.
        guard lookback > 0 else { return false }
        return SpeechActivityDetector.containsSpeech(Array(samples.suffix(lookback)))
    }

    /// Returns (confirmedText, displayText).
    /// confirmedText: only stable segments that won't be revised — safe to insert into the document.
    /// displayText: full transcript including unconfirmed/in-progress text — for overlay display only.
    private static func realtimeTranscriptTexts(
        from state: AudioStreamTranscriber.State,
        voicedFrames: [Bool],
        specialTokenBegin: Int?
    ) -> (confirmed: String, display: String) {
        let confirmed = filteredSegmentText(state.confirmedSegments, voicedFrames: voicedFrames, specialTokenBegin: specialTokenBegin)
        let unconfirmedSegmentsText = filteredSegmentText(state.unconfirmedSegments, voicedFrames: voicedFrames, specialTokenBegin: specialTokenBegin)

        let currentText: String
        if state.currentText == "Waiting for speech..." {
            currentText = ""
        } else {
            currentText = state.currentText
        }

        let cleanedConfirmed = stripWhisperTokens(confirmed)
        // currentText is the newest decoder hypothesis while decoding is active;
        // unconfirmedSegments is the completed fallback between decoder passes.
        let newestTail = currentText.isEmpty ? unconfirmedSegmentsText : currentText
        let cleanedDisplay = mergeTranscriptFragments(cleanedConfirmed, newestTail)

        return (cleanedConfirmed, cleanedDisplay)
    }

    /// Joins overlapping streaming hypotheses without repeating their shared words.
    /// For example, "Hey" + "Hey, what's going on" becomes the latter unchanged.
    static func mergeTranscriptFragments(_ prefixText: String, _ suffixText: String) -> String {
        let prefix = stripWhisperTokens(prefixText)
        let suffix = stripWhisperTokens(suffixText)
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }

        let prefixWords = transcriptWords(in: prefix)
        let suffixWords = transcriptWords(in: suffix)
        let maximumOverlap = min(prefixWords.count, suffixWords.count)

        for overlap in stride(from: maximumOverlap, through: 1, by: -1) {
            let prefixOverlap = prefixWords.suffix(overlap).map(\.normalized)
            let suffixOverlap = suffixWords.prefix(overlap).map(\.normalized)
            guard prefixOverlap == suffixOverlap else { continue }

            // The newer hypothesis already contains the entire prefix, so prefer it;
            // it generally has better punctuation than the earlier fragment.
            if overlap == prefixWords.count {
                return suffix
            }

            let lastSharedWord = suffixWords[overlap - 1]
            let suffixRemainder = String(suffix[lastSharedWord.range.upperBound...])
            return (prefix + suffixRemainder).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return prefix + " " + suffix
    }

    private struct TranscriptWord {
        let normalized: String
        let range: Range<String.Index>
    }

    private static func transcriptWords(in text: String) -> [TranscriptWord] {
        guard let expression = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}']+") else {
            return []
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return TranscriptWord(
                normalized: String(text[range]).lowercased(),
                range: range
            )
        }
    }

    private static func filteredSegmentText(
        _ segments: [TranscriptionSegment],
        voicedFrames: [Bool],
        specialTokenBegin: Int?
    ) -> String {
        segments
            .compactMap { segment in
                acceptedSegmentText(
                    segment,
                    voicedFrames: voicedFrames,
                    specialTokenBegin: specialTokenBegin,
                    logRejections: false
                )
            }
            .joined(separator: " ")
    }

    /// Phrases Whisper is known to invent when decoding silence or background
    /// noise, stored in normalized form (lowercased, punctuation removed).
    static let hallucinationPhrases: Set<String> = [
        "you",
        "bye",
        "bye bye",
        "goodbye",
        "the end",
        "thank you",
        "thank you thank you",
        "thanks",
        "thank you for watching",
        "thanks for watching",
        "thank you so much",
        "thank you so much for watching",
        "thank you for listening",
        "thanks for listening",
        "thanks for watching and see you in the next video",
        "see you in the next video",
        "see you next time",
        "see you in the next one",
        "please subscribe",
        "please like and subscribe",
        "don t forget to subscribe",
        "subtitles by the amara org community",
        "subtitles created by the amara org community",
        "www mooji org",
    ]

    /// Decides whether a decoded segment is a silence hallucination rather than
    /// real speech. The microphone is the primary witness: text placed over a span
    /// the capture shows as silent is dropped whatever it says, and a genuinely
    /// spoken "Thank you." over voiced audio is kept. Known ghost phrases are
    /// otherwise only dropped when the segment's own confidence is poor.
    ///
    /// `noSpeechProb` is honored for completeness, but WhisperKit (through v1.1.1)
    /// hard-codes it to 0, so the audio evidence and per-segment log probability
    /// carry the decision today.
    static func isLikelyHallucination(
        text: String,
        noSpeechProb: Float,
        avgLogprob: Float,
        speechEvidence: SpeechActivityDetector.SpeechEvidence
    ) -> Bool {
        let normalized = normalizedTranscriptPhrase(text)
        guard !normalized.isEmpty else { return true }

        // The microphone recorded no speech where the model placed this text.
        if speechEvidence == .absent {
            return true
        }

        // Whisper's own silence heuristic: the model believes the window is
        // non-speech and decoded it with low confidence.
        if noSpeechProb > 0.6 && avgLogprob < -0.35 {
            return true
        }

        if hallucinationPhrases.contains(normalized) && (noSpeechProb > 0.2 || avgLogprob < -0.6) {
            return true
        }

        return false
    }

    /// Lowercases and strips punctuation so "Thank you!" and "thank you." both
    /// normalize to "thank you" for blocklist comparison.
    static func normalizedTranscriptPhrase(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Remove Whisper control tokens like <|startoftranscript|>, <|en|>, <|0.00|>, etc.
    private static func stripWhisperTokens(_ text: String) -> String {
        // Strip well-formed tokens: <|...|>
        var result = text.replacingOccurrences(of: "<\\|[^|>]*\\|>", with: "", options: .regularExpression)
        // Strip partial/broken tokens at end of string (e.g. trailing "<|en" or "<|")
        result = result.replacingOccurrences(of: "<\\|[^>]*$", with: "", options: .regularExpression)
        // Strip any remaining orphaned <| sequences
        result = result.replacingOccurrences(of: "<\\|", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

enum WhisperSwiftKeyError: LocalizedError {
    case modelNotLoaded
    case noAudioCaptured
    case realtimeCaptureUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "No model loaded. Please download a model first."
        case .noAudioCaptured: return "No audio was captured."
        case .realtimeCaptureUnavailable(let message): return message
        }
    }
}
