# MornRunner

GitHub Actions の self-hosted ランナーを、Mac のメニューバーから**作って・見て・止める**アプリです。

- ターミナルを開かずに、新しいランナーを登録してサービスとして常駐させられます
- 登録済みのランナーを自動で見つけ、全部の状態を一覧で表示します
- 選んだランナーの状態アイコンをメニューバーに並べておけます

macOS 14 以降、Apple Silicon / Intel 両対応。github.com の Organization・リポジトリのどちらにも使えます。

## インストール

```sh
brew install --cask tsukumistudio/tap/mornrunner
```

Homebrew を使わない場合は [Releases](https://github.com/TsukumiStudio/MornRunner/releases/latest) から `MornRunner.app.zip` をダウンロードし、展開した `MornRunner.app` を `/Applications` に置いて開きます（Developer ID 署名・Apple 公証済み）。

起動するとメニューバーにアイコンが出ます。Dock には出ません。

## はじめてランナーを作る

用意するもの: 登録先の Organization またはリポジトリの**管理者権限**。

1. メニューバーのアイコン →「新規設定」
2. 登録先を入力（`https://github.com/owner/repo`、`owner/repo`、`owner` のどれでも可）
3. ランナー名を決める。必要ならラベルと保存先も
4. 登録トークンを入れる
   - 「GitHub で取得」で開くページの Configure 欄から、`--token` の後ろの値をコピー
   - GitHub CLI (`gh`) にログイン済みなら「CLI で取得」で自動入力
5. 「登録して起動」

あとは自動で進みます: 公式ランナーのダウンロードと SHA-256 検証 → GitHub への登録 → ログイン時に起動するサービスの設定 → 接続確認。
完了画面からワークフローに書く `runs-on` の例をコピーできます。

```yaml
jobs:
  build:
    runs-on: [self-hosted, macOS, ARM64]
```

- 登録トークンの有効期限は 1 時間です。トークンはアプリに保存しません
- 既存のフォルダや同名のランナーは上書きしません。途中で失敗しても、同じ内容でもう一度押せば続きから再開します

## すでにあるランナーを使う

`~/actions-runner` と、`~/Library/LaunchAgents` に登録された公式ランナーは自動で一覧に出ます。
それ以外の場所にあるランナーは「既存を追加…」でフォルダ（`.runner` があるフォルダ）を選びます。

サービス未設定のランナーには「サービスを設定して起動」ボタンが出ます。

## 毎日の使い方

### 一覧

メニューバーのアイコンをクリックすると、全ランナーがカードで並びます。状態は 5 秒ごとに更新されます。

| 表示 | 意味 |
| --- | --- |
| 🟢 待機中 | ジョブを待っている |
| 🔵 ジョブ実行中 | ジョブを実行している（ジョブ名も表示） |
| 🟠 接続中 | 起動直後、または GitHub との接続を確認中 |
| 🔴 接続エラー | GitHub と通信できていない |
| ⚪ 停止中 | ランナーが止まっている |

各カードのボタン: 起動 / 停止 / アクティビティ / ログ / GitHub ページ。

### メニューバー

カードの「メニューバー」にチェックしたランナーの状態アイコンが、メニューバーに横並びで出ます。新しく追加したランナーは最初からチェックが入っています。

### アクティビティ

カードのアクティビティボタンで、ジョブの進捗・履歴、接続エラーとスリープの記録（直近 14 日）、診断ログを見られます。

## 更新・アンインストール

アプリ内の「最新を確認」→「最新へ更新」→「再起動して適用」で更新できます。Homebrew なら次でも同じです。

```sh
brew update
brew upgrade --cask tsukumistudio/tap/mornrunner
```

アンインストール:

```sh
brew uninstall --cask mornrunner
```

アプリを終了・更新・アンインストールしても**ランナー自体は動き続けます**。ランナーの登録やサービスは削除しません。

## よくある質問

**Mac を再起動したらランナーは動く？**
動きます。ランナーはサービスとして登録されるので、ログインすれば自動で起動します。アプリの「ログイン時に起動」は、このアプリ（監視画面）の自動起動の設定で、ランナーとは別です。

**状態はどうやって判定している？**
ランナーのプロセスと、`_diag` フォルダの診断ログを手元で読んでいます。GitHub API は使いません。そのため切断がログに出るまで表示が遅れることがあります。接続エラーの後 5 分間エラーが出なければ、復帰したとみなして待機中に戻します。

**対応していないものは？**
GitHub Enterprise Server、Linux・Windows 上のランナーのセットアップ。Mac がスリープ中・ログアウト中の監視。

## 開発

Swift 6 以降の Xcode または Command Line Tools が必要です。

```sh
swift test
zsh build.sh                 # dist/MornRunner.app（ad-hoc 署名）
UNIVERSAL=1 zsh build.sh     # Universal ビルド
dist/MornRunner.app/Contents/MacOS/MornRunner --status   # 状態を JSON で出力
```

古い Command Line Tools で失敗する場合は `bash Support/with-local-toolchain.sh swift test` を使います（システムのツールは変更しません）。
`MORN_RUN_SERVICE_TEST=1` を付けると、一時 LaunchAgent の起動・停止も検証します（実ランナーには触れません）。

### リリース

`Support/Info.plist` のバージョンを上げて `v*` タグを push すると、GitHub Actions がテスト → Universal ビルド → MornNotary（非公開）で署名・公証 → Release 公開 → `TsukumiStudio/homebrew-tap` の Cask 更新まで行います。
必要な設定: Secrets `MORN_NOTARY_TOKEN`・`HOMEBREW_TAP_TOKEN`、Variable `MORN_RELEASE_AUTOMATION=true`。

参考: [GitHub のランナー追加手順](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)
