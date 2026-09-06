# Desktop Pet

Codexとは別プロセスで動く、macOS用の常駐デスクトップペットです。ペット素材は `~/.codex/pets` に保存します。

## 主な機能

- 透明・常時最前面のペット表示（全デスクトップ対応）
- 静止、左右移動、上下運動、喜び・怒り・悲しみ・驚き・愛情アニメーション
- 画像アップロードから8フレーム×9行のスプライトを自動生成
- codex、claudeCode、Gemini、SAKANA FUGU、Ollama、Hermes Agentを選べる内蔵AIチャット
- APIキーはプロジェクト直下の `.env` から読み込み
- Todo・スケジュール管理とmacOS通知
- 日本語の日常会話、音声認識、音声読み上げ
- メニューバー、右クリックメニュー、音声ショートカット
- ペットをクリックすると、モデル名・音声入力・送信ボタン付きの入力吹き出しを表示
- ペットと入力吹き出し以外をクリックすると入力欄を自動で閉じる
- 設定画面から通知の表示時間・横幅・高さを変更可能
- 設定画面から会話ログの保存先と `.env` ファイルの場所を変更可能
- チャットの通話ログは `00_INBOX/YYYYMMDD_HHmmss_pet` に保存

## Hermes Agentを使う

DXP-2800上でHermes AgentのAPIサーバーが動作していることを確認し、プロジェクト直下の `.env` にAPIキーを設定します。

```env
HERMES_API_KEY=<DXP-2800のAPI_SERVER_KEY>
```

アプリの設定画面でAIモデルに `Hermes Agent` を選択します。

- 既定の接続先：`http://DXP2800-86A5.local:8642/v1/chat/completions`
- 既定のモデル：`hermes-agent`
- API形式：OpenAI互換 Chat Completions
- 認証方式：`Authorization: Bearer <HERMES_API_KEY>`

接続先は設定画面で変更できます。`.env` は公開リポジトリへコミットしないでください。

疎通確認：

```sh
curl -fsS http://DXP2800-86A5.local:8642/v1/health
```

正常時は `"status": "ok"` を含むJSONが返ります。接続できない場合は、MacとDXP-2800が同じネットワークまたはTailscale上にあること、Hermesコンテナの8642番ポートが公開されていることを確認してください。

## Run

```sh
./script/build_and_run.sh
```

CodexアプリのRunボタンも同じスクリプトを実行します。

The app opens a transparent floating pet window. Click the pet for everyday conversation. Drag the pet to move it. Right-click the pet, or use the menu bar Pet item, to open AI chat, Todo/schedule, animations, settings, and quit.

Use Settings > Open Settings Window... to upload a pet image, choose the pet and size, configure AI, voice, notifications, and edit Japanese conversation messages.

`codex` と `claudeCode` はローカルCLIを使用します。GeminiはGemini CLIが必要です。SAKANA FUGU、Ollama、Hermes AgentはHTTP APIを使用します。

APIキーは `.env` に設定します。SAKANA FUGUでは `SAKANA_API_KEY` または `SAKANA_FUGU_API_KEY`、Hermes Agentでは `HERMES_API_KEY` を使用します。

日常会話欄の文章は生成例として利用されます。表示時には毎回、例と直近の発言に重複しない新しい会話を生成します。

Clicking the pet advances the everyday conversation. When voice is enabled, the pet speaks the message, listens for your reply, shows the recognized text, and speaks a short response. Voice can be toggled from the menu or with the configured shortcut.

## Settings

Settings are created automatically at:

```txt
~/.codex/pet-standalone/settings.json
```

Example:

```json
{
  "chatCommand": ["/usr/bin/open", "-a", "Codex"],
  "aiEndpoint": "http://DXP2800-86A5.local:8642/v1/chat/completions",
  "aiModel": "hermes-agent",
  "aiProvider": "Hermes Agent",
  "idleConversationDelaySeconds": 90,
  "idleConversationEnabled": true,
  "idleConversationMessages": [
    "今日の空模様、少し気になりますね。外に出る前に天気を確認しておきますか？",
    "いま世の中で何が動いているか、気になるニュースを一つだけ見てみるのも良さそうです。",
    "AIニュースは流れが速いですね。今日の進展を軽く追ってみますか？",
    "雑学です。人は小さな未完了を減らすだけで、かなり頭が軽くなるそうです。",
    "禅語に『喫茶去』があります。まあ一服して、今ここに戻りましょう、という感じです。",
    "偉人の言葉を一つ。小さく始める人が、遠くまで進むことがあります。"
  ],
  "notificationFile": "",
  "notificationText": "",
  "preferredPetID": "hovi",
  "size": 168,
  "voiceEnabled": false,
  "voiceIdentifier": "com.apple.speech.synthesis.voice.kyoko",
  "voiceToggleShortcut": "cmd+shift+v"
}
```

Set `preferredPetID` or use Settings > Pet Type to change pets. Set `size` or use Settings > Size to resize. Set `notificationText` or point `notificationFile` at a text file to show a speech bubble when the message changes. When `idleConversationEnabled` is true, the pet starts a small Japanese everyday conversation after `idleConversationDelaySeconds` of no interaction. Good topics include weather, current events, news, trivia, AI news, Zen phrases, and quotes.

Set `voiceEnabled` to enable speech. `voiceIdentifier` is selected from the voices installed on macOS. `voiceToggleShortcut` uses a format such as `cmd+shift+v`, `ctrl+option+v`, or `cmd+shift+s`. macOS may ask for microphone and speech recognition permissions the first time listening starts.

設定画面で `.env` ファイルを変更した場合は、そのファイル内に `HERMES_API_KEY` を設定してください。APIキーそのものは `settings.json` へ保存されません。

## Build an app bundle

```sh
./scripts/package-app.sh
open dist/CodexPetStandalone.app
```

The package script also installs a double-clickable app bundle at:

```txt
~/Applications/Codex Pet.app
```

This app reads `pet.json` and `spritesheet.webp` from each directory under `~/.codex/pets`. It does not patch or depend on the signed Codex.app bundle.
