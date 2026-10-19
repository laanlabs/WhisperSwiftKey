import AppKit
import ApplicationServices
import Foundation
import XCTest
@testable import WhisperSwiftKey

final class DictationRegressionTests: XCTestCase {
    @MainActor
    func testLivePreviewAtomicallyReplacesTheWholeHypothesis() {
        let defaults = UserDefaults(suiteName: "DictationRegressionTests.\(UUID().uuidString)")!
        let insertionSpy = TextInsertionSpy()
        let appState = AppState(textInsertionService: insertionSpy, defaults: defaults)

        appState.updateLiveDictationPreview("Hey")
        appState.updateLiveDictationPreview("Hey, what's going on now?")

        XCTAssertEqual(insertionSpy.provisionalUpdates, ["Hey", "Hey, what's going on now?"])
        XCTAssertTrue(insertionSpy.regularInsertions.isEmpty)
    }

    @MainActor
    func testLivePreviewStopsAXUpdatesAfterTheEditorRejectsOne() {
        let defaults = UserDefaults(suiteName: "DictationRegressionTests.\(UUID().uuidString)")!
        let insertionSpy = TextInsertionSpy()
        insertionSpy.updateResult = false
        let appState = AppState(textInsertionService: insertionSpy, defaults: defaults)

        appState.updateLiveDictationPreview("Hey")
        appState.updateLiveDictationPreview("Hey, what's going on now?")

        XCTAssertEqual(insertionSpy.provisionalUpdates, ["Hey"])
    }

    @MainActor
    func testFinalTextUsesNormalInsertionWhenNoProvisionalTextExists() {
        let defaults = UserDefaults(suiteName: "DictationRegressionTests.\(UUID().uuidString)")!
        let insertionSpy = TextInsertionSpy()
        insertionSpy.commitResult = .needsFallbackInsertion
        let appState = AppState(textInsertionService: insertionSpy, defaults: defaults)

        appState.finalizeTextInsertion("Hey, what's going on now?")

        XCTAssertEqual(insertionSpy.regularInsertions, ["Hey, what's going on now?"])
    }

    @MainActor
    func testFinalTextDoesNotBlindlyPasteOverUnresolvedProvisionalText() {
        let defaults = UserDefaults(suiteName: "DictationRegressionTests.\(UUID().uuidString)")!
        let insertionSpy = TextInsertionSpy()
        insertionSpy.commitResult = .provisionalTextPreserved
        let appState = AppState(textInsertionService: insertionSpy, defaults: defaults)

        appState.finalizeTextInsertion("Hey, what's going on now?")

        XCTAssertTrue(insertionSpy.regularInsertions.isEmpty)
    }

    func testStreamingFragmentsDoNotRepeatConfirmedPrefix() async {
        let merged = await WhisperService.mergeTranscriptFragments(
            "Hey",
            "Hey, what's going on now?"
        )
        XCTAssertEqual(merged, "Hey, what's going on now?")
    }

    func testMinimalStreamingReplacementAppendsAtTheExistingCaret() {
        let delta = TextInsertionService.minimalReplacement(
            from: "What time is",
            to: "What time is it?"
        )

        XCTAssertEqual(delta.range, NSRange(location: 12, length: 0))
        XCTAssertEqual(delta.replacement, " it?")
    }

    func testMinimalStreamingReplacementIsolatesARevision() {
        let delta = TextInsertionService.minimalReplacement(
            from: "Hello world",
            to: "Hallo world"
        )

        XCTAssertEqual(delta.range, NSRange(location: 1, length: 1))
        XCTAssertEqual(delta.replacement, "a")
    }

    func testFinalizationGateAcceptsOnlyOneResultPerRecording() {
        let sessionID = UUID()
        var gate = DictationFinalizationGate()

        XCTAssertTrue(gate.begin(sessionID: sessionID))
        XCTAssertFalse(gate.begin(sessionID: sessionID))
        XCTAssertTrue(gate.consume(sessionID: sessionID))
        XCTAssertFalse(gate.consume(sessionID: sessionID))
    }

    func testSpeechGateRejectsSilence() {
        XCTAssertFalse(SpeechActivityDetector.containsSpeech(Array(repeating: 0, count: 16_000)))
    }

    func testSpeechGateAcceptsVoicedAudio() {
        let samples = (0..<16_000).map { index in
            0.05 * sin(2 * .pi * 220 * Double(index) / 16_000)
        }

        XCTAssertTrue(SpeechActivityDetector.containsSpeech(samples.map(Float.init)))
    }

    func testSpeechGateDoesNotRequireAFullSecondOfSpeech() {
        let samples = (0..<1_600).map { index in
            0.05 * sin(2 * .pi * 220 * Double(index) / 16_000)
        }

        XCTAssertTrue(SpeechActivityDetector.containsSpeech(samples.map(Float.init)))
    }

    func testBrowsersAndTerminalsUseClipboardOnlyInsertion() {
        XCTAssertTrue(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.google.Chrome"))
        XCTAssertTrue(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.google.Chrome.beta"))
        XCTAssertTrue(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.apple.Safari"))
        XCTAssertTrue(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "org.mozilla.firefox"))
        XCTAssertTrue(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.apple.Terminal"))
        XCTAssertFalse(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(TextInsertionService.usesClipboardOnlyInsertion(bundleID: "com.apple.Notes"))
    }

    // MARK: - Hallucination filtering
    //
    // WhisperKit hard-codes `noSpeechProb` to 0 and copies the whole window's
    // `avgLogprob` onto every segment, so a trailing "Thank you." inherits the
    // confidence of the real speech before it. The app therefore grounds its
    // filtering in the captured audio, which these tests exercise.

    func testSpeechBoundsIgnoreTheKeyClickThatStoppedTheRecording() {
        var samples = Array(repeating: Float(0), count: 8_000) // 0.5 s lead-in
        samples += tone(seconds: 2.0)
        samples += noise(seconds: 1.5)
        samples += Array(repeating: Float(0.05), count: 320) // 20 ms key click
        samples += noise(seconds: 0.3)

        guard let bounds = SpeechActivityDetector.speechBounds(in: samples) else {
            return XCTFail("Expected speech bounds")
        }
        XCTAssertEqual(bounds.lowerBound, 8_000, accuracy: 640)
        XCTAssertEqual(bounds.upperBound, 8_000 + 32_000, accuracy: 640)
    }

    func testTrimmingKeepsMarginsAroundSpeechAndDropsTheNoisyTail() {
        var samples = Array(repeating: Float(0), count: 16_000) // 1 s lead-in
        samples += tone(seconds: 2.0)
        samples += noise(seconds: 2.0)
        samples += Array(repeating: Float(0.05), count: 320) // key click

        guard let trimmed = SpeechActivityDetector.trimmedToSpeech(samples) else {
            return XCTFail("Expected trimmed speech")
        }
        let expected = SpeechActivityDetector.leadingMarginSamples + 32_000 + SpeechActivityDetector.trailingMarginSamples
        XCTAssertEqual(trimmed.count, expected, accuracy: 640)
        // The click sat two seconds after the speech ended and must be gone.
        XCTAssertFalse(trimmed.suffix(8_000).contains { abs($0) >= 0.04 })
    }

    func testVeryShortUtterancesArePaddedToADecodableLength() {
        guard let trimmed = SpeechActivityDetector.trimmedToSpeech(tone(seconds: 0.3)) else {
            return XCTFail("Expected trimmed speech")
        }
        XCTAssertGreaterThanOrEqual(trimmed.count, SpeechActivityDetector.minimumDecodeSamples)
        XCTAssertTrue(trimmed.suffix(8_000).allSatisfy { $0 == 0 })
    }

    func testTrimmingReturnsNothingWithoutSustainedSpeech() {
        var samples = noise(seconds: 2.0)
        samples += Array(repeating: Float(0.05), count: 640) // 40 ms pop
        samples += noise(seconds: 0.5)

        XCTAssertNil(SpeechActivityDetector.trimmedToSpeech(samples))
    }

    func testSegmentSpanOverSilentTailHasNoSpeechEvidence() {
        var samples = tone(seconds: 2.0)
        samples += Array(repeating: Float(0), count: 16_000)
        let voiced = SpeechActivityDetector.voicedFrameMask(samples)

        XCTAssertEqual(SpeechActivityDetector.speechEvidence(voicedFrames: voiced, from: 0.5, to: 1.5), .present)
        XCTAssertEqual(SpeechActivityDetector.speechEvidence(voicedFrames: voiced, from: 2.1, to: 3.0), .absent)
        // Whisper often stamps a hallucinated tail into the zero padding past the recording.
        XCTAssertEqual(SpeechActivityDetector.speechEvidence(voicedFrames: voiced, from: 4.0, to: 6.5), .absent)
        // A malformed span cannot be judged either way.
        XCTAssertEqual(SpeechActivityDetector.speechEvidence(voicedFrames: voiced, from: 1.0, to: 1.0), .unknown)
        XCTAssertEqual(SpeechActivityDetector.speechEvidence(voicedFrames: [], from: 0, to: 1), .unknown)
    }

    func testTextTheMicrophoneContradictsIsFilteredWhateverItSays() async {
        // Healthy confidence is exactly what a hallucinated tail inherits from the
        // real speech decoded before it, so it must not rescue the segment.
        let thankYou = await WhisperService.isLikelyHallucination(
            text: "Thank you.",
            noSpeechProb: 0,
            avgLogprob: -0.2,
            speechEvidence: .absent
        )
        XCTAssertTrue(thankYou)

        let unlistedPhrase = await WhisperService.isLikelyHallucination(
            text: "See you tomorrow.",
            noSpeechProb: 0,
            avgLogprob: -0.2,
            speechEvidence: .absent
        )
        XCTAssertTrue(unlistedPhrase)
    }

    func testGenuinelySpokenThankYouIsKept() async {
        let filtered = await WhisperService.isLikelyHallucination(
            text: "Thank you.",
            noSpeechProb: 0,
            avgLogprob: -0.2,
            speechEvidence: .present
        )
        XCTAssertFalse(filtered)
    }

    func testKnownGhostPhraseWithPoorConfidenceIsFilteredWithoutAudio() async {
        let filtered = await WhisperService.isLikelyHallucination(
            text: "Thanks for watching!",
            noSpeechProb: 0,
            avgLogprob: -0.8,
            speechEvidence: .unknown
        )
        XCTAssertTrue(filtered)
    }

    func testFutureNoSpeechProbabilityStillFiltersLowConfidenceSegments() async {
        // WhisperKit reports 0 today; keep honoring the value for when it is implemented.
        let filtered = await WhisperService.isLikelyHallucination(
            text: "The quick brown fox",
            noSpeechProb: 0.8,
            avgLogprob: -0.9,
            speechEvidence: .unknown
        )
        XCTAssertTrue(filtered)
    }

    func testNormalDictationIsNotFiltered() async {
        let filtered = await WhisperService.isLikelyHallucination(
            text: "Please send the report by Friday.",
            noSpeechProb: 0,
            avgLogprob: -0.25,
            speechEvidence: .unknown
        )
        XCTAssertFalse(filtered)
    }

    func testSegmentConfidenceAveragesOnlyItsOwnTextTokens() async {
        let logprobs: [[Int: Float]] = [[50_258: -0.05], [1_000: -0.5], [2_000: -1.5], [50_364: -0.01]]
        let average = await WhisperService.segmentAverageLogprob(
            tokenLogProbs: logprobs,
            specialTokenBegin: 50_257,
            fallback: -0.1
        )
        XCTAssertEqual(average, -1.0, accuracy: 0.001)

        let fallback = await WhisperService.segmentAverageLogprob(
            tokenLogProbs: [[50_258: -0.05]],
            specialTokenBegin: 50_257,
            fallback: -0.3
        )
        XCTAssertEqual(fallback, -0.3, accuracy: 0.001)
    }

    func testPhraseNormalizationIgnoresCaseAndPunctuation() async {
        let normalized = await WhisperService.normalizedTranscriptPhrase(" Thanks for watching! ")
        XCTAssertEqual(normalized, "thanks for watching")
        let phrases = await WhisperService.hallucinationPhrases
        XCTAssertTrue(phrases.contains(normalized))
    }

    /// A 220 Hz tone standing in for voiced speech.
    private func tone(seconds: Double, amplitude: Double = 0.05) -> [Float] {
        (0..<Int(seconds * 16_000)).map { index in
            Float(amplitude * sin(2 * .pi * 220 * Double(index) / 16_000))
        }
    }

    /// Deterministic low-level room noise.
    private func noise(seconds: Double, amplitude: Float = 0.001) -> [Float] {
        var state: UInt32 = 0x1234_5678
        return (0..<Int(seconds * 16_000)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state) / Float(UInt32.max) * 2 - 1) * amplitude
        }
    }

    func testChunkSplitPrefersTheQuietestRecentMoment() {
        // 10 s of loud tone with 500 ms of silence from 7.0 s to 7.5 s.
        var samples = (0..<160_000).map { index in
            Float(0.1 * sin(2 * .pi * 220 * Double(index) / 16_000))
        }
        for index in 112_000..<120_000 {
            samples[index] = 0
        }

        let cutIndex = SpeechActivityDetector.quietestCutIndex(
            in: samples,
            searchingLast: 64_000
        )

        XCTAssertTrue(
            (112_000...120_000).contains(cutIndex),
            "Cut index \(cutIndex) should fall inside the silent stretch"
        )
    }

    func testLegacyModelNamesMigrateToCurrentVariants() async {
        let turbo = await WhisperService.currentModelName(for: "openai_whisper-large-v3_turbo")
        let large = await WhisperService.currentModelName(for: "openai_whisper-large-v3")

        XCTAssertEqual(
            turbo,
            "openai_whisper-large-v3-v20240930_turbo"
        )
        XCTAssertEqual(
            large,
            "openai_whisper-large-v3-v20240930_626MB"
        )
    }

    @MainActor
    func testTextViewReceivesExactStreamingHypothesisAndExposesCaretBounds() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 240, y: 240, width: 560, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: window.contentView?.bounds ?? .zero)
        textView.autoresizingMask = [.width, .height]
        textView.string = "Dictation marker test: "
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }

        try await Task.sleep(for: .milliseconds(150))

        let insertionService = TextInsertionService()
        guard insertionService.beginProvisionalInsertionSession(
            targetApplicationPID: ProcessInfo.processInfo.processIdentifier
        ) else {
            throw XCTSkip(
                "macOS did not vend AX caret attributes (for example, while the desktop is locked or shielded)"
            )
        }
        XCTAssertTrue(insertionService.updateProvisionalText("Hey"))
        XCTAssertEqual(textView.string, "Dictation marker test: Hey")

        XCTAssertTrue(insertionService.updateProvisionalText("Hey, what's going on now?"))
        XCTAssertEqual(textView.string, "Dictation marker test: Hey, what's going on now?")

        XCTAssertEqual(
            insertionService.commitProvisionalText("Hey, what's going on now?"),
            .committed
        )
        XCTAssertEqual(
            insertionService.commitProvisionalText("Hey, what's going on now?"),
            .needsFallbackInsertion
        )
        XCTAssertEqual(textView.string, "Dictation marker test: Hey, what's going on now?")

        guard let caretRect = RecordingOverlayController.caretRectInScreenCoordinates(
            for: ProcessInfo.processInfo.processIdentifier
        ) else {
            XCTFail("The focused text view did not expose AX caret bounds")
            return
        }
        XCTAssertTrue(
            window.frame.insetBy(dx: -24, dy: -24).contains(
                NSPoint(x: caretRect.midX, y: caretRect.midY)
            ),
            "Caret bounds should resolve inside the focused editor window, not near the mouse pointer"
        )
    }

    @MainActor
    func testFinalFallbackPastesIntoTheFocusedTextView() async throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("The XCTest host is not trusted to post global keyboard paste events")
        }

        let window = NSWindow(
            contentRect: NSRect(x: 260, y: 260, width: 480, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: window.contentView?.bounds ?? .zero)
        textView.autoresizingMask = [.width, .height]
        textView.string = "Fallback test: "
        textView.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0)
        )
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }

        try await Task.sleep(for: .milliseconds(100))

        TextInsertionService().insertText("dictated text")

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(textView.string, "Fallback test: dictated text")
    }
}

private final class TextInsertionSpy: TextInsertionServing {
    var regularInsertions: [String] = []
    var provisionalUpdates: [String] = []
    var updateResult = true
    var commitResult: ProvisionalTextCommitResult = .committed

    func beginProvisionalInsertionSession(targetApplicationPID: pid_t?) -> Bool { true }

    func updateProvisionalText(_ text: String) -> Bool {
        provisionalUpdates.append(text)
        return updateResult
    }

    func commitProvisionalText(_ text: String) -> ProvisionalTextCommitResult {
        commitResult
    }

    func cancelProvisionalInsertionSession() {}

    func insertText(_ text: String) {
        regularInsertions.append(text)
    }
}
