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

    /// Default debounce interval for unknown providers (nanoseconds)
    private let defaultDebounceInterval: UInt64 = 800_000_000  // 800ms

    /// Debounce intervals by provider (nanoseconds)
    /// Shorter intervals for faster providers, longer for API-based ones
    private let debounceIntervals: [TranslationProvider: UInt64] = [
        .macOS: 300_000_000,   // 300ms - fast on-device processing
        .gemini: 600_000_000,  // 600ms - moderate API latency
        .openAI: 800_000_000,  // 800ms - higher API latency
        .grok: 800_000_000     // 800ms - higher API latency
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

        // Prevent concurrent translations
        guard appState.subtitleTranslationState != .translating else {
            dprint("SubtitleTranslation: Skipping - already translating")

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


        } catch {
            dprint("SubtitleTranslation: Error: \(error)")


            let errorMessage = error.localizedDescription
            appState.subtitleTranslationState = .error(errorMessage)
            // Don't set subtitleTranslatedText to original - let displayText fallback handle it

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
