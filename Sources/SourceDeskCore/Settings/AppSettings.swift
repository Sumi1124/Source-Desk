import Foundation

/// Everything the user can configure, in one observable value.
///
/// Settings are persisted in the library database (not `UserDefaults`) so a
/// notebook's behaviour travels with the notebook store, and so export never
/// accidentally carries them. Credentials are *not* here — they live in the Keychain.
public struct AppSettings: Codable, Equatable, Sendable {

    // MARK: AI providers

    /// Provider used for new questions and study tools.
    public var preferredProviderID: String
    /// Model per provider, so switching providers remembers what was selected.
    public var modelSelection: [String: String]
    /// Endpoint for a local Ollama-compatible server.
    public var ollamaEndpoint: String
    /// Endpoint for Ollama's hosted API (or any other remote Ollama host).
    public var ollamaCloudEndpoint: String
    /// Base URL override for OpenAI-compatible gateways.
    public var openAIBaseURL: String
    public var openAIBaseURLOverride: String
    public var anthropicBaseURL: String
    public var temperature: Double
    public var maxResponseTokens: Int

    // MARK: Search

    public var searchEngine: SearchEngine
    public var searchResultCount: Int
    public var enrichWebResults: Bool
    /// Scope new chat sessions start with.
    public var defaultAnswerScope: AnswerScope

    // MARK: Retrieval

    public var chunkTargetTokens: Int
    public var chunkOverlapTokens: Int
    public var retrievalResultCount: Int
    public var retrievalCandidateCount: Int
    public var semanticSearchEnabled: Bool
    public var keywordSearchEnabled: Bool
    public var rerankStrategy: RerankStrategy
    public var contextTokenBudget: Int
    public var maxChunksPerSource: Int
    public var minimumRelevanceScore: Double
    public var embeddingChoice: EmbeddingChoice
    public var ollamaEmbeddingModel: String
    /// Chunks and vectors are rebuilt automatically when the embedding model changes.
    public var autoReindexOnModelChange: Bool

    // MARK: Privacy

    public var localOnlyMode: Bool
    /// Ask before sending source content to a cloud provider.
    public var confirmBeforeCloudSend: Bool
    /// Notebooks for which the user has approved cloud sending.
    public var cloudApprovedNotebooks: [RecordID]
    public var respectRobotsTxt: Bool
    public var storeOriginalDownloads: Bool

    // MARK: Storage

    public var storageRootPath: String
    public var maximumImportBytes: Int64
    public var maximumPageBytes: Int64
    public var autoDeleteCacheOnQuit: Bool
    public var keepChatHistoryDays: Int

    // MARK: Appearance

    public var appearance: AppearanceMode
    /// Show the inspector panel.
    public var showInspector: Bool
    public var showSourceWordCounts: Bool
    public var chatFontSize: Double

    // MARK: Advanced

    public var logLevel: LogLevel
    public var requestTimeoutSeconds: Double
    public var maximumConcurrentIngestions: Int
    public var systemPromptOverride: String
    public var includeHeadingContextInChunks: Bool

    public init() {
        preferredProviderID = "ollama"
        modelSelection = [:]
        ollamaEndpoint = "http://127.0.0.1:11434"
        ollamaCloudEndpoint = "https://ollama.com"
        openAIBaseURL = "https://api.openai.com/v1"
        openAIBaseURLOverride = ""
        anthropicBaseURL = "https://api.anthropic.com/v1"
        temperature = 0.2
        maxResponseTokens = 2_048

        searchEngine = .duckduckgo
        searchResultCount = 6
        enrichWebResults = true
        defaultAnswerScope = .notebookSources

        chunkTargetTokens = 320
        chunkOverlapTokens = 60
        retrievalResultCount = 8
        retrievalCandidateCount = 40
        semanticSearchEnabled = true
        keywordSearchEnabled = true
        rerankStrategy = .lexical
        contextTokenBudget = 4_000
        maxChunksPerSource = 3
        minimumRelevanceScore = 0.08
        embeddingChoice = .builtIn
        ollamaEmbeddingModel = "nomic-embed-text"
        autoReindexOnModelChange = true

        localOnlyMode = false
        confirmBeforeCloudSend = true
        cloudApprovedNotebooks = []
        respectRobotsTxt = true
        storeOriginalDownloads = true

        storageRootPath = AppPaths.defaultRoot.path
        maximumImportBytes = 512 * 1024 * 1024
        maximumPageBytes = 25 * 1024 * 1024
        autoDeleteCacheOnQuit = true
        keepChatHistoryDays = 0

        appearance = .system
        showInspector = true
        showSourceWordCounts = true
        chatFontSize = 13
        logLevel = .error
        requestTimeoutSeconds = 120
        maximumConcurrentIngestions = 3
        systemPromptOverride = ""
        includeHeadingContextInChunks = true
    }

    // MARK: Derived values

    public var ollamaEndpointURL: URL {
        URL(string: ollamaEndpoint) ?? URL(string: "http://127.0.0.1:11434")!
    }

    public var ollamaCloudEndpointURL: URL {
        URL(string: ollamaCloudEndpoint) ?? OllamaProvider.cloudEndpoint
    }

    public var openAIBaseURLValue: URL {
        let override = openAIBaseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty, let url = URL(string: override) { return url }
        return URL(string: openAIBaseURL) ?? URL(string: "https://api.openai.com/v1")!
    }

    public var anthropicBaseURLValue: URL {
        URL(string: anthropicBaseURL) ?? URL(string: "https://api.anthropic.com/v1")!
    }

    public var chunkingConfiguration: TextChunker.Configuration {
        TextChunker.Configuration(
            targetTokens: chunkTargetTokens,
            maximumTokens: Int(Double(chunkTargetTokens) * 1.5),
            overlapTokens: chunkOverlapTokens,
            includeHeadingContext: includeHeadingContextInChunks
        )
    }

    public var retrievalConfiguration: RetrievalConfiguration {
        RetrievalConfiguration(
            resultCount: retrievalResultCount,
            candidateCount: retrievalCandidateCount,
            semanticEnabled: semanticSearchEnabled,
            keywordEnabled: keywordSearchEnabled,
            rerank: rerankStrategy,
            contextTokenBudget: contextTokenBudget,
            maxChunksPerSource: maxChunksPerSource,
            minimumScore: minimumRelevanceScore
        )
    }

    public func model(for providerID: String) -> String {
        modelSelection[providerID] ?? ""
    }

    /// The configuration a study tool or answer engine should use.
    public func researchConfiguration(notebookID: RecordID) -> AnswerEngine.ResearchConfiguration {
        AnswerEngine.ResearchConfiguration(
            providerID: preferredProviderID,
            modelName: model(for: preferredProviderID),
            scope: defaultAnswerScope,
            retrieval: retrievalConfiguration,
            temperature: temperature,
            maxTokens: maxResponseTokens,
            localOnlyMode: localOnlyMode,
            systemPromptOverride: systemPromptOverride.isEmpty ? nil : systemPromptOverride,
            cloudConsentGranted: isCloudApproved(notebookID: notebookID)
        )
    }

    public func studyConfiguration(notebookID: RecordID) -> StudyToolsService.Configuration {
        StudyToolsConfigurationBridge.configuration(for: self, notebookID: notebookID)
    }

    public func isCloudApproved(notebookID: RecordID) -> Bool {
        !confirmBeforeCloudSend || cloudApprovedNotebooks.contains(notebookID)
    }

    public mutating func approveCloud(for notebookID: RecordID) {
        if !cloudApprovedNotebooks.contains(notebookID) {
            cloudApprovedNotebooks.append(notebookID)
        }
    }

    public mutating func revokeCloud(for notebookID: RecordID) {
        cloudApprovedNotebooks.removeAll { $0 == notebookID }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Start from defaults so a settings blob written by an older build is
        // completed rather than rejected.
        self.init()
        func decode<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }
        preferredProviderID = decode(.preferredProviderID, preferredProviderID)
        modelSelection = decode(.modelSelection, modelSelection)
        ollamaEndpoint = decode(.ollamaEndpoint, ollamaEndpoint)
        ollamaCloudEndpoint = decode(.ollamaCloudEndpoint, ollamaCloudEndpoint)
        openAIBaseURL = decode(.openAIBaseURL, openAIBaseURL)
        openAIBaseURLOverride = decode(.openAIBaseURLOverride, openAIBaseURLOverride)
        anthropicBaseURL = decode(.anthropicBaseURL, anthropicBaseURL)
        temperature = decode(.temperature, temperature)
        maxResponseTokens = decode(.maxResponseTokens, maxResponseTokens)

        if let engine = try? container.decode(SearchEngine.self, forKey: .searchEngine) { searchEngine = engine }
        searchResultCount = decode(.searchResultCount, searchResultCount)
        enrichWebResults = decode(.enrichWebResults, enrichWebResults)
        if let scope = try? container.decode(AnswerScope.self, forKey: .defaultAnswerScope) { defaultAnswerScope = scope }

        chunkTargetTokens = decode(.chunkTargetTokens, chunkTargetTokens)
        chunkOverlapTokens = decode(.chunkOverlapTokens, chunkOverlapTokens)
        retrievalResultCount = decode(.retrievalResultCount, retrievalResultCount)
        retrievalCandidateCount = decode(.retrievalCandidateCount, retrievalCandidateCount)
        semanticSearchEnabled = decode(.semanticSearchEnabled, semanticSearchEnabled)
        keywordSearchEnabled = decode(.keywordSearchEnabled, keywordSearchEnabled)
        if let strategy = try? container.decode(RerankStrategy.self, forKey: .rerankStrategy) { rerankStrategy = strategy }
        contextTokenBudget = decode(.contextTokenBudget, contextTokenBudget)
        maxChunksPerSource = decode(.maxChunksPerSource, maxChunksPerSource)
        minimumRelevanceScore = decode(.minimumRelevanceScore, minimumRelevanceScore)
        if let choice = try? container.decode(EmbeddingChoice.self, forKey: .embeddingChoice) { embeddingChoice = choice }
        ollamaEmbeddingModel = decode(.ollamaEmbeddingModel, ollamaEmbeddingModel)
        autoReindexOnModelChange = decode(.autoReindexOnModelChange, autoReindexOnModelChange)

        localOnlyMode = decode(.localOnlyMode, localOnlyMode)
        confirmBeforeCloudSend = decode(.confirmBeforeCloudSend, confirmBeforeCloudSend)
        cloudApprovedNotebooks = decode(.cloudApprovedNotebooks, cloudApprovedNotebooks)
        respectRobotsTxt = decode(.respectRobotsTxt, respectRobotsTxt)
        storeOriginalDownloads = decode(.storeOriginalDownloads, storeOriginalDownloads)

        storageRootPath = decode(.storageRootPath, storageRootPath)
        maximumImportBytes = decode(.maximumImportBytes, maximumImportBytes)
        maximumPageBytes = decode(.maximumPageBytes, maximumPageBytes)
        autoDeleteCacheOnQuit = decode(.autoDeleteCacheOnQuit, autoDeleteCacheOnQuit)
        keepChatHistoryDays = decode(.keepChatHistoryDays, keepChatHistoryDays)

        if let mode = try? container.decode(AppearanceMode.self, forKey: .appearance) { appearance = mode }
        showInspector = decode(.showInspector, showInspector)
        showSourceWordCounts = decode(.showSourceWordCounts, showSourceWordCounts)
        chatFontSize = decode(.chatFontSize, chatFontSize)

        if let level = try? container.decode(LogLevel.self, forKey: .logLevel) { logLevel = level }
        requestTimeoutSeconds = decode(.requestTimeoutSeconds, requestTimeoutSeconds)
        maximumConcurrentIngestions = decode(.maximumConcurrentIngestions, maximumConcurrentIngestions)
        systemPromptOverride = decode(.systemPromptOverride, systemPromptOverride)
        includeHeadingContextInChunks = decode(.includeHeadingContextInChunks, includeHeadingContextInChunks)
    }
}

/// Keeps `AppSettings` free of a dependency on the study-tools type while still
/// producing its configuration.
enum StudyToolsConfigurationBridge {
    static func configuration(for settings: AppSettings, notebookID: RecordID) -> StudyToolsService.Configuration {
        StudyToolsService.Configuration(
            providerID: settings.preferredProviderID,
            modelName: settings.model(for: settings.preferredProviderID),
            retrieval: settings.retrievalConfiguration,
            temperature: max(0.2, settings.temperature),
            localOnlyMode: settings.localOnlyMode,
            cloudConsentGranted: settings.isCloudApproved(notebookID: notebookID)
        )
    }
}

// MARK: - Settings persistence

/// Reads and writes `AppSettings` through the library database.
public struct SettingsStore: Sendable {

    public static let key = "app.settings.v1"
    let store: NotebookStore

    public init(store: NotebookStore) {
        self.store = store
    }

    public func load() -> AppSettings {
        guard let json = try? store.settingValue(Self.key),
              let data = json.data(using: .utf8) else {
            return AppSettings()
        }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            // A corrupt settings blob falls back to defaults rather than failing to
            // launch — the user's notebooks are unaffected either way.
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        try store.setSettingValue(Self.key, String(decoding: data, as: UTF8.self))
    }

    public func reset() throws {
        try store.setSettingValue(Self.key, "")
        try store.setSettingValue(Self.key, String(decoding: try JSONEncoder().encode(AppSettings()), as: UTF8.self))
    }

    /// Settings that must be surfaced when the user changes something structural.
    public static func requiresReindex(from old: AppSettings, to new: AppSettings) -> Bool {
        old.embeddingChoice != new.embeddingChoice
            || old.ollamaEmbeddingModel != new.ollamaEmbeddingModel
            || old.chunkTargetTokens != new.chunkTargetTokens
            || old.chunkOverlapTokens != new.chunkOverlapTokens
            || old.includeHeadingContextInChunks != new.includeHeadingContextInChunks
    }
}

// MARK: - Diagnostics log

/// A small rotating log the Advanced settings can point at and the user can read.
/// Deliberately plain text: no telemetry, nothing leaves the Mac.
public final class DiagnosticsLog: @unchecked Sendable {

    public static let shared = DiagnosticsLog()

    private let lock = NSLock()
    private var level: LogLevel = .error

    public init() {}
    private var fileURL: URL?
    private let maximumBytes = 2 * 1024 * 1024

    public func configure(level: LogLevel, directory: URL?) {
        lock.lock(); defer { lock.unlock() }
        self.level = level
        if let directory {
            fileURL = directory.appendingPathComponent("sourcedesk.log")
        }
    }

    public var logFileURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return fileURL
    }

    public func log(_ message: String, level: LogLevel, category: String = "app") {
        lock.lock()
        let threshold = self.level
        let url = fileURL
        lock.unlock()
        guard shouldLog(level, threshold: threshold), let url else { return }

        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) [\(level.rawValue.uppercased())] \(category): \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd() {
                if size > UInt64(maximumBytes) {
                    // Rotate: keep the newest half rather than growing without bound.
                    if let existing = try? Data(contentsOf: url) {
                        let half = existing.suffix(existing.count / 2)
                        try? half.write(to: url, options: .atomic)
                    }
                }
                try? handle.write(contentsOf: data)
            }
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    public func error(_ message: String, category: String = "app") { log(message, level: .error, category: category) }
    public func info(_ message: String, category: String = "app") { log(message, level: .info, category: category) }
    public func debug(_ message: String, category: String = "app") { log(message, level: .debug, category: category) }

    public func recentLines(limit: Int = 400) -> [String] {
        lock.lock()
        let url = fileURL
        lock.unlock()
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).suffix(limit).map { $0 }
    }

    private func shouldLog(_ level: LogLevel, threshold: LogLevel) -> Bool {
        func rank(_ value: LogLevel) -> Int {
            switch value {
            case .off: return 0
            case .error: return 1
            case .info: return 2
            case .debug: return 3
            }
        }
        return rank(level) <= rank(threshold) && threshold != .off
    }
}
