import Foundation

/// State of subtitle translation
enum SubtitleTranslationState: Equatable {
    case idle           // No translation active
    case translating    // Translation in progress
    case error(String)  // Error occurred

    var isTranslating: Bool {
        if case .translating = self { return true }
        return false
    }
}

/// Service for real-time subtitle translation
/// Cumulative text design: track confirmed portion length and translate only new parts
@MainActor
final class SubtitleTranslationService {
    static let shared = SubtitleTranslationService()

    // MARK: - Configuration Constants

    /// Pause threshold for confirming current segment (seconds)
    /// After this duration of no new text, translation is triggered
    private let pauseThreshold: TimeInterval = 1.5

    /// Interval for checking pause condition (nanoseconds)
    /// Checks every 500ms if pause threshold has been exceeded
    private let pauseCheckInterval: UInt64 = 500_000_000  // 500ms

    /// Delay before resetting error state (nanoseconds)
    /// Allows user to see error message before auto-clearing
    private let errorResetDelay: UInt64 = 3_000_000_000  // 3 seconds

    /// Default debounce interval for unknown providers (nanoseconds).
    /// Tightened after the v0.1.34 model refresh — current Flash/Mini/Fast LLMs
    /// have ~300–800 ms typical translation latency, so debounce + API latency
    /// stays under ~1 s end-to-end. Combined with the queue pattern (see
    /// `pendingTranslationText`), the user-visible delay between speech and
    /// translated subtitle now tracks API latency rather than debounce.
    private let defaultDebounceInterval: UInt64 = 400_000_000  // 400ms

    /// Debounce intervals by provider (nanoseconds)
    private let debounceIntervals: [TranslationProvider: UInt64] = [
        .macOS: 200_000_000,   // 200ms - instant on-device processing
        .gemini: 350_000_000,  // 350ms - Gemini 3.1 Flash Lite (~300-500ms API)
        .openAI: 400_000_000,  // 400ms - GPT-5.4 Mini (~500-1000ms API)
        .grok: 350_000_000     // 350ms - Grok 4.1 Fast non-reasoning (~300-700ms API)
    ]

    /// Maximum context segments to include for LLM translation
    /// More context improves consistency but increases token usage
    private let maxContextSegments = 2

    /// Maximum number of cached translations (LRU eviction)
    private let maxCacheEntries = 200

    // MARK: - State

    /// Last known STT text
    private var lastSTTText: String = ""

    /// Context for LLM translation (recently translated sentences)
    private var contextSegments: [TranslatedSentence] = []

    /// Last time text was updated
    private var lastUpdateTime: Date = Date()

    /// Task for debouncing translation
    private var debounceTask: Task<Void, Never>?

    /// Task for pause-based confirmation check
    private var pauseCheckTask: Task<Void, Never>?

    /// Latest text waiting to be translated while a previous translation is in
    /// flight. When the in-flight translation completes and this differs from
    /// what was just translated, we immediately fire another translation pass.
    /// Replaces the old "skip while translating" behavior which dropped updates
    /// for the entire 1–2 s an API call took.
    private var pendingTranslationText: String?

    /// Current translator instance
    private var translator: ContextualTranslator?

    /// Current provider (to detect changes)
    private var currentProvider: TranslationProvider?

    /// Current target language (to detect changes)
    private var currentTargetLanguage: LanguageCode?

    /// Cache for translations (original -> translated)
    private var translationCache: [String: String] = [:]
    private var cacheKeys: [String] = []

    private init() {}

    // MARK: - Public Methods

    /// Process text update from STT
    /// - Parameters:
    ///   - text: Full transcription text (cumulative from STT)
    ///   - isFinal: Whether this is a final result from STT
    ///   - appState: App state for settings and output
    func processTextUpdate(_ text: String, isFinal: Bool, appState: AppState) async {
        guard appState.subtitleTranslationEnabled else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastUpdateTime = Date()

        // Check for provider/language changes
        await ensureTranslator(for: appState)

        // Handle empty text
        if trimmedText.isEmpty {
            appState.subtitleTranslatedText = ""
            return
        }

        // Update last known text
        lastSTTText = trimmedText
        dprint("SubtitleTranslation: text='\(trimmedText.prefix(40))...', isFinal=\(isFinal), provider=\(appState.translationProvider.displayName)")


        if isFinal {
            // Final result - translate the full text immediately
            dprint("SubtitleTranslation: isFinal=true, translating immediately")

            debounceTask?.cancel()
            pauseCheckTask?.cancel()

            // Translate the entire text (simpler approach)
            await translateFullText(trimmedText, appState: appState)
        } else {
            // Partial result - schedule debounced translation
            dprint("SubtitleTranslation: isFinal=false, scheduling debounced translation (interval: \(debounceIntervals[appState.translationProvider] ?? defaultDebounceInterval)ns)")

            await scheduleTranslation(fullText: trimmedText, appState: appState)
            // Start pause check for auto-confirm
            startPauseCheck(appState: appState)
        }
    }

    /// Reset service state (call when recording starts)
    func reset() {
        lastSTTText = ""
        contextSegments.removeAll()
        debounceTask?.cancel()
        debounceTask = nil
        pauseCheckTask?.cancel()
        pauseCheckTask = nil
        pendingTranslationText = nil
        translator?.cancel()
        // Keep cache for potential reuse
    }

    /// Clear all state including cache
    func clearAll() {
        reset()
        translationCache.removeAll()
        cacheKeys.removeAll()
        translator = nil
        currentProvider = nil
        currentTargetLanguage = nil
    }

    /// Clear cache only (when language/provider changes)
    func clearCache() {
        translationCache.removeAll()
        cacheKeys.removeAll()
    }

    // MARK: - Private Methods

    /// Ensure translator is set up for current provider
    private func ensureTranslator(for appState: AppState) async {
        let provider = appState.translationProvider
        let targetLang = appState.translationTargetLanguage

        // Check if we need to create/recreate translator
        if translator == nil ||
           currentProvider != provider ||
           currentTargetLanguage != targetLang {

            translator?.cancel()

            // Use provider's default model for subtitle translation
            // (selectedTranslationModel might be for a different provider)
            let modelToUse = provider.defaultModelId

            translator = ContextualTranslatorFactory.makeTranslator(
                for: provider,
                model: modelToUse
            )
            currentProvider = provider

            #if DEBUG
            dprint("SubtitleTranslation: Created translator for \(provider.displayName), model: \(modelToUse), language: \(targetLang.displayName)")
            if translator == nil {
                dprint("SubtitleTranslation: WARNING - translator is nil!")
            }
            #endif

            // Clear state if language changed
            if currentTargetLanguage != targetLang {
                clearCache()
                contextSegments.removeAll()
                currentTargetLanguage = targetLang
            }
        }
    }

    /// Schedule debounced translation for full text
    private func scheduleTranslation(fullText: String, appState: AppState) async {
        debounceTask?.cancel()

        let interval = debounceIntervals[appState.translationProvider] ?? defaultDebounceInterval
        let textToTranslate = fullText

        debounceTask = Task { [weak self, weak appState] in
            do {
                try await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let appState else {
                    dprint("SubtitleTranslation: Debounce cancelled")

                    return
                }
                dprint("SubtitleTranslation: Debounce fired, translating...")

                await self?.translateFullText(textToTranslate, appState: appState)
            } catch {
                // Cancelled, ignore
            }
        }
    }

    /// Translate the full text and update display
    private func translateFullText(_ text: String, appState: AppState) async {
        guard !text.isEmpty else {
            appState.subtitleTranslatedText = ""
            return
        }

        // If another translation is in flight, queue this one as the latest
        // pending request instead of dropping it. When the in-flight call
        // completes, the wrapping pass will pick this up and fire again so the
        // displayed translation tracks the speech with minimal delay.
        guard appState.subtitleTranslationState != .translating else {
            pendingTranslationText = text
            dprint("SubtitleTranslation: In-flight — queued latest as pending (\(text.count) chars)")
            return
        }

        // Check cache first
        let cacheKey = makeCacheKey(text: text, language: appState.translationTargetLanguage)
        if let cached = translationCache[cacheKey] {
            appState.subtitleTranslatedText = cached
            dprint("SubtitleTranslation: Cache hit for '\(text.prefix(20))...'")

            return
        }

        appState.subtitleTranslationState = .translating

        do {
            guard let translator = translator else {
                throw TranslationError.translationUnavailable("Translator not available")
            }
            dprint("SubtitleTranslation: Translating '\(text.prefix(40))...' to \(appState.translationTargetLanguage.displayName)")


            let translated = try await translator.translate(
                text: text,
                context: contextSegments.suffix(maxContextSegments).map { $0 },
                to: appState.translationTargetLanguage
            )

            // Validate translation result - don't cache empty results
            guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                dprint("SubtitleTranslation: Empty translation result, skipping cache")

                appState.subtitleTranslationState = .idle
                return
            }

            // Update display
            appState.subtitleTranslatedText = translated
            addToCache(key: cacheKey, value: translated)

            // Store for context
            if contextSegments.isEmpty || contextSegments.last?.original != text {
                contextSegments.append(TranslatedSentence(original: text, translated: translated))
                if contextSegments.count > maxContextSegments * 2 {
                    contextSegments.removeFirst()
                }
            }

            appState.subtitleTranslationState = .idle
            dprint("SubtitleTranslation: Success → '\(translated.prefix(40))...'")

            // Drain queued pending translation if newer text arrived while this
            // call was in flight. Fire-and-forget — the recursive call will
            // re-enter the same in-flight check and either run or re-queue.
            if let pending = pendingTranslationText, pending != text {
                pendingTranslationText = nil
                dprint("SubtitleTranslation: Draining queued pending translation")
                Task { [weak self, weak appState] in
                    guard let self = self, let appState = appState else { return }
                    await self.translateFullText(pending, appState: appState)
                }
            } else {
                pendingTranslationText = nil
            }
        } catch {
            dprint("SubtitleTranslation: Error: \(error)")


            let errorMessage = error.localizedDescription
            appState.subtitleTranslationState = .error(errorMessage)
            // Don't set subtitleTranslatedText to original - let displayText fallback handle it

            // Drop any pending request so we don't immediately retry into the
            // same failure.
            pendingTranslationText = nil

            // Reset error state after delay
            let resetDelay = errorResetDelay
            Task { @MainActor [weak appState] in
                try? await Task.sleep(nanoseconds: resetDelay)
                if case .error = appState?.subtitleTranslationState {
                    appState?.subtitleTranslationState = .idle
                }
            }
        }
    }

    /// Start periodic check for pause-based translation trigger
    private func startPauseCheck(appState: AppState) {
        pauseCheckTask?.cancel()

        let checkInterval = pauseCheckInterval
        pauseCheckTask = Task { [weak self, weak appState] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: checkInterval)
                guard !Task.isCancelled, let self = self, let appState else { break }

                let elapsed = Date().timeIntervalSince(self.lastUpdateTime)
                if elapsed >= self.pauseThreshold && !self.lastSTTText.isEmpty {
                    // Only trigger if debounce hasn't already started translating
                    // Check if we're already translating
                    guard appState.subtitleTranslationState != .translating else {
                        dprint("SubtitleTranslation: Pause timeout skipped - already translating")

                        break
                    }
                    dprint("SubtitleTranslation: Pause timeout - triggering translation")


                    // Cancel debounce and translate immediately
                    self.debounceTask?.cancel()
                    await self.translateFullText(self.lastSTTText, appState: appState)
                    break
                }
            }
        }
    }

    // MARK: - Cache Management

    private func makeCacheKey(text: String, language: LanguageCode) -> String {
        return "\(language.rawValue):\(text)"
    }

    private func addToCache(key: String, value: String) {
        // Remove if exists (for LRU reordering)
        if let index = cacheKeys.firstIndex(of: key) {
            cacheKeys.remove(at: index)
        }

        translationCache[key] = value
        cacheKeys.append(key)

        // Evict oldest if over limit
        while cacheKeys.count > maxCacheEntries {
            let oldKey = cacheKeys.removeFirst()
            translationCache.removeValue(forKey: oldKey)
        }
    }
}
