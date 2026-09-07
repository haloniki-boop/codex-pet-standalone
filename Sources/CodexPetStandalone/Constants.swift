import AppKit
import Foundation

struct PetAnimationConstants {
    static let frameInterval: TimeInterval = 0.12
    static let animationFrameInterval: TimeInterval = 0.1
    static let thinkingAnimationDuration: TimeInterval = 1.15

    static let spriteColumns = 8
    static let spriteRows = 9
    static let spritesheetFrameSize = CGSize(width: 256, height: 256)

    static let idleFramesIndex = 0
    static let runningFramesMinCount = 1
    static let directionalAnimationRowCount = 3
    static let leftRunningFramesRow = 2
    static let rightRunningFramesRow = 1
}

struct UIConstants {
    static let petWindowLevel: NSWindow.Level = .floating
    static let bubbleWindowLevel: NSWindow.Level = .floating
    static let panelGap: CGFloat = 14

    static let bubbleViewInsets = NSEdgeInsets(top: 2, left: 2, bottom: 8, right: 2)
    static let bubbleCornerRadius: CGFloat = 8
    static let bubbleResizeHandleSize: CGFloat = 16

    static let composerViewInsets = NSEdgeInsets(top: 2, left: 2, bottom: 9, right: 2)
    static let composerCornerRadius: CGFloat = 12
    static let composerBorderWidth: CGFloat = 1.2

    static let spriteViewInsets: CGFloat = 6
    static let minWindowSize: CGFloat = 80

    static let settingsWindowWidth: CGFloat = 560
    static let settingsWindowHeight: CGFloat = 680
    static let settingsWindowMinWidth: CGFloat = 520
    static let settingsWindowMinHeight: CGFloat = 560

    static let chatWindowWidth: CGFloat = 520
    static let chatWindowHeight: CGFloat = 560
    static let chatWindowMinWidth: CGFloat = 420
    static let chatWindowMinHeight: CGFloat = 420

    static let organizerWindowWidth: CGFloat = 720
    static let organizerWindowHeight: CGFloat = 520
    static let organizerWindowMinWidth: CGFloat = 620
    static let organizerWindowMinHeight: CGFloat = 420

    static let labelWidth: CGFloat = 150
    static let controlMinWidth: CGFloat = 320
    static let ragTableViewHeight: CGFloat = 140

    static let helpTextFontSize: CGFloat = 11
    static let sectionTitleFontSize: CGFloat = 15
    static let chatTranscriptFontSize: CGFloat = 14
    static let composerTextFontSize: CGFloat = 13
    static let bubbleTextFontSize: CGFloat = 13

    static let bubbleQueryTextColor: NSColor = .systemBlue
    static let bubbleResponseTextColor: NSColor = .labelColor
    static let bubbleHistoryMaxTurns: Int = 30

    static let screenMargin: CGFloat = 8
    static let minNotificationWidth: CGFloat = 20
    static let maxNotificationWidth: CGFloat = 600
    static let minNotificationHeight: CGFloat = 80
    static let maxNotificationHeight: CGFloat = 700
    static let minNotificationFontSize: CGFloat = 10
    static let maxNotificationFontSize: CGFloat = 64
    static let minComposerWidth: CGFloat = 120
    static let maxComposerWidth: CGFloat = 600
}

struct NotificationConstants {
    static let minDuration: TimeInterval = 1
    static let maxDuration: TimeInterval = 300
    static let defaultDuration: TimeInterval = 10
    static let defaultWidth: CGFloat = 152
    static let defaultHeight: CGFloat = 174
    static let defaultFontSize: CGFloat = 16
    static let defaultComposerWidth: CGFloat = 218

    static let preferredCharactersPerLine = 30
}

struct VoiceConstants {
    static let defaultLanguage = "ja-JP"
    static let audioBufferSize: UInt32 = 1024
}

struct SettingsConstants {
    static let supportedAIProviders = ["codex", "claudeCode", "Gemini", "SAKANA FUGU", "Ollama", "Hermes Agent", "Genspark"]
    static let supportedAIProvidersForUI = ["codex", "claudeCode", "Gemini", "SAKANA FUGU", "Ollama", "Hermes Agent", "Genspark"]

    static let minIdleDelaySeconds: TimeInterval = 10
    static let defaultIdleDelaySeconds: TimeInterval = 90

    static let minSize: Double = 80
    static let defaultSize: Double = 168

    static let settingsCheckInterval: TimeInterval = 2

    static let sakanaModels = ["fugu", "fugu-ultra"]
    static let defaultSakanaModel = "fugu"
    static let defaultOllamaModel = "llama3.1"
    static let defaultHermesModel = "hermes-agent"
    static let defaultGensparkModel = "genspark"
}

struct ExecutableConstants {
    static let codexExecutableCandidates: [String] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
        "/Applications/Codex.app/Contents/Resources/codex"
    ]

    static let claudeExecutableCandidates: [String] = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude"
    ]

    static let geminiExecutableCandidates: [String] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/gemini").path,
        "/opt/homebrew/bin/gemini",
        "/usr/local/bin/gemini"
    ]

    static let ollamaExecutableCandidates: [String] = [
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/usr/bin/ollama"
    ]
}

struct DialogConstants {
    static let defaultScreenWidth: CGFloat = 1440
    static let defaultScreenHeight: CGFloat = 900
}

struct ConversationConstants {
    static let recentMessageHistorySize = 6
    static let minGenerationAttempts = 20
    static let defaultFallbackMessage = "少し窓の外へ目を向けて、いま聞こえる音を一つ探してみませんか。短い休憩が次の集中を連れてくるかもしれません。"

    static let openings = [
        "少し肩の力を抜く時間にしませんか。",
        "ふと気になったのですが、",
        "今日の小さな発見として、",
        "作業の合間にひとつだけ。",
        "気分転換の種を見つけました。"
    ]

    static let topics = [
        "机の上を一か所だけ整えると、次の作業へ入りやすくなるそうです。",
        "温かい飲み物をゆっくり一口飲むと、思考の区切りを作りやすいですよ。",
        "今日できたことを一つ言葉にすると、意外と前進が見えてきます。",
        "遠くを見る時間を少し作ると、目だけでなく頭も休まりやすいそうです。",
        "気になるアイデアを三語だけメモしておくと、あとで育てやすくなります。",
        "一分だけ深呼吸してから戻ると、次の一手が見つかるかもしれません。"
    ]

    static let closings = [
        "今、ひとつ試してみますか？",
        "無理のないところからどうでしょう。",
        "必要なら私も一緒に考えます。",
        "小さく始めるにはちょうど良さそうです。",
        "今日はどれが合いそうですか？"
    ]
}
