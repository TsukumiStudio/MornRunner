# MornRunner

GitHub Actions の self-hosted ランナーを **セットアップして、メニューバーから管理する** macOS アプリです。
macOS 14 以降、Apple Silicon / Intel 両対応。特定の Organization やリポジトリに依存しません。

## インストール

Homebrew からインストールできます。

```sh
brew install --cask tsukumistudio/tap/mornrunner
```

ZIP 版は `MornRunner.app` を `~/Applications` または `/Applications` にコピーして開きます。
配布用 ZIP は Developer ID 署名・Apple 公証済みです。

## ランナーを新しく設定する

1. メニューバーから「新しいランナーを設定」を開きます。
2. GitHub の Organization またはリポジトリの URL を入力します。`owner` / `owner/repository` の形式でも指定できます。
3. ランナー名、必要なら追加ラベルと保存先を設定します。
4. 「GitHub の登録画面を開く」から Configure 欄の `--token` の値をコピーします。GitHub CLI がログイン済みなら「GitHub CLI で取得」も使えます。
5. 「セットアップして起動」を押します。

この Mac の CPU に合った公式ランナーをダウンロードし、SHA-256 検証、GitHub への登録、ログイン時に起動するサービスの設定、起動・接続確認まで進めます。完了画面から `runs-on` の設定例をコピーできます。

GitHub 側で登録先の管理権限が必要です。登録トークンの有効期限は 1 時間。入力したトークンはアプリの設定に保存せず、登録プロセスに環境変数で渡します。GitHub CLI の権限変更は自動では行いません。
登録先は **github.com の Organization／リポジトリ** に対応しています。GitHub Enterprise Server、Linux、Windows のセットアップは対象外です。

既存フォルダや同名の登録済みランナーは上書きしません。途中で失敗した場合は、同じ登録先・名前・ラベル・保存先で再試行できます。GitHub 登録後にサービス設定が失敗した場合も、登録済みランナーを追加し「サービスを設定して起動」で再開できます。

## 既存ランナーの管理

- `~/actions-runner` とユーザーの LaunchAgents にある公式ランナーを検出します。
- 「既存を追加…」で別のフォルダも追加できます。複数ランナーは選択して切り替えます。
- 選択中のランナーについて、停止中 / 接続中 / 待機中 / ジョブ実行中 / 接続エラーを 5 秒ごとに更新します。
- ランナーの起動・停止、診断ログ・GitHub ページの表示に対応します。
- 「ログイン時に MornRunner を起動」は監視アプリの自動起動です。ランナー自身のサービス設定とは別です。
- 監視アプリを終了・更新しても、ランナーは動き続けます。

状態はプロセスの生存と現在の起動以降の診断ログからローカルで判定します。GitHub API によるオンライン確認ではないため、切断がログに出るまでは表示が遅れる場合があります。ログ末尾 512 KiB に状態イベントがない場合は接続確認中と表示します。Mac のスリープ中やログアウト中は監視できません。

## アプリを更新する

メニューバーの「最新を確認」→「最新へ更新」→「再起動して適用」で更新できます。

- `/Applications` にある Homebrew 管理版は `brew update` / `brew upgrade --cask tsukumistudio/tap/mornrunner` を使用します。
- ZIP 版は公開 Release の ZIP をダウンロードし、SHA-256、Bundle ID、バージョン、同じ Developer ID チームの署名、Apple 公証を確認してから差し替えます。保存先に書き込み権限が必要です。
- 未公開・通信エラー・更新配信前などの場合は理由を表示し、再確認できます。
- 更新するのは MornRunner アプリです。GitHub Actions ランナー本体は公式ランナーの自動更新に従います。

```sh
brew update
brew upgrade --cask tsukumistudio/tap/mornrunner
```

アンインストールは `brew uninstall --cask mornrunner`。ランナーの登録・作業データ・サービスはアプリのアンインストールでは削除しません。

## ビルド・検証

Swift 6 以降の Xcode / Command Line Tools を使用します。

```sh
swift test
zsh build.sh
UNIVERSAL=1 zsh build.sh
open dist/MornRunner.app
# UI と同じ読み取り専用の状態確認
dist/MornRunner.app/Contents/MacOS/MornRunner --status
```

出力は `dist/MornRunner.app` と `dist/MornRunner.app.zip`。通常ビルドは ad-hoc 署名です。

古い Command Line Tools の private interface や SwiftBridging 定義が残っている環境では、次の補助スクリプトを使用できます。システムの開発ツールを変更せず、`.build` 内のコピーと仮想ファイルシステムで回避します。

```sh
bash Support/with-local-toolchain.sh swift test
UNIVERSAL=1 bash Support/with-local-toolchain.sh zsh build.sh
# ログイン済み Mac で一時 LaunchAgent の起動・停止も検証（実ランナーには触れません）
MORN_RUN_SERVICE_TEST=1 bash Support/with-local-toolchain.sh swift test
```

## 署名・リリース・Homebrew

MornDesktopTube と同じ SwiftUI / Swift Package / `.app` 構成で、`matsufriends/MornNotary` による署名・公証を使用します。

```sh
bash /path/to/MornNotary/sign.sh dist/MornRunner.app
```

`dist/MornRunner-signed.zip` が生成されます。GitHub Release に載せる際のファイル名は **MornRunner.app.zip** です。

タグからの自動リリースは初期状態では無効です。リポジトリの Actions Secrets に `MORN_NOTARY_TOKEN` と `HOMEBREW_TAP_TOKEN`、Actions Variable に `MORN_RELEASE_AUTOMATION=true` を設定すると、`v0.2.0` などのタグを push すると、テスト → Universal ビルド → 署名・公証 → Release 公開 → `TsukumiStudio/homebrew-tap` の `Casks/mornrunner.rb` 更新を行います。手動実行は成果物の生成・Tap への書き込み権限確認までです。

`Support/mornrunner.rb.in` にバージョンと公開 ZIP の SHA-256 を反映して Cask を生成します。公開 Release が存在するまでアプリの「最新を確認」は未公開と表示します。

## 構成

- `MornRunnerApp.swift`: メニューバー・複数ランナーの切り替え
- `SetupView.swift` / `RunnerSetup.swift`: セットアップ画面・導入処理
- `RunnerProfiles.swift` / `RunnerStatus.swift`: 既存ランナーの検出・監視・サービス操作
- `Updater.swift`: Homebrew / ZIP 版の更新
- `Tests`: 登録先・上書き防止・SHA-256・更新状態・サービスの検証
- `build.sh` / `.github/workflows/release.yml`: アプリ生成・配布

参考: [GitHub のランナー追加手順](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)、[Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)。
