# Desktop Pet（codex-pet-standalone）仕様書

**作成日：** 2026年6月25日

**最終更新：** 2026年9月6日

**アプリバージョン：** 0.2.0

## 1. プロジェクト概要

`codex-pet-standalone` は、Codexとは別プロセスで動作するmacOS用デスクトップペットです。透明なフローティングウィンドウにペットを表示し、AIとの会話、音声入出力、Todo・スケジュール管理、通知を提供します。

- 対応OS：macOS 14以降
- 実装言語：Swift 6
- UI：AppKit
- パッケージ管理：Swift Package Manager
- 配布形式：署名済みmacOSアプリバンドル

## 2. 主な機能

### 2.1 ペット表示・操作

- 透明・常時最前面・全デスクトップ対応のペットウィンドウ
- ドラッグ移動およびサイズ変更
- 静止、左右移動、上下運動、喜び・怒り・悲しみ・驚き・愛情アニメーション
- 画像から8フレーム×9行のスプライトを生成
- `~/.codex/pets` 内のペット素材を選択

### 2.2 AIチャット

次のプロバイダーを設定画面から選択できます。

| プロバイダー | 接続方式 | 認証・前提 |
|---|---|---|
| codex | ローカルCodex CLI | Codex CLIが利用可能であること |
| claudeCode | ローカルClaude Code CLI | Claude Code CLIが利用可能であること |
| Gemini | ローカルGemini CLI | Gemini CLIが利用可能であること |
| SAKANA FUGU | Responses互換HTTP API | `.env` のSakana APIキー |
| Ollama | OpenAI互換HTTP API | 既定ではローカルOllama、認証なし |
| Hermes Agent | OpenAI互換Chat Completions API | `.env` の `HERMES_API_KEY` |

会話にはシステムプロンプト、直近のメッセージ、指定されたRAGファイルの内容を渡します。応答および会話ログは日本語利用を前提とします。

### 2.3 音声機能

- macOS Speech Recognitionによる音声入力
- AVSpeechSynthesizerによる音声読み上げ
- 音声入出力の個別オン・オフ
- 音声ショートカットの設定

### 2.4 Todo・スケジュール

- Todoリスト管理
- スケジュール表示
- macOS Reminders／Calendar連携
- macOS通知

### 2.5 UI・操作

- メニューバーおよび右クリックメニュー
- ペットクリックでモデル名・音声入力・送信ボタン付き入力吹き出しを表示
- AIチャット、Todo／スケジュール、アニメーション、設定、終了操作
- 通知表示時間、サイズ、文字サイズ、入力吹き出し幅の設定

## 3. Hermes Agent連携仕様

### 3.1 接続先

DXP-2800上で動作するHermes Agent APIサーバーへ、MacからローカルネットワークまたはTailscale経由で接続します。

| 項目 | 既定値 |
|---|---|
| プロバイダー名 | `Hermes Agent` |
| エンドポイント | `http://DXP2800-86A5.local:8642/v1/chat/completions` |
| モデル | `hermes-agent` |
| API形式 | OpenAI互換Chat Completions |
| 認証 | Bearerトークン |
| APIキー環境変数 | `HERMES_API_KEY` |

設定画面ではHermesの接続先URLを編集できます。モデル名は `hermes-agent` を使用します。

### 3.2 リクエスト

HTTP `POST` で次の情報を送信します。

- `Content-Type: application/json`
- `Accept: application/json`
- `Authorization: Bearer <HERMES_API_KEY>`
- `model`: `hermes-agent`
- `stream`: `false`
- `messages`: システムプロンプトと会話履歴

### 3.3 APIキー管理

プロジェクト直下、設定画面で指定したファイル、またはホームディレクトリの `.env` から `HERMES_API_KEY` を読み込みます。プロセス環境変数が設定されている場合は環境変数を優先します。

```env
HERMES_API_KEY=<DXP-2800のAPI_SERVER_KEY>
```

APIキーは `settings.json`、ログ、ソースコードへ保存しません。`.env` はGit管理対象に含めないでください。

### 3.4 macOSローカルネットワーク対応

配布アプリの `Info.plist` に以下を設定します。

- `NSAppTransportSecurity.NSAllowsLocalNetworking = true`
- `NSLocalNetworkUsageDescription`

これにより、HTTPの `.local` エンドポイントへ接続できます。初回接続時にmacOSがローカルネットワーク利用許可を求める場合があります。

### 3.5 エラー処理

- URL不正：接続先URLエラーを表示
- `HERMES_API_KEY` 未設定：`.env` への設定を案内
- HTTPエラー：Hermes APIが返したエラー内容を表示
- 応答本文なし：読み取れる返答がないことを表示

## 4. データと設定

### 4.1 設定ファイル

設定は以下にJSON形式で保存します。

```text
~/.codex/pet-standalone/settings.json
```

主なAI設定：

```json
{
  "aiProvider": "Hermes Agent",
  "aiEndpoint": "http://DXP2800-86A5.local:8642/v1/chat/completions",
  "aiModel": "hermes-agent",
  "dotenvFilePath": "/Users/<user>/codex-pet-standalone/.env"
}
```

### 4.2 会話ログ

既定ではHOVIX保管庫の `00_INBOX` に `YYYYMMDD_HHmmss_pet` 形式で保存します。保存先は設定画面から変更できます。

### 4.3 RAGファイル

設定されたファイルのうち最大5件を読み込み、各ファイルの内容を最大1,200文字に整形してプロンプトへ追加します。

## 5. プロジェクト構成

| パス | 役割 |
|---|---|
| `Package.swift` | Swiftパッケージ定義 |
| `Sources/CodexPetStandalone/main.swift` | アプリ、ウィンドウ、設定UI、イベント処理 |
| `Sources/CodexPetStandalone/CompanionFeatures.swift` | AIクライアント、秘密情報読込、Todo等の付随機能 |
| `Sources/CodexPetStandalone/SettingsManagement.swift` | 設定モデル、保存、移行、正規化 |
| `Sources/CodexPetStandalone/Constants.swift` | UI、AIプロバイダー等の定数 |
| `script/build_and_run.sh` | 開発ビルドと起動 |
| `scripts/package-app.sh` | Releaseビルド、署名、アプリのインストール |
| `dist/` | パッケージ済みアプリ |
| `.env` | APIキー。Gitへコミットしない |

## 6. ビルド・インストール

### 6.1 開発実行

```sh
./script/build_and_run.sh
```

### 6.2 アプリの再パッケージ

```sh
./scripts/package-app.sh
```

スクリプトはReleaseビルドを作成し、アドホック署名を行って次の2か所へ配置します。

- `dist/CodexPetStandalone.app`
- `~/Applications/Codex Pet.app`

## 7. Hermes Agentの動作確認

認証不要のヘルスチェック：

```sh
curl -fsS http://DXP2800-86A5.local:8642/v1/health
```

認証付きモデル一覧：

```sh
curl -fsS \
  -H "Authorization: Bearer $HERMES_API_KEY" \
  http://DXP2800-86A5.local:8642/v1/models
```

接続できない場合は以下を確認します。

1. Macから `DXP2800-86A5.local` を名前解決できること
2. MacとDXP-2800が同じネットワークまたはTailscale上にあること
3. Hermesコンテナの8642番ポートが公開されていること
4. `.env` の `HERMES_API_KEY` がDXP-2800の `API_SERVER_KEY` と一致すること
5. macOSの「ローカルネットワーク」でCodex Petが許可されていること

## 8. セキュリティ

- APIキーをソースコード、README、仕様書、`settings.json` に記載しない
- `.env` を公開リポジトリへコミットしない
- Hermes APIは `API_SERVER_KEY` によるBearer認証を必須とする
- DXP-2800の8642番ポートは信頼できるLANまたはTailscale内に限定する
- APIキーを変更した場合は `.env` も更新する

## 9. 更新履歴

| 日付 | バージョン | 内容 |
|---|---|---|
| 2026-09-06 | 0.2.0 | DXP-2800上のHermes Agent連携、Bearer認証、ローカルネットワーク許可を追加 |
| 2026-06-25 | 0.1.0 | 初版 |
