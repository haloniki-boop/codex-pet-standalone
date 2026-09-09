import AppKit
import EventKit
import Foundation
import os
import UserNotifications

private let companionLogger = Logger(subsystem: "local.hal.codex-pet-standalone", category: "companion")

func codexPetProjectRootURL() -> URL {
    let fileManager = FileManager.default
    let bundleStart = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [bundleStart, URL(fileURLWithPath: fileManager.currentDirectoryPath)]

    for start in candidates {
        var current = start
        for _ in 0..<8 {
            if fileManager.fileExists(atPath: current.appendingPathComponent("Package.swift").path) ||
                fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
    }

    return fileManager.homeDirectoryForCurrentUser
}

func codexPetDefaultInboxPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Mobile Documents")
        .appendingPathComponent("iCloud~md~obsidian")
        .appendingPathComponent("Documents")
        .appendingPathComponent("HOVIX")
        .appendingPathComponent("00_INBOX")
        .path
}

func codexPetDefaultDotenvPath() -> String {
    codexPetProjectRootURL().appendingPathComponent(".env").path
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

enum AIClientError: LocalizedError {
    case invalidEndpoint
    case missingAPIKey
    case invalidResponse
    case server(String)
    case commandUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "AIの接続先URLが正しくありません。"
        case .missingAPIKey:
            return "APIキーが未設定です。.env に設定してください。"
        case .invalidResponse:
            return "AIから読み取れる返答がありませんでした。"
        case .server(let message):
            return message
        case .commandUnavailable(let name):
            return "\(name) のコマンドが見つかりません。先にCLIをインストールしてください。"
        }
    }
}

@MainActor
final class SecretStore {
    private var dotenvFilePath = codexPetDefaultDotenvPath()

    func configure(dotenvFilePath: String) {
        self.dotenvFilePath = dotenvFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func loadAPIKey() -> String {
        return loadEnvironmentValue(for: [
            "SAKANA_FUGU_API_KEY",
            "SAKANA_API_KEY",
            "OPENAI_API_KEY",
            "AI_API_KEY",
            "API_KEY"
        ])
    }

    func loadEnvironmentValue(for keys: [String]) -> String {
        let current = ProcessInfo.processInfo.environment
        for key in keys {
            if let value = current[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }

        for dotenvURL in dotenvCandidateURLs() {
            guard let data = try? Data(contentsOf: dotenvURL),
                  let contents = String(data: data, encoding: .utf8) else {
                continue
            }
            let values = parseDotEnv(contents)
            for key in keys {
                if let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
        }
        return ""
    }

    private func dotenvCandidateURLs() -> [URL] {
        var urls: [URL] = []
        if let explicit = resolvedPathURL(dotenvFilePath) {
            urls.append(explicit)
        }
        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env"))
        urls.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env"))
        return urls
    }

    private func parseDotEnv(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let valuePart = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String
            if (valuePart.hasPrefix("\"") && valuePart.hasSuffix("\"")) || (valuePart.hasPrefix("'") && valuePart.hasSuffix("'")) {
                value = String(valuePart.dropFirst().dropLast())
            } else {
                value = valuePart
            }
            if !key.isEmpty {
                values[key] = value
            }
        }
        return values
    }

    private func resolvedPathURL(_ rawPath: String) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return codexPetProjectRootURL().appendingPathComponent(expanded)
    }
}

@MainActor
final class AIChatClient {
    private let secretStore: SecretStore

    init(secretStore: SecretStore) {
        self.secretStore = secretStore
    }

    func reply(to messages: [ChatMessage], settings: PetSettings) async throws -> String {
        switch settings.aiProvider {
        case "codex":
            return try await commandReply(
                executableCandidates: ExecutableConstants.codexExecutableCandidates,
                name: "codex",
                prompt: prompt(from: messages, settings: settings),
                kind: .codex
            )
        case "claudeCode":
            return try await commandReply(
                executableCandidates: ExecutableConstants.claudeExecutableCandidates,
                name: "claudeCode",
                prompt: prompt(from: messages, settings: settings),
                kind: .claude
            )
        case "Gemini":
            return try await commandReply(
                executableCandidates: ExecutableConstants.geminiExecutableCandidates,
                name: "Gemini",
                prompt: prompt(from: messages, settings: settings),
                kind: .gemini
            )
        case "Ollama":
            guard let url = URL(string: settings.aiEndpoint) else {
                throw AIClientError.invalidEndpoint
            }
            return try await ollamaReply(url: url, messages: messages, settings: settings)
        case "Hermes Agent":
            guard let url = URL(string: settings.aiEndpoint) else {
                throw AIClientError.invalidEndpoint
            }
            return try await hermesReply(url: url, messages: messages, settings: settings)
        case "Genspark":
            guard let url = URL(string: settings.aiEndpoint) else {
                throw AIClientError.invalidEndpoint
            }
            return try await gensparkReply(url: url, messages: messages, settings: settings)
        case "SAKANA FUGU":
            guard let url = URL(string: settings.aiEndpoint) else {
                throw AIClientError.invalidEndpoint
            }
            return try await sakanaReply(url: url, messages: messages, settings: settings)
        default:
            throw AIClientError.server("選択したAIモデルに対応していません。")
        }
    }

    private enum CommandKind: Sendable {
        case codex
        case claude
        case gemini
    }

    private func prompt(from messages: [ChatMessage], settings: PetSettings) -> String {
        let history = messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        let ragContext = ragContext(from: settings)
        let ragSection = ragContext.isEmpty ? "" : "\n\n参考資料:\n\(ragContext)"
        return """
        \(settings.aiSystemPrompt)
        \(ragSection)

        以下の会話に日本語で返答してください。
        \(history)
        """
    }

    private func commandReply(
        executableCandidates: [String],
        name: String,
        prompt: String,
        kind: CommandKind
    ) async throws -> String {
        guard let executable = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AIClientError.commandUnavailable(name)
        }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let errorOutput = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.standardOutput = output
            process.standardError = errorOutput

            let temporaryOutput = FileManager.default.temporaryDirectory
                .appendingPathComponent("desktop-pet-\(UUID().uuidString).txt")
            switch kind {
            case .codex:
                process.arguments = [
                    "exec",
                    "--skip-git-repo-check",
                    "--color", "never",
                    "--output-last-message", temporaryOutput.path,
                    prompt
                ]
            case .claude:
                process.arguments = ["-p", prompt, "--output-format", "text"]
            case .gemini:
                process.arguments = ["-p", prompt]
            }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw AIClientError.server("\(name) の起動に失敗しました: \(error.localizedDescription)")
            }

            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = errorOutput.fileHandleForReading.readDataToEndOfFile()
            let finalData: Data
            if let outputFileData = try? Data(contentsOf: temporaryOutput) {
                finalData = outputFileData
            } else {
                finalData = stdout
            }
            do {
                try FileManager.default.removeItem(at: temporaryOutput)
            } catch {
                companionLogger.debug("Failed to remove temporary file: \(error.localizedDescription)")
            }
            let text = String(data: finalData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus != 0 {
                let detail = String(data: stderr, encoding: .utf8) ?? "終了コード \(process.terminationStatus)"
                throw AIClientError.server("\(name) エラー: \(detail.prefix(300))")
            }
            guard !text.isEmpty else {
                throw AIClientError.invalidResponse
            }
            return text
        }.value
    }

    private func sakanaReply(url: URL, messages: [ChatMessage], settings: PetSettings) async throws -> String {
        let endpoint = responsesEndpointURL(from: url)
        let apiKey = secretStore.loadAPIKey()
        guard !apiKey.isEmpty else {
            throw AIClientError.missingAPIKey
        }
        let ragContext = ragContext(from: settings)
        let instructions = [settings.aiSystemPrompt, ragContext.isEmpty ? nil : "参考資料:\n\(ragContext)"]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": sakanaModelSlug(for: settings),
            "instructions": instructions,
            "input": messages.map { message in
                [
                    "role": message.role,
                    "content": [
                        [
                            "type": "input_text",
                            "text": message.content
                        ]
                    ]
                ]
            }
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIClientError.invalidResponse
        }
        if let text = extractResponsesText(from: object) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw AIClientError.invalidResponse
    }

    private func ollamaReply(url: URL, messages: [ChatMessage], settings: PetSettings) async throws -> String {
        try await chatCompletionsReply(url: url, messages: messages, settings: settings, apiKey: nil)
    }

    private func hermesReply(url: URL, messages: [ChatMessage], settings: PetSettings) async throws -> String {
        let apiKey = secretStore.loadEnvironmentValue(for: ["HERMES_API_KEY"])
        guard !apiKey.isEmpty else {
            throw AIClientError.missingAPIKey
        }
        return try await chatCompletionsReply(url: url, messages: messages, settings: settings, apiKey: apiKey)
    }

    private func gensparkReply(url: URL, messages: [ChatMessage], settings: PetSettings) async throws -> String {
        let apiKey = secretStore.loadEnvironmentValue(for: ["GENSPARK_API_KEY"])
        guard !apiKey.isEmpty else {
            throw AIClientError.missingAPIKey
        }
        return try await chatCompletionsReply(url: url, messages: messages, settings: settings, apiKey: apiKey)
    }

    func gensparkUsage(endpoint: String) async -> (remainingPercent: Double, error: String?) {
        guard let url = URL(string: endpoint) else {
            return (100.0, "無効なエンドポイント")
        }

        let apiKey = secretStore.loadEnvironmentValue(for: ["GENSPARK_API_KEY"])
        guard !apiKey.isEmpty else {
            return (100.0, "APIキーが未設定")
        }

        let baseURLString = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let usageEndpoints = [
            baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/models",
            baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/billing/usage"
        ]

        for usageURL in usageEndpoints {
            guard let endpointURL = URL(string: usageURL) else { continue }

            var request = URLRequest(url: endpointURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    continue
                }

                if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let usage = object["usage"] as? [String: Any],
                       let total = usage["total_available"] as? Double,
                       let used = usage["total_used"] as? Double,
                       total > 0 {
                        let remaining = max(0, min(100, (total - used) / total * 100))
                        return (remaining, nil)
                    }
                    if let models = object["data"] as? [[String: Any]] {
                        return (100.0, nil)
                    }
                }
            } catch {
                continue
            }
        }

        return (100.0, nil)
    }

    private func chatCompletionsReply(
        url: URL,
        messages: [ChatMessage],
        settings: PetSettings,
        apiKey: String?
    ) async throws -> String {
        let endpoint = chatCompletionsEndpointURL(from: url)
        let ragContext = ragContext(from: settings)
        let systemPrompt = [settings.aiSystemPrompt, ragContext.isEmpty ? nil : "参考資料:\n\(ragContext)"]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": settings.aiModel,
            "stream": false,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ]
            ] + messages.map { message in
                [
                    "role": message.role,
                    "content": message.content
                ]
            }
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIClientError.invalidResponse
        }
        if let choices = object["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let message = object["message"] as? [String: Any],
           let content = message["content"] as? String {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        throw AIClientError.invalidResponse
    }

    private func sakanaModelSlug(for settings: PetSettings) -> String {
        let model = settings.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty || model == "SAKANA FUGU" {
            return "fugu"
        }
        return model
    }

    private func responsesEndpointURL(from url: URL) -> URL {
        let path = url.path
        if path.hasSuffix("/responses") {
            return url
        }
        if path.hasSuffix("/chat/completions") {
            let next = url.absoluteString.replacingOccurrences(of: "/chat/completions", with: "/responses")
            return URL(string: next) ?? url
        }
        return url.appendingPathComponent("responses")
    }

    private func ragContext(from settings: PetSettings) -> String {
        let entries = settings.ragFilePaths.prefix(5).compactMap { rawPath -> String? in
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let url = resolvedRAGURL(from: trimmed)
            guard let data = try? Data(contentsOf: url),
                  let contents = String(data: data, encoding: .utf8) else {
                return nil
            }
            let collapsed = contents
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !collapsed.isEmpty else { return nil }
            return "・\(url.lastPathComponent): \(collapsed.prefix(1200))"
        }
        return entries.joined(separator: "\n")
    }

    private func resolvedRAGURL(from rawPath: String) -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return codexPetProjectRootURL().appendingPathComponent(expanded)
    }

    private func chatCompletionsEndpointURL(from url: URL) -> URL {
        let path = url.path
        if path.hasSuffix("/chat/completions") {
            return url
        }
        if path.hasSuffix("/v1") || path.hasSuffix("/v1/") {
            return url.appendingPathComponent("chat").appendingPathComponent("completions")
        }
        if path.isEmpty || path == "/" {
            return url.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions")
        }
        return url.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions")
    }

    private func extractResponsesText(from object: [String: Any]) -> String? {
        if let text = object["output_text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let output = object["output"] as? [[String: Any]] {
            for item in output {
                if let text = extractText(from: item) {
                    return text
                }
            }
        }
        return nil
    }

    private func extractText(from value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : string
        }
        if let dictionary = value as? [String: Any] {
            if let text = dictionary["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let content = dictionary["content"] as? [Any] {
                for item in content {
                    if let text = extractText(from: item) {
                        return text
                    }
                }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let text = extractText(from: item) {
                    return text
                }
            }
        }
        return nil
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AIClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AIClientError.server("AI接続エラー: \(body.prefix(300))")
        }
    }
}

@MainActor
final class ChatWindowController: NSWindowController, NSTextFieldDelegate {
    private let client: AIChatClient
    private let settingsProvider: () -> PetSettings
    private var logDirectoryPath: String
    private let transcript = NSTextView()
    private let input = NSTextField()
    private let sendButton = NSButton(title: "送信", target: nil, action: nil)
    private var messages: [ChatMessage] = []
    private var logURL: URL
    private let sessionStartedAt = Date()
    private var logLines: [String] = []
    private var persistedLineCount = 0
    private var didWriteSessionHeader = false
    var responseHandler: ((String, String) -> Void)?
    var thinkingStateHandler: ((Bool) -> Void)?

    init(client: AIChatClient, settingsProvider: @escaping () -> PetSettings, logDirectoryPath: String) {
        self.client = client
        self.settingsProvider = settingsProvider
        self.logDirectoryPath = logDirectoryPath
        self.logURL = ChatLogStore.shared.makeLogURL(directoryPath: logDirectoryPath)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: UIConstants.chatWindowWidth, height: UIConstants.chatWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ペットとAIチャット"
        window.minSize = NSSize(width: UIConstants.chatWindowMinWidth, height: UIConstants.chatWindowMinHeight)
        super.init(window: window)
        buildUI()
        append("ペット", "こんにちは。今日のこと、作業の相談、ちょっとした雑談まで何でもどうぞ。", persist: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(prefill: String? = nil) {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let prefill, !prefill.isEmpty {
            input.stringValue = prefill
        }
        window?.makeFirstResponder(input)
    }

    func configureLogDirectoryPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != logDirectoryPath else {
            return
        }
        companionLogger.info("log directory changed to \(trimmed, privacy: .public)")
        logDirectoryPath = trimmed
        logURL = ChatLogStore.shared.makeLogURL(directoryPath: trimmed)
        persistedLineCount = 0
        didWriteSessionHeader = false
        persistLog()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        transcript.isEditable = false
        transcript.isRichText = false
        transcript.font = .systemFont(ofSize: UIConstants.chatTranscriptFontSize)
        transcript.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = transcript

        input.placeholderString = "メッセージを入力"
        input.delegate = self
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.keyEquivalent = "\r"

        let composer = NSStackView(views: [input, sendButton])
        composer.orientation = .horizontal
        composer.spacing = 8
        sendButton.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let stack = NSStackView(views: [scroll, composer])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 10
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            composer.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let movement = obj.userInfo?["NSTextMovement"] as? Int, movement == NSReturnTextMovement {
            send()
        }
    }

    @objc private func send() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, sendButton.isEnabled else { return }
        input.stringValue = ""
        messages.append(ChatMessage(role: "user", content: text))
        append("あなた", text)
        sendButton.isEnabled = false
        append("ペット", "考え中…", persist: false)
        thinkingStateHandler?(true)

        Task {
            defer {
                thinkingStateHandler?(false)
                sendButton.isEnabled = true
            }
            do {
                let response = try await client.reply(to: messages, settings: settingsProvider())
                removeThinkingLine()
                messages.append(ChatMessage(role: "assistant", content: response))
                append("ペット", response)
                responseHandler?(text, response)
            } catch {
                removeThinkingLine()
                append("エラー", error.localizedDescription, persist: false)
            }
        }
    }

    private func append(_ speaker: String, _ text: String, persist: Bool = true) {
        let entry = "\(speaker): \(text)"
        logLines.append(entry)
        transcript.string = logLines.joined(separator: "\n---\n")
        transcript.scrollToEndOfDocument(nil)
        if persist {
            persistLog()
        }
    }

    private func removeThinkingLine() {
        if !logLines.isEmpty {
            logLines.removeLast()
        }
        transcript.string = logLines.joined(separator: "\n---\n")
        transcript.scrollToEndOfDocument(nil)
    }

    private func persistLog() {
        guard let handle = try? ensureLogHandle() else { return }
        defer { try? handle.close() }

        if !didWriteSessionHeader {
            let header = [
                "# Pet Chat Log",
                "Logged: \(Self.logTimestampFormatter.string(from: sessionStartedAt))",
            ].joined(separator: "\n")
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(header.utf8))
            try? handle.write(contentsOf: Data("\n---\n".utf8))
            didWriteSessionHeader = true
        }

        guard persistedLineCount < logLines.count else { return }
        let newEntries = logLines[persistedLineCount...].joined(separator: "\n---\n")
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(newEntries.utf8))
        try? handle.write(contentsOf: Data("\n".utf8))
        persistedLineCount = logLines.count
    }

    private func ensureLogHandle() throws -> FileHandle {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        return try FileHandle(forWritingTo: logURL)
    }

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

@MainActor
final class ChatLogStore {
    static let shared = ChatLogStore()

    private init() {}

    func makeLogURL(directoryPath: String) -> URL {
        let fileManager = FileManager.default
        let inbox = resolvedDirectoryURL(from: directoryPath, defaultPath: codexPetDefaultInboxPath())
        try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: nil)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let fileName = "\(formatter.string(from: Date()))_pet.md"
        return inbox.appendingPathComponent(fileName)
    }

    func appendMarkdownEntry(directoryPath: String, speaker: String, text: String) {
        appendMarkdownEntries(directoryPath: directoryPath, entries: ["\(speaker): \(text)"])
    }

    func appendMarkdownEntries(directoryPath: String, entries: [String]) {
        let normalizedEntries = entries
            .map { normalizeLogLine($0) }
            .filter { !$0.isEmpty }
        guard !normalizedEntries.isEmpty else { return }

        let fileManager = FileManager.default
        let logURL = makeLogURL(directoryPath: directoryPath)
        let folderURL = logURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }

        let isEmpty = (try? Data(contentsOf: logURL).isEmpty) ?? true
        if isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let header = [
                "# Pet Chat Log",
                "Logged: \(formatter.string(from: Date()))",
            ].joined(separator: "\n")
            try? handle.write(contentsOf: Data(header.utf8))
            try? handle.write(contentsOf: Data("\n---\n".utf8))
        } else {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\n---\n".utf8))
        }

        let body = normalizedEntries.joined(separator: "\n---\n")
        try? handle.write(contentsOf: Data(body.utf8))
        try? handle.write(contentsOf: Data("\n".utf8))
    }

    private func normalizeLogLine(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedDirectoryURL(from rawPath: String, defaultPath: String) -> URL {
        let candidate = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = candidate.isEmpty ? defaultPath : candidate
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return codexPetProjectRootURL().appendingPathComponent(expanded, isDirectory: true)
    }
}

struct TodoItem: Identifiable {
    let id: String
    var title: String
    var dueDate: Date?
    var isDone: Bool
}

struct ScheduleItem: Identifiable {
    let id: String
    var title: String
    var date: Date
    var notes: String
}

@MainActor
final class OrganizerStore: NSObject {
    private let eventStore = EKEventStore()
    private let legacyURL: URL
    private(set) var todos: [TodoItem] = []
    private(set) var schedules: [ScheduleItem] = []
    var onChange: (() -> Void)?

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        legacyURL = homeDirectory.appendingPathComponent(".codex/pet-standalone/organizer.json")
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreChanged),
            name: .EKEventStoreChanged,
            object: eventStore
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func requestAccessAndReload() async throws {
        let remindersGranted = try await eventStore.requestFullAccessToReminders()
        let eventsGranted = try await eventStore.requestFullAccessToEvents()
        guard remindersGranted, eventsGranted else {
            throw OrganizerError.accessDenied
        }
        try migrateLegacyItemsIfNeeded()
        await reload()
    }

    func reload() async {
        async let reminders = loadReminders()
        let events = loadEvents()
        todos = await reminders
        schedules = events
        onChange?()
    }

    func addTodo(title: String, dueDate: Date?) throws {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        }
        try eventStore.save(reminder, commit: true)
    }

    func toggleTodo(at index: Int) throws {
        guard todos.indices.contains(index),
              let reminder = eventStore.calendarItem(withIdentifier: todos[index].id) as? EKReminder else { return }
        reminder.isCompleted.toggle()
        reminder.completionDate = reminder.isCompleted ? Date() : nil
        try eventStore.save(reminder, commit: true)
    }

    func removeTodo(at index: Int) throws {
        guard todos.indices.contains(index),
              let reminder = eventStore.calendarItem(withIdentifier: todos[index].id) as? EKReminder else { return }
        try eventStore.remove(reminder, commit: true)
    }

    func addSchedule(title: String, date: Date, notes: String) throws {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = date
        event.endDate = date.addingTimeInterval(3600)
        event.notes = notes
        event.calendar = eventStore.defaultCalendarForNewEvents
        event.addAlarm(EKAlarm(relativeOffset: -300))
        try eventStore.save(event, span: .thisEvent, commit: true)
    }

    func removeSchedule(at index: Int) throws {
        guard schedules.indices.contains(index),
              let event = eventStore.event(withIdentifier: schedules[index].id) else { return }
        try eventStore.remove(event, span: .thisEvent, commit: true)
    }

    private func loadReminders() async -> [TodoItem] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: eventStore.predicateForReminders(in: nil)) { reminders in
                Task { @MainActor in
                    let items = (reminders ?? []).compactMap { reminder -> TodoItem? in
                        let id = reminder.calendarItemIdentifier
                        guard !id.isEmpty,
                              !reminder.isCompleted,
                              !reminder.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                        return TodoItem(
                            id: id,
                            title: reminder.title,
                            dueDate: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                            isDone: reminder.isCompleted
                        )
                    }.sorted {
                        ($0.isDone ? 1 : 0, $0.dueDate ?? .distantFuture) <
                        ($1.isDone ? 1 : 0, $1.dueDate ?? .distantFuture)
                    }
                    continuation.resume(returning: items)
                }
            }
        }
    }

    private func loadEvents() -> [ScheduleItem] {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate).map {
            ScheduleItem(
                id: $0.eventIdentifier,
                title: $0.title ?? "予定",
                date: $0.startDate,
                notes: $0.notes ?? ""
            )
        }.sorted { $0.date < $1.date }
    }

    @objc private func eventStoreChanged() {
        Task { @MainActor in await reload() }
    }

    private struct LegacyTodo: Codable {
        let id: UUID
        var title: String
        var dueDate: Date?
        var isDone: Bool
    }

    private struct LegacySchedule: Codable {
        let id: UUID
        var title: String
        var date: Date
        var notes: String
    }

    private struct LegacyPayload: Codable {
        var todos: [LegacyTodo]
        var schedules: [LegacySchedule]
    }

    private func migrateLegacyItemsIfNeeded() throws {
        let key = "CodexPetStandalone.EventKitMigration.v1"
        guard !UserDefaults.standard.bool(forKey: key),
              let data = try? Data(contentsOf: legacyURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(LegacyPayload.self, from: data) else {
            UserDefaults.standard.set(true, forKey: key)
            return
        }
        for item in payload.todos {
            let reminder = EKReminder(eventStore: eventStore)
            reminder.title = item.title
            reminder.calendar = eventStore.defaultCalendarForNewReminders()
            reminder.isCompleted = item.isDone
            reminder.completionDate = item.isDone ? Date() : nil
            if let date = item.dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            }
            try eventStore.save(reminder, commit: false)
        }
        for item in payload.schedules {
            let event = EKEvent(eventStore: eventStore)
            event.title = item.title
            event.startDate = item.date
            event.endDate = item.date.addingTimeInterval(3600)
            event.notes = item.notes
            event.calendar = eventStore.defaultCalendarForNewEvents
            try eventStore.save(event, span: .thisEvent, commit: false)
        }
        try eventStore.commit()
        UserDefaults.standard.set(true, forKey: key)
    }
}

enum OrganizerError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        "リマインダーとカレンダーへのアクセスを許可してください。"
    }
}

final class PetNotificationService: NSObject, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func schedule(title: String, body: String, date: Date, id: UUID) {
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger))
    }

    func cancel(id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
final class OrganizerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: OrganizerStore
    private let notifications: PetNotificationService
    private let todoTable = NSTableView()
    private let scheduleTable = NSTableView()

    init(store: OrganizerStore, notifications: PetNotificationService) {
        self.store = store
        self.notifications = notifications
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: UIConstants.organizerWindowWidth, height: UIConstants.organizerWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Todo・スケジュール"
        window.minSize = NSSize(width: UIConstants.organizerWindowMinWidth, height: UIConstants.organizerWindowMinHeight)
        super.init(window: window)
        buildUI()
        store.onChange = { [weak self] in
            self?.todoTable.reloadData()
            self?.scheduleTable.reloadData()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            do {
                try await store.requestAccessAndReload()
            } catch {
                showError(error)
            }
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        todoTable.identifier = NSUserInterfaceItemIdentifier("todos")
        scheduleTable.identifier = NSUserInterfaceItemIdentifier("schedules")
        let todoPanel = makePanel(
            title: "リマインダー",
            table: todoTable,
            addAction: #selector(addTodo),
            removeAction: #selector(removeTodo),
            openAction: #selector(openRemindersApp)
        )
        let schedulePanel = makePanel(
            title: "カレンダー",
            table: scheduleTable,
            addAction: #selector(addSchedule),
            removeAction: #selector(removeSchedule),
            openAction: #selector(openCalendarApp)
        )
        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(todoPanel)
        split.addArrangedSubview(schedulePanel)
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            split.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    private func makePanel(title: String, table: NSTableView, addAction: Selector, removeAction: Selector, openAction: Selector) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main")))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        let add = NSButton(title: "追加", target: self, action: addAction)
        let remove = NSButton(title: "削除", target: self, action: removeAction)
        let refresh = NSButton(title: "再読込", target: self, action: #selector(refreshFromMac))
        let open = NSButton(title: "\(title)を開く", target: self, action: openAction)
        let buttons = NSStackView(views: [add, remove, refresh, open])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [titleLabel, scroll, buttons])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -8)
        ])
        return host
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === todoTable ? store.todos.count : store.schedules.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        if tableView === todoTable {
            let item = store.todos[row]
            let due = item.dueDate.map { "  •  \(Self.dateFormatter.string(from: $0))" } ?? ""
            label.stringValue = "\(item.isDone ? "✓" : "○") \(item.title)\(due)"
        } else {
            let item = store.schedules[row]
            label.stringValue = "\(Self.dateFormatter.string(from: item.date))  \(item.title)"
        }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table === todoTable, table.selectedRow >= 0 else { return }
        do {
            try store.toggleTodo(at: table.selectedRow)
            Task { await store.reload() }
        } catch {
            showError(error)
        }
    }

    @objc private func addTodo() {
        presentEntrySheet(title: "Todoを追加", dateRequired: false) { [weak self] title, date, _ in
            guard let self else { return }
            do {
                try self.store.addTodo(title: title, dueDate: date)
                Task { await self.store.reload() }
            } catch {
                self.showError(error)
            }
        }
    }

    @objc private func removeTodo() {
        let row = todoTable.selectedRow
        guard row >= 0 else { return }
        do {
            try store.removeTodo(at: row)
            Task { await store.reload() }
        } catch {
            showError(error)
        }
    }

    @objc private func addSchedule() {
        presentEntrySheet(title: "予定を追加", dateRequired: true) { [weak self] title, date, notes in
            guard let self, let date else { return }
            do {
                try self.store.addSchedule(title: title, date: date, notes: notes)
                Task { await self.store.reload() }
            } catch {
                self.showError(error)
            }
        }
    }

    @objc private func removeSchedule() {
        let row = scheduleTable.selectedRow
        guard row >= 0 else { return }
        do {
            try store.removeSchedule(at: row)
            Task { await store.reload() }
        } catch {
            showError(error)
        }
    }

    @objc private func refreshFromMac() {
        Task {
            do {
                try await store.requestAccessAndReload()
            } catch {
                showError(error)
            }
        }
    }

    @objc private func openRemindersApp() {
        openSystemApp(bundleIdentifier: "com.apple.reminders", fallbackPath: "/System/Applications/Reminders.app")
    }

    @objc private func openCalendarApp() {
        openSystemApp(bundleIdentifier: "com.apple.iCal", fallbackPath: "/System/Applications/Calendar.app")
    }

    private func openSystemApp(bundleIdentifier: String, fallbackPath: String) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.open(appURL)
            return
        }
        let fallbackURL = URL(fileURLWithPath: fallbackPath)
        if FileManager.default.fileExists(atPath: fallbackURL.path) {
            NSWorkspace.shared.open(fallbackURL)
            return
        }
        NSSound.beep()
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }

    private func presentEntrySheet(
        title: String,
        dateRequired: Bool,
        completion: @escaping (String, Date?, String) -> Void
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "キャンセル")
        let titleField = NSTextField()
        titleField.placeholderString = "タイトル"
        let datePicker = NSDatePicker()
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.dateValue = Date().addingTimeInterval(3600)
        let notesField = NSTextField()
        notesField.placeholderString = "メモ（任意）"
        let stack = NSStackView(views: [titleField, datePicker, notesField])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 92)
        alert.accessoryView = stack
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let value = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            completion(value, dateRequired || datePicker.dateValue > Date() ? datePicker.dateValue : nil, notesField.stringValue)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
}

enum PetAssetGeneratorError: LocalizedError {
    case cannotLoadImage
    case cannotCreateImage

    var errorDescription: String? {
        switch self {
        case .cannotLoadImage: return "画像を読み込めませんでした。"
        case .cannotCreateImage: return "スプライト画像を作成できませんでした。"
        }
    }
}

final class PetAssetGenerator {
    private let petsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/pets")
    private let frameSize = PetAnimationConstants.spritesheetFrameSize
    private let columns = PetAnimationConstants.spriteColumns
    private let rows = PetAnimationConstants.spriteRows

    func generate(from sourceURL: URL, displayName: String) throws -> String {
        guard let source = NSImage(contentsOf: sourceURL) else {
            throw PetAssetGeneratorError.cannotLoadImage
        }
        let id = "custom-\(UUID().uuidString.lowercased())"
        let directory = petsRoot.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sheetURL = directory.appendingPathComponent("spritesheet.png")
        let sourceCopy = directory.appendingPathComponent("source.\(sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension)")
        try? FileManager.default.copyItem(at: sourceURL, to: sourceCopy)

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(frameSize.width) * columns,
            pixelsHigh: Int(frameSize.height) * rows,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw PetAssetGeneratorError.cannotCreateImage
        }

        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw PetAssetGeneratorError.cannotCreateImage
        }
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
        for row in 0..<rows {
            for column in 0..<columns {
                drawFrame(source: source, row: row, column: column)
            }
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PetAssetGeneratorError.cannotCreateImage
        }
        try png.write(to: sheetURL, options: .atomic)
        let manifest: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "description": "アップロード画像から生成したデスクトップペット",
            "spritesheetPath": "spritesheet.png"
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("pet.json"), options: .atomic)
        return id
    }

    private func drawFrame(source: NSImage, row: Int, column: Int) {
        let x = CGFloat(column) * frameSize.width
        let y = CGFloat(rows - row - 1) * frameSize.height
        let phase = CGFloat(column) / CGFloat(columns)
        let bob = sin(phase * .pi * 2) * (row == 0 ? 3 : 8)
        let horizontal: CGFloat = row == 1 ? CGFloat(column) * 2 : row == 2 ? -CGFloat(column) * 2 : 0
        let scale: CGFloat = row == 4 ? 1 + 0.04 * sin(phase * .pi * 2) : 1
        let base = NSRect(x: x + 22 + horizontal, y: y + 22 + bob, width: 212 * scale, height: 212 * scale)
        let sourceRect = aspectFillRect(imageSize: source.size)
        source.draw(in: base, from: sourceRect, operation: .sourceOver, fraction: 1)
        drawExpression(row: row, frame: NSRect(x: x, y: y, width: 256, height: 256), phase: phase)
    }

    private func aspectFillRect(imageSize: CGSize) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let targetRatio = frameSize.width / frameSize.height
        let ratio = imageSize.width / imageSize.height
        if ratio > targetRatio {
            let width = imageSize.height * targetRatio
            return NSRect(x: (imageSize.width - width) / 2, y: 0, width: width, height: imageSize.height)
        }
        let height = imageSize.width / targetRatio
        return NSRect(x: 0, y: (imageSize.height - height) / 2, width: imageSize.width, height: height)
    }

    private func drawExpression(row: Int, frame: NSRect, phase: CGFloat) {
        let symbol: String
        let color: NSColor
        switch row {
        case 4: symbol = "♥"; color = .systemPink
        case 5: symbol = "⚡"; color = .systemRed
        case 6: symbol = "●"; color = .systemBlue
        case 7: symbol = "!"; color = .systemYellow
        case 8: symbol = "✦"; color = .systemPurple
        default: return
        }
        let alpha = 0.55 + 0.35 * sin(phase * .pi)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .bold),
            .foregroundColor: color.withAlphaComponent(alpha)
        ]
        NSAttributedString(string: symbol, attributes: attributes)
            .draw(at: NSPoint(x: frame.maxX - 52, y: frame.maxY - 54))
    }
}
