# Orca バックエンドアダプタ

本ドキュメントは、`multi-agent-orchestrator` スキルの抽象オーケストレーション操作（`_contract.md` 準拠の 10 操作）を **Orca CLI**（`ORCA orchestration ...`）へマッピングするバックエンドアダプタ仕様です。

---

## 1. バックエンド概要・前提と CLI 解決 (Bootstrap)

Orca は、イベント駆動のマルチエージェント・オーケストレーション基盤を提供します。コーディネーター（司令塔）は **Run**・**Task DAG**・監視付きワーカー（**Dispatch**）を Orca CLI で管理し、ワークツリー隔離やローカル／ペアリング済みリモートサーバー実行を一貫したコマンド体系で扱います。

### 1.0 メタデータ・対応ケイパビリティ（`_contract.md` 準拠）

- **Backend ID**: `orca`（本スキルの既定バックエンド）
- **CLI 解決**: 下節 1.1 の優先順位（`ORCA_CLI_COMMAND` → `ORCA_DEV_REPO_ROOT` → Linux 管理外 `orca-ide` → `orca`）
- **事前条件・起動手順**: 下節 1.2〜1.4（`ORCA skills get orchestration`、`--environment local`、`ORCA status --json` による稼働確認）

| ケイパビリティ | Orca 対応状況 | 備考 |
|---|---|---|
| Run / Task DAG 管理 | ネイティブ対応 | `run-create`, `task-create --deps`, `task-list --ready` |
| 待機方式（`wait_strategy`） | ネイティブ対応（イベント駆動 wake） | 起動・送信後は即 end turn。ポーリング禁止 |
| ワークスペース分離 | ネイティブ対応 | Git は `--worktree new-child` / `new-top-level`、非 Git は `current`＋ファイル分割 |
| 同一 Task 再試行リンク | ネイティブ対応 | `--task <id> --retry-of <dispatch_id>` |
| エージェント・モデル・エフォート指定 | ネイティブ対応 | `--agent`, `--model`, `--effort`（`--effort` は `--model` 必須） |
| 双方向メッセージング | ネイティブ対応 | `send`, `reply`, `inbox`, `question`, `escalation`, 承認待機検知 |
| 状態・出力の一次証拠検証 | ネイティブ対応 | `worker-show`, `worker-read --source auto`, `worker-list` |
| 司令塔再起動後の Run 再接続 | ネイティブ対応 | `inbox --terminal run:<run_id>` ＋ `worker-list --run <run_id>` |
| `context-guard` 連携 | 同梱ツール対応 | `scripts/context-guard/` により `pi` / `antigravity` / `vibe` 対応、未対応エージェント時は第 2 段 `HANDOFF.md` 駆動へ劣化 |

### 1.1 `ORCA` 実行ファイルの解決（セッション開始時に 1 回）

セッションの最初に以下の優先順位で実行ファイルを 1 つ決定し、以降の全コマンドでその実行ファイルを直接置き換えて使用します（シェル変数に格納したり、文字通り `ORCA` と打ったりしないこと）。

1. 環境変数 `ORCA_CLI_COMMAND` が設定されている場合 → その値（マネージド WSL セッション等で Orca が自動設定）
2. それ以外で `ORCA_DEV_REPO_ROOT` が設定されている場合 → `orca-dev`
3. それ以外で **Linux かつ Orca 管理ターミナル外** の場合 → `orca-ide`
   - **厳守**: この環境で裸の `orca` を実行しないこと。`/usr/bin/orca`（GNOME Orca スクリーンリーダー）が起動し、ユーザー環境で音声読み上げが始まってしまう。
4. それ以外 → `orca`

選択した実行ファイルが起動できない場合は、別の実行ファイルへフォールバックせず（別ビルドの Orca を誤操作する恐れがあるため）、正確なエラー内容を報告して停止します。

### 1.2 バージョン一致ガイドの読み込み

セッション開始時に 1 回だけ次を実行し、使用中の Orca バイナリとバージョンが一致する公式オーケストレーションガイドを読み込みます。

```sh
ORCA skills get orchestration
```

- 条件付きの高度な操作（リモート配置、並列起動、障害復旧など）が必要になったときのみ、該当リファレンスを追加で読み込みます（セクション 7 参照）。
- バイナリが `--reference` に非対応の場合は `ORCA skills get orchestration --full` を使用します。

### 1.3 `--environment local` ルール（誤ルーティング防止）

シェルの `ORCA_ENVIRONMENT` やペアリングコード（`ORCA_PAIRING_CODE`）によってコマンドが意図せずリモート Orca へ流れるのを防ぐため、以下を徹底します。

- **ローカル実行のワーカー起動**および、その Run の **作成・一覧コマンド**（`run-create`, `task-create`, `task-list`, `worker-list`）には、常に `--environment local` を付与する。
- **ペアリング済みリモートサーバー**でワーカーを起動する場合は、`--environment local` の代わりに `--on <server>` を指定する（Run 本体とコーディネーターのメールボックスはローカル Orca に残る）。

### 1.4 `ORCA open` 安全ルールと接続エラー対処

- **失敗リトライのために `ORCA open` を実行しない**: `ORCA open` はユーザー作業中の前面に Orca ウィンドウを奪うため、コマンド失敗時の復旧手段として使わない。
- `ORCA open`（または `ORCA open --json`）を実行してよいのは次のいずれかのみ:
  1. ユーザーが明示的に Orca の起動・表示を求めたとき
  2. `ORCA status --json` で `result.app.running: false` が確認されたとき（または `ORCA status` を含む全コマンドが約 30 秒リトライしても接続できないとき）
- **`runtime_unavailable`**: Orca のビジーや再起動による一時エラーであることが多いため、数秒待って再試行する。状態変更コマンドを再試行する前は反映済みかを確認し、エラーが返す `--retry-request <id>` を再利用する。
- **`runtime_access_denied`**: サンドボックスによる接続ブロックが原因。Orca を再起動したり `ORCA open` を呼んだりせず、**昇格権限（escalated permissions）でコマンドを再実行**する。

---

## 2. 抽象操作 → Orca コマンド対応表

`SKILL.md` / `_contract.md` で定義された 10 個の抽象操作と、対応する Orca コマンドの対応表です。

| # | 抽象操作 | Orca コマンド / 実装 | 補足 |
|---|---|---|---|
| 1 | `run_create` | `ORCA orchestration run-create --environment local --objective "<目標>"` | DAG 管理や新規目標の開始時に最初に実行。`worker-start --spec` でも未バインド時は自動生成されるが、明示的 DAG では先に `run-create` を行う。 |
| 2 | `task_create` | `ORCA orchestration task-create --environment local --spec-file <spec_path> [--task-title "<タイトル>"] [--deps '["<task_id>",...]'] [--run <run_id>]` | 単一行の短い指示なら `--spec "<指示>"` も可。依存関係は JSON 配列で指定。 |
| 3 | `task_list_ready` | `ORCA orchestration task-list --environment local --ready --brief [--run <run_id>]` | 依存解決済みの着手可能タスク一覧を取得。全文が必要なら `--full`。 |
| 4 | `worker_start` | `ORCA orchestration worker-start --environment local --task <task_id> --worktree <placement> --agent <agent> [--model <id>] [--effort <level>] [--keep-open]` | 直接起動は `--spec-file <path>`、再試行は `--retry-of <dispatch_id>`、リモート起動は `--environment local` を `--on <server>` に置換。 |
| 5 | `worker_send` | `ORCA orchestration send --to dispatch:<dispatch_id> --subject "<件名>" --body-file <body_path>` | 単一行なら `--body "<本文>"` も可。稼働中・完了済み・クローズ済みのいずれにも送信可能（Dispatch 宛フォローアップに `--on` は付けない）。 |
| 6 | `worker_reply` | `ORCA orchestration reply --id <message_id> --body-file <body_path>` | ワーカーからの `question`（`ask`）へ回答。単一行なら `--body "<回答>"` も可。リモートワーカー宛でも追加フラグ不要。 |
| 7 | `inbox_check` | `ORCA orchestration inbox --terminal run:<run_id> --limit 50` | コーディネーター受信箱の確認（既読も参照可能、未読を消費しない）。ターミナル環境や長文 wake で明示指示された場合のみ `ORCA orchestration check` を実行。 |
| 8 | `worker_inspect` | `ORCA orchestration worker-show --dispatch <dispatch_id>`<br>`ORCA orchestration worker-read --dispatch <dispatch_id> --source auto --limit 50`<br>`ORCA orchestration worker-list --environment local --run <run_id> --include-remote` | 状態・生存性・待機検知は `worker-show`、出力閲覧は `worker-read --source auto`、Run 全体（リモート含む）の一覧は `worker-list`。 |
| 9 | `worker_stop` | `ORCA orchestration worker-stop --dispatch <dispatch_id>` | 明示的キャンセル時に Dispatch をフェンスし、管理下の端末とヘルパーを停止。プロセス停止を主張せず放棄する場合は `worker-abandon`、完了端末の即時解放は `worker-release`。 |
| 10 | `wait_strategy` | **イベント駆動（end turn）** | ワーカー起動・指示送信後、手元作業がなければ直ちにターンを終了し、Orca からの `worker_done` / `question` / `escalation` wake を待つ（詳細: セクション 3）。 |

### 2.1 複数行テキストの受け渡しルール（必須）

- 複数行の spec や本文は、必ずファイルツールでファイルへ書き出し、`--spec-file <path>` または `--body-file <path>` で渡します。
- シェルの **ヒアドキュメント（`<<`）やヒアストリング（`<<<`）は絶対に使用しない** でください（シェルがハングする原因になります）。
- `send` / `reply` / `worker-start` が失敗した場合は、渡したファイルを変更せずそのまま保持し、CLI が出力したリカバリ指示だけを実行します（自己判断で新しい ID を作って再送しないこと）。

### 2.2 並列起動ルール（最大約 4 体 / 1 シェルコマンド）

各 `worker-start` はエージェントの準備完了まで待機する（通常約 10 秒）ため、ツール呼び出しを分けると直列実行になり待ち時間が積み上がります。独立したワーカーは **1 つのシェルコマンド内で最大約 4 体まで並列起動**し、完了したものから後続を起動します。

- 各ワーカーの spec は別々のファイルにし、`--spec-file` で渡す（クォート問題を回避）。
- 各起動の標準出力（レシート）と標準エラーをワーカー別のファイルに保存し、全プロセスの終了コードを回収する。
- 失敗時を含め全レシートを読み、`next` や `failedStage` に従って処理する。レシートが欠落・途切れている場合は「結果不明（unknown outcome）」として扱い、盲目的に再起動せず先に `ORCA orchestration worker-list --environment local` で実態を確認する。

POSIX シェル（bash / zsh / WSL / SSH）の例:

```sh
d=$(mktemp -d)
ORCA orchestration worker-start --environment local --spec-file w1.md --worktree new-child --name w1 --agent <agent> >"$d/w1.out" 2>"$d/w1.err" & p1=$!
ORCA orchestration worker-start --environment local --spec-file w2.md --worktree new-child --name w2 --agent <agent> >"$d/w2.out" 2>"$d/w2.err" & p2=$!
s=0; wait "$p1" || s=$?; echo "w1 exit $s"
s=0; wait "$p2" || s=$?; echo "w2 exit $s"
for f in "$d"/*; do echo "== $f"; cat "$f"; done
```

Windows PowerShell 形式や詳細は `ORCA skills get orchestration --reference references/parallel-start.md` を参照してください。

### 2.3 `worker_inspect` の使い分け

| 目的 | コマンド | 確認ポイント |
|---|---|---|
| 個別ワーカーの状態・生存性確認 | `ORCA orchestration worker-show --dispatch <id>` | liveness、`stopReason`、`observation.agentWait`（人間の許可/応答待ち検知。待機中は失敗ではなく正常）、`autoReleaseAt`、`next` |
| 個別ワーカーの最新出力確認 | `ORCA orchestration worker-read --dispatch <id> --source auto --limit 50` | `--source auto` は hook トランスクリプト優先、なければラベル付き端末出力を返す。チャット型ワーカーや自動解放後ワーカーでも動作（`--source terminal` は端末なしワーカーで拒否される） |
| Run 全体のワーカー棚卸し | `ORCA orchestration worker-list --environment local --run <run_id> --include-remote` | ローカルおよび接続サーバー上の全ワーカーの terminal state（`active`, `reclaimable`, `retained`, `released` 等）と `next` アクション |

---

## 3. 通信・待機プロトコル (`wait_strategy` / Orca 固有禁止事項)

### 3.1 イベント駆動 Wake モデル

Orca では、コーディネーターが能動的に監視ループを回すのではなく、**Orca からの push 型 wake で動く**設計になっています。

1. 準備完了（ready）なワーカーを起動し、未処理の質問や指示を処理し終えたら、**直ちにターンを終了（end turn）**する。ユーザーから「終わったら報告して」と言われている場合も同様に end turn する。
2. ワーカーから次のイベントが発生すると、Orca がコーディネーターを自動 wake する:
   - `worker_done`: Task の完了（`succeeded` / `failed`）報告。Task を settle する（失敗報告を完了扱いにしてはならない）。
   - `question`（ワーカーの `ask`）: Task spec やユーザー指示から回答できる場合は `worker_reply` で即答し、ユーザー判断が必要な事項はユーザーへ確認してから回答する。
   - `escalation`: ワーカーの異常停止・ブロック通知（セクション 6 の手順で対処）。
3. チャット UI 環境では各メッセージが全文そのまま届く。ターミナル環境やメッセージが大きすぎる場合は wake が具体的な `check` コマンドを指定してくるので、そのコマンドを実行して内容を取得する。
4. 状況を俯瞰し直したい場合や履歴を見失った場合は、`ORCA orchestration inbox --terminal run:<run_id> --limit 50` を使用する（`check` 済みメールも含めて確認できる）。
5. レシートに `next` アクションが記載されている場合はそれに従い、やるべきことがなくなったら再び end turn する。

### 3.2 Orca 固有の禁止事項

以下は Orca バックエンド固有の厳守事項です（コア `SKILL.md` には置かず、本アダプタで規定します）。

1. **ポーリングや監視スクリプトを作らない**: `sleep` ループや watch スクリプトで素の `ORCA orchestration check` を実行すると、未読メールが既読消費されてコーディネーターから隠れてしまい、Orca が wake する契機も失われる。
2. **ワーカーのターミナルを直接操作・読み取りしない**: `orca terminal` 系コマンドでワーカーへ入力を送ったり出力を読んだりしない。ワーカーはターミナルを持たないチャットセッションの場合がある。指示は必ず `ORCA orchestration send`、出力確認は `ORCA orchestration worker-read --source auto` を使用する。
3. **Git チェックアウトや worktree を手動作成しない**: 自分で `git worktree add` や別ディレクトリのクローンを作らず、必ず `worker-start --worktree ...` にワークスペース作成を任せる。フォルダプロジェクトに対して勝手に `git init` を行うことも禁止。
4. **起動後に待機ループを回さない**: ワーカー起動後は即座に end turn する。

---

## 4. ワークスペース隔離・配置ルール

### 4.1 `--worktree` オプションの使い分け

| 配置オプション | 用途・挙動 | 注意点 |
|---|---|---|
| `--worktree current` | コーディネーターと同じワークスペースで実行 | ローカル専用（`--on` と併用不可）。setup フックは再実行されない。作成系フラグ（`--name`, `--repo`, `--base-branch`, `--setup` 等）は拒否される。 |
| `--worktree new-child --name <short-name>` | 現在のワークスペース配下に子 Git worktree を作成 | 同一ファイル群を並列編集する複数ワーカー間の競合回避に使用。ローカル同一プロジェクトなら `--repo` 省略可。`--on` やフォルダワークスペース起点では `--repo id:<repoId>` が必要。 |
| `--worktree new-top-level --repo id:<repoId> --name <short-name>` | 親を持たないトップレベル Git worktree を作成 | `repoId` はローカルなら `ORCA repo list --json`、マルチホスト選定時は対象マシンの `ORCA project setups --environment <id> --json` から取得。 |

- `--name` は現行 Orca では省略可能（自動命名）ですが、旧サーバー互換性と識別性のため短い名前（`<short-name>`）の付与を推奨します。
- 成果物をコーディネーターへ戻す必要がない（ユーザーがそのチャットで直接作業を続けるだけの）場合は、`worker-start` ではなく `ORCA worktree create --name <name> --no-parent --agent <agent> --prompt "<brief>" --json` を使って end turn します。

### 4.2 非 Git・執筆・調査タスクでの隔離ルール

フォルダプロジェクトやコード以外の作業（ドキュメント執筆、調査・分析など）では、`new-child` / `new-top-level` で Git worktree を作成できません（また `git init` を勝手に行ってはいけません）。

- **`--worktree current` のまま、ワーカーごとに担当ファイルを厳密に分割**して書き込み競合を回避します（例: 執筆なら章別ファイル、調査ならテーマ別メモファイルを作成し、最終統合は 1 人のワーカーに担当させる）。
- 各 Task spec に **「編集してよいファイル」** と **「触ってはいけないファイル」** を必ず明記します。

### 4.3 Placement 行の規約とリモート配置

ユーザーが実行マシンを指定した場合（「ここ」= ローカルを含む）、別プロジェクトを対象とする場合、または配置選定手順（「Which machine」、`references/placement-and-remote.md` 参照）でマシンを決めた場合は、**新規 Task の spec の最終行**（先頭行は Task タイトルになるため必ず末尾）に配置記録行を追記します。

```text
<タスク本文...>
Placement: <machine name> (<kind> <id>), <reason>.
```

- ローカルマシンの表記は `this machine (local)`（例: `Placement: this machine (local), the user named it.`）。
- `<reason>` には選定理由を簡潔に記す（例: `the user named it` / `set up on this machine` / `the only ready candidate` / `this Run already works there` 等）。
- 既存 Task の再起動（`--task` / `--retry-of`）では新 spec を渡さないため、選んだマシン・理由・新しい Dispatch ID をユーザー報告に記載する。
- リモート配置したワーカーは、起動後は常に `dispatch:<dispatch_id>` で扱い、端末ハンドルで参照しない。

---

## 5. エージェント・モデル・エフォートのマッピング

`SKILL.md` / `model-routing.md` のルーティング規則で解決された `(agent, model, effort)` は、`worker-start` のフラグへ以下のように対応付けます。

```sh
ORCA orchestration worker-start --environment local --task <task_id> --worktree <placement> --agent <agent> [--model <id>] [--effort <level>]
```

### 5.1 基本ルールと制約

- **`--effort` は `--model` 必須**: Orca CLI では `--effort` を単独指定できない。エフォートを指定する場合は必ず `--model` とセットで渡す。
- **`--terminal` との併用不可**: 既存端末を再利用する `--terminal <handle>` 指定時は `--agent` / `--model` / `--effort` および新規 worktree 作成フラグを指定できない。
- **モデル未指定時の既定挙動**:
  - ユーザーがモデルを指定しておらず、ルーティングポリシー上も明示指定を行わない場合は `--model`（および `--effort`）を省略し、エージェント既定に委ねる。
  - `model-routing.md` によりタスク性質ごとの `(agent, model, effort)` が解決された場合（例: 個人情報タスクでの特定エージェント固定や、複雑タスク／事務タスク別のモデル選択）は、対応するフラグを明示指定し、**後任ワーカーでも同じ選定基準を維持する**。
- **CLI 未導入の注意点**: `worker-start` は起動前にエージェント CLI の存在確認を行わない。未導入エージェントを指定すると `agent_readiness` タイムアウトで失敗する。

### 5.2 エージェント別の `--model` / `--effort` 形式

Orca が対応する主なエージェント ID と、モデル／エフォート指定形式の違いは以下のとおりです。

| エージェント (`--agent`) | `--model` 形式 | `--effort` の扱い |
|---|---|---|
| `antigravity`, `claude`, `codex`, `cursor`, `grok`, `muse` | 各プロバイダ固有のモデル ID（opaque provider model ID） | 推論エフォートレベルを指定（`--model` 必須） |
| `pi` | `provider/id` 形式 | Pi の `--thinking` レベル（`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`）にマッピング（`--model` 必須） |
| `omp` | モデルロールやセレクタ（例: `@worker`, `provider/model:level`） | thinking レベルとして適用（`--model` 必須） |
| `opencode`, `opencode2` | 既存ワークツリー＋検証済みホスト CLI＋利用可能モデルが必要 | **非サポート** |
| その他（`zcode` 等） | 指定不可（エージェント自身の設定ファイルのモデルで起動） | 非サポート |

> **論理エージェント名の対応と確認方法**: [../model-routing.md](../model-routing.md) の論理エージェント名は、`Antigravity` → `antigravity`、`pi coding agent` → `pi` に対応します。`vibe` 等の別選択肢や、正確なエージェント ID・モデル ID・エフォート表記は使用中の Orca バージョンや実行ホスト構成によって異なるため、不確かな場合は必ず `ORCA orchestration worker-start --help` を実行して確認してください。PII タスク向けに指定された安全なエージェント／モデルが起動できない場合は、暗黙に一般モデルへフォールバックせずユーザーへエスカレーションします。

---

## 6. 障害復旧・引き継ぎ・ライフサイクル管理

### 6.1 `escalation` の `stopReason` 別対処

ワーカーが `worker_done` を送らずに停止した場合、Orca は `stopReason` 付きの `escalation` でコーディネーターを wake します。必ず**証拠を確認してから**行動します。

| `stopReason` | 初動確認と対処方針 |
|---|---|
| `lost` | 最初に `ORCA orchestration worker-show --dispatch <id>` を実行する。元エージェントがまだ稼働中である可能性がある。沈黙・タイムアウト・`unverifiable` な liveness だけでは終了の証明にならず、メール送信・停止・放棄・再試行・解放を自律実行してはならない。不確実な状態をユーザーへそのまま報告する。 |
| `exited` | プロセス終了が確定している。`worker-read --dispatch <id> --source auto --limit 50` とワーカーの `HANDOFF.md` を確認して途中経過・成果物を把握し、必要なら整理したうえで、同一 Task に対して `--retry-of` で後任を起動するか、ユーザーへ報告する。 |
| その他 | `worker-show` / `worker-read` で状態を確認。応答可能なら `worker_send` で軌道修正（または `HANDOFF.md` の更新依頼）を行う。プロセス終了が確定しており回復不能な場合は同一 Task に `--retry-of` で後任を起動する。稼働中ワーカーの停止が必要な場合は安全規則に従い勝手に `worker-stop` せずユーザーへ報告して判断を仰ぐ。 |

### 6.2 HANDOFF 駆動の引き継ぎ（コンテキスト枯渇・途中停止）

- **context-guard 通知（`[context-guard] コンテキスト使用量が 80%...` の `ask`）が来た場合**: ワーカーの `HANDOFF.md` 更新と終了報告を待ち、通常の引き継ぎフローで後任を起動する。
- **後任の起動**: `HANDOFF.md` が最新であれば、同一 Task に `--retry-of` で後任を起動する。`HANDOFF.md` が古い・空でも元ワーカーが応答可能なら、まず `send` で現状の書き出しを依頼する。応答しない場合は成果物ファイルと `worker-read` の出力からコーディネーターが状況を再構築する。
- **コーディネーター自身の引き継ぎ**: 新セッションから `ORCA orchestration inbox --terminal run:<run_id> --limit 50` と `ORCA orchestration worker-list --environment local --run <run_id> --include-remote` を実行すれば、Orca 上の Run を維持したまま指揮を継続できる。

### 6.3 再試行ルールと 3 回失敗サーキットブレーカー

```sh
ORCA orchestration worker-start --environment local --task <task_id> --retry-of <newest_failed_dispatch_id> --worktree <placement> --agent <agent> [--model <id>] [--effort <level>]
```

- **同一 Task を再利用する**: 失敗した試行の再試行は必ず `--task <task_id> --retry-of <dispatch_id>` で行う。`--spec` を付け直して重複 Task を作らない。
- **配置・エージェント設定は継承されない**: `--environment local`（または `--on <server>`）、`--worktree`、`--agent`、`--model`、`--effort` を明示的に再指定する。
- **原因未解消のリトライ禁止**: 到達不能ホストなど原因が変わっていない失敗に対して同じ起動を繰り返さず、ユーザーへ報告する。
- **3 回失敗サーキットブレーカー**: 同一 `--retry-of` チェーンで起動失敗が 3 回に達すると Orca 側で Dispatch がサーキットブレークし、Task が失敗状態になる（ワーカー自身が `worker_done --outcome failed` を返した場合は Orca の起動失敗カウントを進めないが、コア規則に従い司令塔側でも同一 Task の失敗が累計 3 回に達したら自動再試行を停止する）。いずれの場合も直ちに自動再試行を停止し、ユーザーへ報告する。**新規 Run / 新規 Task の作成や `reset` でブレーカーを迂回してはならない。**
- **ユーザー明示による再オープン**: ユーザーが同一 Task の再試行・再割り当てを明示的に指示した場合のみ、保有 Run のコーディネーターが履歴を `worker-show` / `worker-read` で確認し（必要に応じ `worker-stop` / `worker-abandon` / `worker-release` を実施）、以下で同一 Task を再オープンして新規シリーズ（失敗カウント 0）を開始する:
  ```sh
  ORCA orchestration task-update --environment local --id <task_id> --status ready --run <owning_run_id>
  ORCA orchestration worker-start --environment local --task <task_id> --run <owning_run_id> --worktree <placement> --agent <agent>
  ```

### 6.4 フォローアップ `send` と端末ライフサイクル

- **完了・クローズ済みワーカーへのフォローアップ**: `ORCA orchestration send --to dispatch:<dispatch_id> --subject "<件名>" --body-file <path>` は、稼働中ワーカーにはターン終了時に届き、**完了済み・クローズ済みワーカーにはフォローアップ Task として再起動・配達され、完了時に再び `worker_done` が返る**（Dispatch フォローアップに `--on` は付けない）。
  - レガシーなペアリングサーバー接続で `dispatch_inactive` により拒否された場合のみ、`worker-start --on <server>` で新規起動する。
- **自動解放（auto-release）と `--keep-open` / `worker-keep-open`**:
  - `worker_done` が受理されたワーカーは通常、約 2 分後（`autoReleaseAt`）に自動解放される。クローズ時は付随する setup 端末（setup 失敗時は残る）・起動タブ・`--keep-open` なしでワーカーが作った端末も一緒に閉じられる。解放後も `worker-read` でトランスクリプト／チャット履歴を閲覧できる。
  - ユーザーが作業後もワーカーのチャットや端末を見続けたい・対話したい場合は、起動時に `--keep-open` を付けるか、起動後に `ORCA orchestration worker-keep-open --dispatch <dispatch_id>` を実行する。
  - 新規 worktree（`new-child` / `new-top-level`）のワーカーはレシートの `keepOpenByDefault` に従い開いたままになる場合があるため、誰も使わなくなったら `ORCA orchestration worker-release --dispatch <dispatch_id>` で解放する。
- **停止・放棄・リセットの区別**:
  - `worker-stop --dispatch <id>`: ユーザー明示のキャンセル等で使用。`stop_unknown`（終了コード 1）が出た場合は停止未確定のため `worker-show` を確認し、盲目的に再停止・再試行しない。
  - `worker-abandon --dispatch <id>`: 意図的放棄として割り当てをフェンス・終了するが、プロセス停止は行わず主張もしない。キャンセルの代替として黙って使わない。
  - `worker-release --dispatch <id>`: 完了済み・失敗起動済みで回収可能な管理下端末を明示解放する（`terminal close` を直接使わない）。
  - `orchestration reset`: オーケストレーション状態を破棄するため、ユーザーが明示的に破棄を承認した場合のみ実行する。

---

## 7. 追加公式リファレンス一覧

状況に応じて、使用中バイナリからバージョン一致の公式リファレンスを読み込みます。

```sh
ORCA skills get orchestration --reference references/<file>.md
```

| リファレンス | 参照すべき状況 |
|---|---|
| `references/coordinator-loop.md` | Task DAG の構築・運用、複数 Run の並行管理（`run-create`, `run-use`, `--run`） |
| `references/placement-and-remote.md` | 別プロジェクト・別マシン選定（「Which machine」）、子 worktree、SSH / WSL、ペアリング済みサーバー（`--on`）とリモートメール |
| `references/messaging-and-gates.md` | グループメッセージ、承認・意思決定ゲート（`gate-create`, `gate-resolve`, `gate-list`） |
| `references/recovery-and-cleanup.md` | 失敗・不明状態ワーカーの復旧、サーキットブレーカー後の再オープン、`worker-stop` / `worker-abandon` / `worker-release` / `reset` |
| `references/worker-teardown.md` | ワーカー終了ライフサイクル（settled / ended / destroyed）と自動解放の挙動 |
| `references/parallel-start.md` | 独立ワーカー（最大約 4 体）を 1 シェルコマンドで並列起動する POSIX / PowerShell テンプレート |
| `references/low-level-topology.md` | カスタム argv や低レベルな端末トポロジー構成が必要な場合 |
