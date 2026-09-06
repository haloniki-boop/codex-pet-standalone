import AppKit
import AVFoundation
import Foundation
import os

private let settingsLogger = Logger(subsystem: "local.hal.codex-pet-standalone", category: "settings")

struct PetManifest: Decodable {
    let id: String
    let displayName: String
    let description: String?
    let spritesheetPath: String
}

struct Pet {
    let manifest: PetManifest
    let directory: URL

    var spritesheetURL: URL {
        directory.appendingPathComponent(manifest.spritesheetPath)
    }
}

struct PetSettings: Codable, Equatable {
    var preferredPetID: String
    var size: Double
    var chatCommand: [String]
    var notificationText: String
    var notificationFile: String
    var notificationDurationSeconds: Double
    var notificationWidth: Double
    var notificationHeight: Double
    var notificationFontSize: Double
    var inputBubbleWidth: Double
    var chatLogDirectoryPath: String
    var dotenvFilePath: String
    var idleConversationEnabled: Bool
    var idleConversationDelaySeconds: Double
    var idleConversationMessages: [String]
    var voiceInputEnabled: Bool
    var voiceOutputEnabled: Bool
    var voiceIdentifier: String
    var voiceToggleShortcut: String
    var aiProvider: String
    var aiEndpoint: String
    var aiModel: String
    var aiSystemPrompt: String
    var ragFilePaths: [String]

    static let legacyEnglishIdleConversationMessages = [
        "Need a tiny planning break?",
        "I am here when you want to think out loud.",
        "A small next step is still a next step.",
        "Want to open Codex and continue?"
    ]

    static let defaults = PetSettings(
        preferredPetID: "hovi",
        size: 168,
        chatCommand: ["/usr/bin/open", "-a", "Codex"],
        notificationText: "",
        notificationFile: "",
        notificationDurationSeconds: 10,
        notificationWidth: 152,
        notificationHeight: 174,
        notificationFontSize: 16,
        inputBubbleWidth: 218,
        chatLogDirectoryPath: codexPetDefaultInboxPath(),
        dotenvFilePath: codexPetDefaultDotenvPath(),
        idleConversationEnabled: true,
        idleConversationDelaySeconds: 90,
        idleConversationMessages: [
            "今日の空模様、少し気になりますね。外に出る前に天気を確認しておきますか？",
            "いま世の中で何が動いているか、気になるニュースを一つだけ見てみるのも良さそうです。",
            "AIニュースは流れが速いですね。今日の進展を軽く追ってみますか？",
            "雑学です。人は小さな未完了を減らすだけで、かなり頭が軽くなるそうです。",
            "禅語に『喫茶去』があります。まあ一服して、今ここに戻りましょう、という感じです。",
            "偉人の言葉を一つ。小さく始める人が、遠くまで進むことがあります。",
            "時事の話題は広すぎるので、まずは一つだけ。政治、経済、テック、どれを見ますか？",
            "今日はどんなAI活用を試しましょう。文章、整理、調査、どれでも付き合います。"
        ],
        voiceInputEnabled: false,
        voiceOutputEnabled: false,
        voiceIdentifier: AVSpeechSynthesisVoice(language: "ja-JP")?.identifier ?? "",
        voiceToggleShortcut: "cmd+shift+v",
        aiProvider: "codex",
        aiEndpoint: "https://api.openai.com/v1/chat/completions",
        aiModel: "gpt-4.1-mini",
        aiSystemPrompt: "あなたはデスクトップに住む小さな相棒です。日本語で、親しみやすく簡潔に返答してください。必要なら次の小さな行動を一つ提案してください。",
        ragFilePaths: []
    )

    static let sakanaDefaultEndpoint = "https://api.sakana.ai/v1/responses"
    static let ollamaDefaultEndpoint = "http://localhost:11434/v1/chat/completions"
    static let hermesDefaultEndpoint = "http://DXP2800-86A5.local:8642/v1/chat/completions"

    private enum CodingKeys: String, CodingKey {
        case preferredPetID
        case size
        case chatCommand
        case notificationText
        case notificationFile
        case notificationDurationSeconds
        case notificationWidth
        case notificationHeight
        case notificationFontSize
        case inputBubbleWidth
        case chatLogDirectoryPath
        case dotenvFilePath
        case idleConversationEnabled
        case idleConversationDelaySeconds
        case idleConversationMessages
        case voiceEnabled
        case voiceInputEnabled
        case voiceOutputEnabled
        case voiceIdentifier
        case voiceToggleShortcut
        case aiProvider
        case aiEndpoint
        case aiModel
        case aiSystemPrompt
        case ragFilePaths
    }

    init(
        preferredPetID: String,
        size: Double,
        chatCommand: [String],
        notificationText: String,
        notificationFile: String,
        notificationDurationSeconds: Double,
        notificationWidth: Double,
        notificationHeight: Double,
        notificationFontSize: Double,
        inputBubbleWidth: Double,
        chatLogDirectoryPath: String,
        dotenvFilePath: String,
        idleConversationEnabled: Bool,
        idleConversationDelaySeconds: Double,
        idleConversationMessages: [String],
        voiceInputEnabled: Bool,
        voiceOutputEnabled: Bool,
        voiceIdentifier: String,
        voiceToggleShortcut: String,
        aiProvider: String,
        aiEndpoint: String,
        aiModel: String,
        aiSystemPrompt: String,
        ragFilePaths: [String]
    ) {
        self.preferredPetID = preferredPetID
        self.size = size
        self.chatCommand = chatCommand
        self.notificationText = notificationText
        self.notificationFile = notificationFile
        self.notificationDurationSeconds = notificationDurationSeconds
        self.notificationWidth = notificationWidth
        self.notificationHeight = notificationHeight
        self.notificationFontSize = notificationFontSize
        self.inputBubbleWidth = inputBubbleWidth
        self.chatLogDirectoryPath = chatLogDirectoryPath
        self.dotenvFilePath = dotenvFilePath
        self.idleConversationEnabled = idleConversationEnabled
        self.idleConversationDelaySeconds = idleConversationDelaySeconds
        self.idleConversationMessages = idleConversationMessages
        self.voiceInputEnabled = voiceInputEnabled
        self.voiceOutputEnabled = voiceOutputEnabled
        self.voiceIdentifier = voiceIdentifier
        self.voiceToggleShortcut = voiceToggleShortcut
        self.aiProvider = aiProvider
        self.aiEndpoint = aiEndpoint
        self.aiModel = aiModel
        self.aiSystemPrompt = aiSystemPrompt
        self.ragFilePaths = ragFilePaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.preferredPetID = try container.decodeIfPresent(String.self, forKey: .preferredPetID) ?? Self.defaults.preferredPetID
        self.size = try container.decodeIfPresent(Double.self, forKey: .size) ?? Self.defaults.size
        self.chatCommand = try container.decodeIfPresent([String].self, forKey: .chatCommand) ?? Self.defaults.chatCommand
        self.notificationText = try container.decodeIfPresent(String.self, forKey: .notificationText) ?? Self.defaults.notificationText
        self.notificationFile = try container.decodeIfPresent(String.self, forKey: .notificationFile) ?? Self.defaults.notificationFile
        self.notificationDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .notificationDurationSeconds) ?? Self.defaults.notificationDurationSeconds
        self.notificationWidth = try container.decodeIfPresent(Double.self, forKey: .notificationWidth) ?? Self.defaults.notificationWidth
        self.notificationHeight = try container.decodeIfPresent(Double.self, forKey: .notificationHeight) ?? Self.defaults.notificationHeight
        self.notificationFontSize = try container.decodeIfPresent(Double.self, forKey: .notificationFontSize) ?? Self.defaults.notificationFontSize
        self.inputBubbleWidth = try container.decodeIfPresent(Double.self, forKey: .inputBubbleWidth) ?? Self.defaults.inputBubbleWidth
        self.chatLogDirectoryPath = try container.decodeIfPresent(String.self, forKey: .chatLogDirectoryPath) ?? Self.defaults.chatLogDirectoryPath
        self.dotenvFilePath = try container.decodeIfPresent(String.self, forKey: .dotenvFilePath) ?? Self.defaults.dotenvFilePath
        self.idleConversationEnabled = try container.decodeIfPresent(Bool.self, forKey: .idleConversationEnabled) ?? Self.defaults.idleConversationEnabled
        self.idleConversationDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .idleConversationDelaySeconds) ?? Self.defaults.idleConversationDelaySeconds
        self.idleConversationMessages = try container.decodeIfPresent([String].self, forKey: .idleConversationMessages) ?? Self.defaults.idleConversationMessages
        let legacyVoiceEnabled = (try container.decodeIfPresent(Bool.self, forKey: .voiceEnabled)) ?? Self.defaults.voiceInputEnabled
        self.voiceInputEnabled = (try container.decodeIfPresent(Bool.self, forKey: .voiceInputEnabled)) ?? legacyVoiceEnabled
        self.voiceOutputEnabled = (try container.decodeIfPresent(Bool.self, forKey: .voiceOutputEnabled)) ?? legacyVoiceEnabled
        self.voiceIdentifier = try container.decodeIfPresent(String.self, forKey: .voiceIdentifier) ?? Self.defaults.voiceIdentifier
        self.voiceToggleShortcut = try container.decodeIfPresent(String.self, forKey: .voiceToggleShortcut) ?? Self.defaults.voiceToggleShortcut
        self.aiProvider = try container.decodeIfPresent(String.self, forKey: .aiProvider) ?? Self.defaults.aiProvider
        self.aiEndpoint = try container.decodeIfPresent(String.self, forKey: .aiEndpoint) ?? Self.defaults.aiEndpoint
        self.aiModel = try container.decodeIfPresent(String.self, forKey: .aiModel) ?? Self.defaults.aiModel
        self.aiSystemPrompt = try container.decodeIfPresent(String.self, forKey: .aiSystemPrompt) ?? Self.defaults.aiSystemPrompt
        self.ragFilePaths = try container.decodeIfPresent([String].self, forKey: .ragFilePaths) ?? Self.defaults.ragFilePaths
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preferredPetID, forKey: .preferredPetID)
        try container.encode(size, forKey: .size)
        try container.encode(chatCommand, forKey: .chatCommand)
        try container.encode(notificationText, forKey: .notificationText)
        try container.encode(notificationFile, forKey: .notificationFile)
        try container.encode(notificationDurationSeconds, forKey: .notificationDurationSeconds)
        try container.encode(notificationWidth, forKey: .notificationWidth)
        try container.encode(notificationHeight, forKey: .notificationHeight)
        try container.encode(notificationFontSize, forKey: .notificationFontSize)
        try container.encode(inputBubbleWidth, forKey: .inputBubbleWidth)
        try container.encode(chatLogDirectoryPath, forKey: .chatLogDirectoryPath)
        try container.encode(dotenvFilePath, forKey: .dotenvFilePath)
        try container.encode(idleConversationEnabled, forKey: .idleConversationEnabled)
        try container.encode(idleConversationDelaySeconds, forKey: .idleConversationDelaySeconds)
        try container.encode(idleConversationMessages, forKey: .idleConversationMessages)
        try container.encode(voiceInputEnabled, forKey: .voiceInputEnabled)
        try container.encode(voiceOutputEnabled, forKey: .voiceOutputEnabled)
        try container.encode(voiceInputEnabled || voiceOutputEnabled, forKey: .voiceEnabled)
        try container.encode(voiceIdentifier, forKey: .voiceIdentifier)
        try container.encode(voiceToggleShortcut, forKey: .voiceToggleShortcut)
        try container.encode(aiProvider, forKey: .aiProvider)
        try container.encode(aiEndpoint, forKey: .aiEndpoint)
        try container.encode(aiModel, forKey: .aiModel)
        try container.encode(aiSystemPrompt, forKey: .aiSystemPrompt)
        try container.encode(ragFilePaths, forKey: .ragFilePaths)
    }
}

final class SettingsStore {
    let settingsURL: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.settingsURL = homeDirectory
            .appendingPathComponent(".codex")
            .appendingPathComponent("pet-standalone")
            .appendingPathComponent("settings.json")
    }

    func load() -> PetSettings {
        ensureSettingsFileExists()
        guard let data = try? Data(contentsOf: settingsURL) else {
            settingsLogger.warning("Failed to read settings file: \(self.settingsURL.path)")
            return .defaults
        }
        guard let settings = try? JSONDecoder().decode(PetSettings.self, from: data) else {
            settingsLogger.warning("Failed to decode settings from: \(self.settingsURL.path)")
            return .defaults
        }
        let normalizedSettings = normalized(settings)
        if settingsFileNeedsMigration(data: data) || normalizedSettings != settings {
            save(normalizedSettings)
        }
        return normalizedSettings
    }

    func save(_ settings: PetSettings) {
        ensureSettingsDirectoryExists()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else {
            settingsLogger.error("Failed to encode settings")
            return
        }
        do {
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            settingsLogger.error("Failed to write settings: \(error.localizedDescription)")
        }
    }

    func ensureSettingsFileExists() {
        ensureSettingsDirectoryExists()

        guard !FileManager.default.fileExists(atPath: settingsURL.path) else {
            return
        }

        save(.defaults)
    }

    func openInEditor() {
        ensureSettingsFileExists()
        NSWorkspace.shared.open(settingsURL)
    }

    private func ensureSettingsDirectoryExists() {
        let directory = settingsURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            settingsLogger.error("Failed to create settings directory: \(error.localizedDescription)")
        }
    }

    private func normalized(_ settings: PetSettings) -> PetSettings {
        var normalized = settings
        if normalized.preferredPetID.isEmpty {
            normalized.preferredPetID = PetSettings.defaults.preferredPetID
        }
        if normalized.size < SettingsConstants.minSize {
            normalized.size = PetSettings.defaults.size
        }
        if normalized.chatCommand.isEmpty {
            normalized.chatCommand = PetSettings.defaults.chatCommand
        }
        normalized.notificationDurationSeconds = min(max(normalized.notificationDurationSeconds, NotificationConstants.minDuration), NotificationConstants.maxDuration)
        normalized.notificationWidth = min(max(normalized.notificationWidth, UIConstants.minNotificationWidth), UIConstants.maxNotificationWidth)
        normalized.notificationHeight = min(max(normalized.notificationHeight, UIConstants.minNotificationHeight), UIConstants.maxNotificationHeight)
        normalized.notificationFontSize = min(max(normalized.notificationFontSize, UIConstants.minNotificationFontSize), UIConstants.maxNotificationFontSize)
        normalized.inputBubbleWidth = min(max(normalized.inputBubbleWidth, UIConstants.minComposerWidth), UIConstants.maxComposerWidth)
        if normalized.chatLogDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.chatLogDirectoryPath = PetSettings.defaults.chatLogDirectoryPath
        }
        if normalized.dotenvFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            normalized.dotenvFilePath = PetSettings.defaults.dotenvFilePath
        }
        if normalized.idleConversationDelaySeconds < SettingsConstants.minIdleDelaySeconds {
            normalized.idleConversationDelaySeconds = PetSettings.defaults.idleConversationDelaySeconds
        }
        if normalized.idleConversationMessages.isEmpty || normalized.idleConversationMessages == PetSettings.legacyEnglishIdleConversationMessages {
            normalized.idleConversationMessages = PetSettings.defaults.idleConversationMessages
        }
        if normalized.voiceIdentifier.isEmpty {
            normalized.voiceIdentifier = PetSettings.defaults.voiceIdentifier
        }
        if normalized.voiceToggleShortcut.isEmpty {
            normalized.voiceToggleShortcut = PetSettings.defaults.voiceToggleShortcut
        }
        if normalized.aiEndpoint.isEmpty {
            normalized.aiEndpoint = PetSettings.defaults.aiEndpoint
        }
        if !SettingsConstants.supportedAIProviders.contains(normalized.aiProvider) {
            normalized.aiProvider = PetSettings.defaults.aiProvider
        }
        if normalized.aiProvider == "SAKANA FUGU" {
            if normalized.aiEndpoint == PetSettings.defaults.aiEndpoint || normalized.aiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized.aiEndpoint = PetSettings.sakanaDefaultEndpoint
            }
            if normalized.aiModel.isEmpty || normalized.aiModel == "SAKANA FUGU" {
                normalized.aiModel = SettingsConstants.defaultSakanaModel
            }
        } else if normalized.aiProvider == "Ollama" {
            if normalized.aiEndpoint == PetSettings.defaults.aiEndpoint || normalized.aiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized.aiEndpoint = PetSettings.ollamaDefaultEndpoint
            }
            if normalized.aiModel.isEmpty || normalized.aiModel == "Ollama" {
                normalized.aiModel = SettingsConstants.defaultOllamaModel
            }
        } else if normalized.aiProvider == "Hermes Agent" {
            if normalized.aiEndpoint == PetSettings.defaults.aiEndpoint || normalized.aiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized.aiEndpoint = PetSettings.hermesDefaultEndpoint
            }
            if normalized.aiModel.isEmpty || normalized.aiModel == "Hermes Agent" {
                normalized.aiModel = SettingsConstants.defaultHermesModel
            }
        } else if normalized.aiModel.isEmpty {
            normalized.aiModel = PetSettings.defaults.aiModel
        }
        if normalized.aiSystemPrompt.isEmpty {
            normalized.aiSystemPrompt = PetSettings.defaults.aiSystemPrompt
        }
        normalized.ragFilePaths = Self.normalizePaths(normalized.ragFilePaths)
        return normalized
    }

    private static func normalizePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for rawPath in paths {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            normalized.append(trimmed)
        }
        return normalized
    }

    private func settingsFileNeedsMigration(data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return true
        }

        let requiredKeys: Set<String> = [
            "preferredPetID",
            "size",
            "chatCommand",
            "notificationText",
            "notificationFile",
            "notificationDurationSeconds",
            "notificationWidth",
            "notificationHeight",
            "notificationFontSize",
            "inputBubbleWidth",
            "chatLogDirectoryPath",
            "dotenvFilePath",
            "idleConversationEnabled",
            "idleConversationDelaySeconds",
            "idleConversationMessages",
            "voiceInputEnabled",
            "voiceOutputEnabled",
            "voiceEnabled",
            "voiceIdentifier",
            "voiceToggleShortcut",
            "aiProvider",
            "aiEndpoint",
            "aiModel",
            "aiSystemPrompt",
            "ragFilePaths"
        ]
        return !requiredKeys.isSubset(of: Set(dictionary.keys))
    }
}

final class PetStore {
    private let petsRoot: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.petsRoot = homeDirectory
            .appendingPathComponent(".codex")
            .appendingPathComponent("pets")
    }

    func loadPets() -> [Pet] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: petsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            settingsLogger.debug("Failed to list pet directories at \(self.petsRoot.path)")
            return []
        }

        return directories.compactMap { directory in
            let manifestURL = directory.appendingPathComponent("pet.json")
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            guard let data = try? Data(contentsOf: manifestURL) else {
                settingsLogger.debug("Failed to load pet manifest from \(manifestURL.path)")
                return nil
            }
            guard let manifest = try? JSONDecoder().decode(PetManifest.self, from: data) else {
                settingsLogger.debug("Failed to decode pet manifest from \(manifestURL.path)")
                return nil
            }
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(manifest.spritesheetPath).path) else {
                settingsLogger.debug("Missing spritesheet for pet \(manifest.id)")
                return nil
            }
            return Pet(manifest: manifest, directory: directory)
        }
        .sorted { $0.manifest.displayName.localizedStandardCompare($1.manifest.displayName) == .orderedAscending }
    }
}
