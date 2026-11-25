# Herdr バックエンド・アダプタ（`herdr`）

本ドキュメントは、[../../SKILL.md](../../SKILL.md) のコアプロトコルおよび [_contract.md](./_contract.md) の 10 抽象操作を **Herdr CLI**（`herdr`、ターミナルワークスペース＆エージェントランタイム）へマッピングするバックエンドアダプタ実装です。

---

## 1. バックエンド概要・前提と CLI 解決（Bootstrap）

### 1.0 バックエンドメタデータ・対応ケイパビリティ表

| 項目 | 内容 |
|---|---|
| **Backend ID** | `herdr` |
| **CLI / 接続先の解決** | `PATH` 上の `herdr` バイナリ（例: `~/.local/bin/herdr`）。設定ファイルは `~/.config/herdr/config.toml`（`HERDR_CONFIG_PATH` で上書き可能） |
| **事前条件・起動手順** | 1) **Herdr 管理ペイン内からの実行が必須**: `test "${HERDR_ENV:-}" = 1` を最初に確認する<br>2) `herdr --skill` を 1 回実行してバージョン一致ガイドを読み、`herdr --version` でバージョンを確認する |
| **ネイティブ Run / Task DAG 管理** | **アダプタ側エミュレーション**（Herdr は workspace/tab/pane/agent を管理するランタイムであり DAG DB を持たないため、`<Run のルート>/.herdr-run/state.json` と `HANDOFF.md` で管理する） |
| **待機モデル（`wait_strategy`）** | **ブロッキング待機／有界ポーリング併用（Pull / Wait）**（`herdr agent prompt --wait` / `herdr agent wait` / `herdr agent list`） |
| **ワークスペース分離** | **ネイティブ対応**（Git リポジトリは `herdr worktree create --no-focus`、共有作業は `herdr pane split --current --no-focus` ＋担当ファイル排他分割） |
| **再試行リンク（`retry_of`）** | **アダプタ側エミュレーション**（`.herdr-run/state.json` で試行回数を追跡し、新エージェント名 `<task>-try2` で同一タスクの後任を起動。3 回失敗でサーキットブレーカー発動） |
| **エージェント・モデル・エフォート指定** | **ネイティブ `--kind` ＋ネイティブ引数パススルー（`-- <agent-args...>`）** |
| **双方向メッセージング** | **プロンプト送信＋出力読取＋`blocked` 検知**（`herdr agent prompt` / `send-keys` / `read` / `get` / `notification show`） |
| **状態・出力・生存検証** | **ネイティブ対応**（`herdr agent list` / `get` / `explain` / `read --source recent-unwrapped` / `herdr pane process-info`） |
| **司令塔セッション再接続** | **永続セッション＋ローカル状態ファイルで対応**（`herdr --session <name>` / `herdr session list` と `.herdr-run/state.json`・`HANDOFF.md` から復元） |
| **`context-guard` 連携** | **一部連携**（`pi` / `agy` / `vibe` の `HANDOFF.md` 更新＆終了指示注入が機能。Orca 向け通知は不要なため `*_CONTEXT_GUARD_SILENT=1` を推奨） |

### 1.1 必須前提チェック（Herdr ペイン内判定）

すべての制御コマンドを発行する前に、必ず以下を実行して Herdr 管理ペイン内で動いていることを確認する。

```bash
test "${HERDR_ENV:-}" = 1
printf 'workspace=%s tab=%s pane=%s\n' "${HERDR_WORKSPACE_ID:-}" "${HERDR_TAB_ID:-}" "${HERDR_PANE_ID:-}"
```

- `HERDR_ENV=1` でない場合は、**「Herdr の管理ペイン外から実行されているため制御できない」旨をユーザーへ報告して停止する**。外部からフォーカス中の Herdr セッションを操作してはならない。
- 公開 ID の形式は `workspace: w1`、`tab: w1:t1`、`pane: w1:p1`。ID は必ずコマンドの JSON 出力から取得し、サイドバー順や推測で組み立てない。

### 1.2 バージョン一致ガイドとコマンド確認ルール

セッション開始時に 1 度だけ以下を実行し、インストール済み `herdr` バイナリ固有の最新仕様を確認する。

```bash
herdr --version
herdr --skill
```

- サブコマンドの引数確認は必ず `herdr <group> --help` または `herdr <group> <subcommand> --help` を使う。
- **やってはいけない探索**:
  - 引数なしの `herdr` を実行しない（TUI の起動・アタッチを行ってしまう）。
  - 状態を変更するコマンド（例: `herdr workspace create`）を引数なしで試し打ちしない（デフォルト引数で実際に作成が実行される）。
- CLI のサーバーエラーは stderr に JSON を出して終了コード `1`、構文エラーは終了コード `2` を返す。

---

## 2. 抽象操作 → Herdr コマンド対応表

[_contract.md](./_contract.md) の 10 個の抽象操作を、Herdr のコマンドおよびアダプタ側ローカル状態管理へ以下のように対応づけます。

| # | 抽象操作 | Herdr での実現方法・コマンド | 備考 |
|---|---|---|---|
| 1 | `run_create` | `<Run のルート>/.herdr-run/state.json` および `specs/`、`handoffs/` を作成し、`run_id`・`objective`・呼び出し元コンテキスト（`$HERDR_WORKSPACE_ID` / `$HERDR_TAB_ID` / `$HERDR_PANE_ID`）を記録する | ユーザーが明示的に専用ワークスペースを求めた場合のみ `herdr workspace create --cwd <path> --label "<run>" --no-focus` を作成 |
| 2 | `task_create` | Task spec 本文を `<Run のルート>/.herdr-run/specs/<task_id>.md` に書き出し、`.herdr-run/state.json` へ `{task_id, title, spec_path, deps, status, attempts: 0, model_config}` を登録する | 長文 spec をシェル引数へ直接展開せず、ファイル経由でワーカーに読ませる |
| 3 | `task_list_ready` | `.herdr-run/state.json` を読み取り、`deps` がすべて `succeeded` かつ未着手（`ready`）のタスク一覧を抽出する | 依存未解消や settled 済みタスクは返さない |
| 4 | `worker_start` | **3 ステップで起動**（下記 2.1 参照）:<br>① 空のシェルペイン作成（`herdr pane split` または `herdr worktree create`）<br>② `herdr agent start <name> --kind <kind> --pane <pane_id> [--timeout <ms>] [-- <agent-args...>]`<br>③ `herdr agent prompt <name> "<spec 読み込み指示>"` | `agent start` はペイン作成を行わないため必ず①が先行する。`<name>` は `[a-z][a-z0-9_-]{0,31}` でライブ一意 |
| 5 | `worker_send` | `herdr agent prompt <name_or_pane_id> "<指示>" [--wait --timeout <ms>]`<br>TUI 制御キー送信時は `herdr agent send-keys <name_or_pane_id> <esc\|ctrl+c\|...>` | 生の `pane send-text` ではなく、検証済みの `agent prompt` / `agent send-keys` を優先する |
| 6 | `worker_reply` | `blocked` 検知後に `herdr agent get` と `herdr agent read` で内容を確認し、司令塔回答可能な質問なら `herdr agent prompt <target> "<回答>"`（選択肢 UI は `herdr agent send-keys`）で応答する | 人による承認（approval）プロンプトなら自動応答せずユーザーへエスカレーション |
| 7 | `inbox_check` | `herdr agent list` で全稼働エージェントの状態を取得し、変化があったワーカーについて `herdr agent get <target>`・`herdr agent read <target> --source recent-unwrapped --lines 120`・担当 `HANDOFF.md` を確認して正規化イベントへ分類する | 正規化ルールは第 3.2 節を参照 |
| 8 | `worker_inspect` | `herdr agent get <target>`<br>`herdr agent explain <target>`<br>`herdr agent read <target> --source recent-unwrapped --lines 120`<br>`herdr pane process-info --pane <pane_id>` | `read` が代替画面で見切れる場合のフォールバックは第 3.3 節を参照 |
| 9 | `worker_stop` | 必要に応じ `herdr agent send-keys <target> ctrl+c` 等で終了させた後、この Run で作成したペインなら `herdr pane close <pane_id>`（分離 worktree なら `herdr worktree remove --workspace <workspace_id>`） | ユーザー明示依頼時または確定完了後のクリーンアップのみ。他者作成のペイン／タブ／ワークスペースや `herdr server stop` は絶対に触らない |
| 10 | `wait_strategy` | 単体待機: `herdr agent prompt <target> "<指示>" --wait --timeout 120000` または `herdr agent wait <target> --timeout 120000`<br>並列待機: 全ワーカーへ `--wait` なしで投入後、`herdr agent wait` / `herdr agent list` による有界待機ループで状態遷移を回収する | 詳細は第 3.1 節を参照 |

### 2.1 `worker_start` の具体的な 3 ステップ手順

Herdr では `herdr agent start` は**既存の対話シェルプロンプト上のペイン**を必要とし、ペイン分割や worktree 作成を自動で行いません。次の手順で起動します。

```bash
# Step A-1: 共有ワークスペース（既定）の場合 — レイアウト確認後にペイン分割
herdr pane layout --pane "$HERDR_PANE_ID"
# 幅広なら --direction right、縦長／狭いなら --direction down を選ぶ
herdr pane split --current --direction right --cwd "$PWD" --no-focus
# JSON の .result.pane.pane_id を <pane_id> として取得

# Step A-2: 分離ワークスペース（Git worktree）の場合
herdr worktree create --branch "orch/<task_id>" --base HEAD --label "<task_id>" --no-focus
# JSON 応答から workspace ID と root pane ID (<pane_id>) を取得

# Step B: シェルペイン内でエージェント起動（準備完了まで既定 30s 待機）
herdr agent start t1-w1 --kind agy --pane <pane_id> --timeout 30000 -- <agent-args...>

# Step C: ファイル化した Task spec を読ませて作業開始
# 単体実行なら --wait --timeout 120000 を付与、複数並列なら --wait なしで連続投入
herdr agent prompt t1-w1 "Read /abs/path/.herdr-run/specs/t1.md and /abs/path/HANDOFF-t1.md (if present), execute the task, update the handoff file with evidence, and report completion summary."
```

- **ファイルベース spec 運用の理由**: `herdr agent prompt` は 1 つのテキスト引数を受け取ります。長文の複数行 Markdown や引用符・バッククォートを含む spec は直接コマンドラインに渡さず、`.herdr-run/specs/<task_id>.md` に保存してから短いプロンプトで読み込ませることで、エスケープ事故やペースト崩れを防ぎます。
- **並列起動の上限目安**: 一度に起動する並列ワーカーは最大 4 台程度に抑え、ペインが過度に狭くならないよう `right` / `down` を交互に選ぶか、多数になる場合は新規タブ（`herdr tab create --no-focus`）や分離 worktree ワークスペースへ分散します。

### 2.2 ローカル Run 状態ファイル（`.herdr-run/state.json`）の最小スキーマ

```json
{
  "run_id": "herdr-run-20261125-144500",
  "objective": "ユーザーと合意した目標",
  "caller": {
    "workspace_id": "w1",
    "tab_id": "w1:t1",
    "pane_id": "w1:p1"
  },
  "created_resources": {
    "workspaces": [],
    "tabs": [],
    "panes": ["w1:p2", "w1:p3"]
  },
  "tasks": {
    "t1": {
      "title": "タスク名",
      "spec_path": ".herdr-run/specs/t1.md",
      "handoff_path": ".herdr-run/handoffs/t1.md",
      "deps": [],
      "status": "running",
      "attempts": 1,
      "model_config": { "agent": "Antigravity", "model": "Gemini 4 Neon", "effort": "High" },
      "active_worker": { "name": "t1-w1", "pane_id": "w1:p2", "workspace_id": "w1" }
    }
  }
}
```

- 司令塔自身が作成したリソース（`created_resources`）を必ず記録し、クリーンアップ時に自分が作っていないペイン・タブ・ワークスペースを誤って閉じないようにします。

---

## 3. 通信・待機プロトコル（`wait_strategy`）

### 3.1 Pull / Blocking-Wait モデルの運用規律

Orca のようなプッシュ型 wake（`end turn` で自動再開）と異なり、Herdr は**司令塔側が明示的に待機コマンドや状態照会を実行する Pull / Wait モデル**です。

1. **単一ワーカー待機**:
   ```bash
   herdr agent prompt t1-w1 "<指示>" --wait --timeout 120000
   # または投入済みのワーカーを待つ場合:
   herdr agent wait t1-w1 --timeout 120000
   ```
   - `--wait` および `--until` 省略時の `agent wait` は、既定で最初の `idle` / `done` / `blocked` 状態到達を待ちます（同じ既定値を `--until` で重複指定しない）。
   - 非 `working` 状態からの `prompt --wait` は、5 秒以内に状態遷移が観測されないと `agent_prompt_stalled` を返します（無限ハング防止）。その場合は `agent get` と `agent read` でプロンプト受理状況を確認します。
   - `--wait` はターン単位ではなく**ライフサイクル状態**を監視するため、すでに `working` 中のエージェントへ追加投入した場合は進行中ターンの終了で返ることがあります。
2. **並列ワーカー待機**:
   - 各ワーカーへ `herdr agent prompt <name> "<指示>"` を `--wait` なしで順に投入する。
   - その後、有界タイムアウト付きの待機／照会サイクルを回す:
     - 優先度の高いワーカーを `herdr agent wait <name> --timeout 60000` で待つか、バックグラウンド待機プロセスで複数 `herdr agent wait` を並列監視し、最初に返ったワーカーから処理する。
     - `herdr agent list` で全稼働ワーカーの状態を一括確認し、`done` / `idle` / `blocked` へ遷移したワーカーから順次 `inbox_check`（確認・統合・次タスク起動）を進める。
3. **特定状態だけ待ちたい場合**:
   - 例: 実行中ワーカーが承認・質問を求めて止まるのを待つ場合のみ `herdr agent wait <name> --until blocked --timeout 120000` を使用する。
4. **タイムアウトの扱い**:
   - `--timeout` 超過は「まだ作業中」を示すに過ぎず、**停止や失敗の証拠ではない**。`herdr agent get` と `herdr agent read` で進捗を確認してから追加待機または介入を判断する。

### 3.2 Herdr ライフサイクル状態 → 正規化イベントのマッピング

| Herdr 状態（`agent list` / `agent get`） | 意味 | 正規化イベント | 司令塔の基本アクション |
|---|---|---|---|
| `working` | エージェントがアクティブに処理中 | （稼働中） | 待機継続 |
| `done` / `idle` | 入力待ちへ復帰（`done` は未閲覧のバックグラウンド完了、`idle` は閲覧済みの待機状態） | **`worker_done`**（要証拠確認） | `herdr agent read` と担当 `HANDOFF.md`・成果物を検証。完了証拠が揃っていれば成功確定、未完や失敗報告なら修正指示（`worker_send`）または再試行（上限 3 回） |
| `blocked` | Herdr が承認プロンプトまたは質問 UI を検知 | **`question`** または **`approval`** | `herdr agent get` と `herdr agent read` で内容を必ず確認。タスク上の質問なら `worker_reply`、人による承認が必要なら自動承認せずユーザーへエスカレーション（任意で `herdr notification show` で通知可） |
| `unknown` | エージェントは存在するが状態を確信分類できない | **判定不能（`unverifiable`）** | 完了・停止の証拠にならない。`herdr agent explain <target>`・`herdr agent read`・`herdr pane process-info` で一次証拠を確認する |
| エージェント消失／プロセス終了 | `agent list` から消えた、または `pane process-info` でエージェント終了を確認 | **`escalation`**（`exited`） | 成果物・`pane read`・`HANDOFF.md` を確認し、後任ワーカーの起動（第 6 節）またはユーザー報告を実施 |

> **注意**: Herdr CLI による `agent read` はタブを「既読」にしません（`focus` コマンドや UI クリックで初めて `done` → `idle` へ切り替わります）。バックグラウンド運用中は `--no-focus` を維持し、ユーザーのフォーカスを奪わないこと。

### 3.3 出力読取（`agent read`）と代替画面フォールバック

- 読み取りソースの選択:
  - **`recent-unwrapped`**（既定推奨）: ソフトラップを結合した直近出力。ログ・完了報告の取得に最も適する。
  - `recent`: ソフトラップ含む直近出力。
  - `visible`: 現在の表示領域のみ。
  - `detection`: エージェント状態判定用の下端プレーンテキスト。
  - 色・ANSI スタイルが証拠になる場合のみ `--format ansi` を付ける。
- **代替画面（alternate screen）の見切れ対策**:
  - `--lines` を増やしても完了応答の上部が取得できない場合、そのエージェントはターミナルの代替画面上で動いており、スクロールアウトした行は Herdr のスクロールバックに残らない。
  - その場合に限り（初回プロンプトでは頼まずフォールバックとして）、`herdr agent prompt <target> "Write your complete report as Markdown to /tmp/herdr-report-<task_id>.md and reply with only the file path." --wait` でファイル書き出しを依頼し、そのファイルを直接読む。

### 3.4 Herdr 固有の禁止事項

- **ペイン外からの操作禁止**: `HERDR_ENV=1` が成立しない環境から Herdr を制御しない。
- **フォーカス奪取禁止**: ユーザーが明示的に画面切替を望まない限り、作成・分割系コマンドには常に `--no-focus` を付ける。
- **無関係なリソースの破棄禁止**: この Run で作成した記録（`created_resources`）にないワークスペース・タブ・ペイン・セッションを閉じない。
- **サーバー停止禁止**: アクティブなセッションから `herdr server stop` を実行したり、メインの Herdr プロセスを kill しない。
- **ターゲット省略の禁止**: ペイン系コマンドは `--current` または明示的 `<pane_id>` を必ず指定し、別クライアントがフォーカス中のペインへ誤送信しない。

---

## 4. ワークスペース分離・配置と `HANDOFF.md` 競合回避

### 4.1 ワークスペース分離モード

| 状況 | モード | Herdr コマンド | 競合回避ルール |
|---|---|---|---|
| **同一ファイル群を編集する並列コード作業**（Git リポジトリ） | 分離（`isolated`） | `herdr worktree create --branch <branch> --base <ref> --label <name> --no-focus` | ワーカーごとに独立 worktree・独立ブランチで実行。完了後、司令塔または統合ワーカーが差分・テストを検証してベースブランチへ統合する |
| **単一ワーカー作業、または非 Git・執筆・調査の並列作業** | 共有（`shared`） | `herdr pane split --current --direction <right\|down> --cwd "$PWD" --no-focus` | ワーカーごとに「編集してよいファイル」「触ってはいけないファイル」を Task spec で厳密に排他分割する |
| **ワーカー数が多く現在タブに収まらない場合** | 新規タブ（`shared`） | `herdr tab create --no-focus`（返却された `root_pane` を使用） | ユーザーが明示的にワークスペース／タブ分離を望む場合や、ペイン分割限界に達した場合に使う |

- `herdr pane move` でペインを別ワークスペースへ移動した場合、ペイン ID が新しいワークスペース接頭辞付き ID（`.result.move_result.pane.pane_id`）に変わるため、以後は新 ID またはライブエージェント名を使うこと。

### 4.2 共有ワークスペース並列時の `HANDOFF.md` パス分離

複数の並列ワーカーが共有ワークスペース（`--cwd "$PWD"`）で同時稼働する場合、全員が同じ `<Run のルート>/HANDOFF.md` へ書き込むと衝突します。

- **司令塔**: `<Run のルート>/HANDOFF.md`（Run 全体の状況）
- **分離 worktree ワーカー**: `<各 worktree ルート>/HANDOFF.md`
- **共有ワークスペースの並列ワーカー**: タスク単位のパス（例: `<Run のルート>/.herdr-run/handoffs/<task_id>.md` または `<Run のルート>/HANDOFF-<task_id>.md`）を Task spec に明記して排他管理する。

---

## 5. エージェント・モデル・エフォートのマッピング

[../model-routing.md](../model-routing.md) で確定した論理的な `(agent, model, effort)` を、`herdr agent start` の `--kind` とネイティブ引数パススルー（`-- <agent-args...>`）へ変換します。

### 5.1 論理エージェント名 → Herdr `--kind` マッピング

`herdr 0.8.0` の `herdr agent start --kind` がサポートする値:
`pi`, `claude`, `codex`, `gemini`, `cursor`, `devin`, `agy`, `cline`, `omp`, `mastracode`, `opencode`, `copilot`, `kimi`, `kiro`, `droid`, `amp`, `grok`, `hermes`, `kilo`, `qodercli`, `maki`

| `model-routing.md` の論理エージェント | Herdr `--kind` | モデル／エフォート指定の渡し方（`--` の後ろ） | 備考 |
|---|---|---|---|
| `Antigravity` | `agy` | `agy` CLI が受け付けるモデル／エフォート引数を `--` 以降へ渡す（不確かな場合は `agy --help` で事前確認） | 未指定時は `agy` の既定設定で起動 |
| `pi coding agent` | `pi` | `-- --model <provider/id> --thinking <off\|minimal\|low\|medium\|high\|xhigh\|max>`（`pi --help` で最新フラグを確認） | `pii` ロール既定 |
| `vibe` | **未収載**（`--kind` 対象外） | 下記 5.2 の非対応時ルールに従う | `herdr agent start --help` で最新版の対応状況を再確認すること |
| その他（`claude`, `codex`, `cursor`, `opencode`, `omp` 等） | 同名の `--kind` | 各 CLI 固有のモデル／推論フラグを `--` 以降へ渡す（例: `claude --help`, `codex --help` で確認） | ユーザー明示指定時に使用 |

```bash
# 例: Antigravity (agy) を起動
herdr agent start t1-w1 --kind agy --pane <pane_id>

# 例: pi coding agent をモデル・thinking 指定付きで起動
herdr agent start t2-pii --kind pi --pane <pane_id> -- --model <provider/model-id> --thinking high
```

### 5.2 非対応エージェント・フラグの劣化ルールと PII 保護

1. **モデル／エフォート引数の確認**: Herdr 自体は `--model` / `--effort` フラグを持たず、すべて `--` 以降のネイティブ CLI 引数として転送します。使用前に必ず対象エージェントの `--help` で正確なフラグ名を確認してください。
2. **エフォート非対応エージェント**: 対象エージェント CLI が `effort` / `thinking` 相当の引数を持たない場合は、無理に不明フラグを渡さず省略し、その旨をユーザーへ共有します。
3. **`vibe` など `--kind` 未収載エージェントの扱い**:
   - 最新版の `herdr agent start --help` でも `--kind` に含まれていない場合は、ユーザーへ次のいずれかを確認する:
     - 対応済み `--kind`（例: `agy` / `pi` / `claude` / `codex`）へ切り替える
     - 生ペイン（`herdr pane run <pane_id> "vibe ..."` ＋ `herdr pane wait-output` / `herdr pane read`）で限定運用する（ライフサイクル自動検知は使えない旨を明示）
4. **PII 安全モデルの厳格保護**: 個人情報タスク向けに確定した安全なエージェント／モデル（例: `pi`）が Herdr 環境で起動できない場合、**暗黙に外部汎用モデルへフォールバックしてはならない**。起動を中止し、ユーザーへエスカレーションする。
5. **後任継承**: 後任ワーカーを起動するときも、`.herdr-run/state.json` に記録した同一の `--kind` および `-- <agent-args...>` をそのまま渡す。

---

## 6. 障害復旧・生存確認・引き継ぎ・クリーンアップ

### 6.1 生存確認（Liveness）の 3 区分

| 区分 | Herdr での判定根拠 | 許可されるアクション |
|---|---|---|
| **稼働中（`alive`）** | `agent get` が `working` / `blocked`、または `pane process-info` でエージェントプロセス生存を確認 | 待機継続、`blocked` なら内容確認の上で応答またはユーザー確認 |
| **確証ある停止（`verified_stopped`）** | `agent get` で対象エージェント不在かつ `herdr pane process-info --pane <pane_id>` でフォアグラウンドが対話シェルへ戻っている／ペインが終了済み | 成果物・`pane read`・`HANDOFF.md` を確認し、再試行（後任起動）またはユーザー報告 |
| **判定不能（`unverifiable`）** | `agent get` が `unknown`、`agent wait` のタイムアウト、または沈黙のみ | **停止の証拠にならない**。`herdr agent explain <target>`・`herdr agent read`・`herdr pane process-info` で証拠を集め、不明なままならユーザーへ状況を報告する（独断で `pane close` や重複起動をしない） |

### 6.2 再試行とサーキットブレーカー（3 回上限）

1. タスクが失敗・クラッシュ・コンテキスト枯渇で中断した場合、新しい Task を作らず**同一 `task_id` の `attempts` をインクリメント**して後任を起動する。
2. **サーキットブレーカー**: `attempts` が **3 回**（3 回失敗）に達したら自動再試行を停止し、失敗の経緯・確認した出力ログ・`HANDOFF.md` をまとめてユーザーへ報告する。
3. **後任の起動手順**:
   - 前任がまだ対話可能で `HANDOFF.md` が古い場合は、`herdr agent prompt <old_name> "現在の進捗・成果・残作業を <handoff_path> に書き出して終了せよ" --wait` で書き出させてから交代する。
   - 前任ペインが安全に終了してシェルに戻っていれば同じペインを再利用するか、新ペイン（または同じ worktree 上の新ペイン）で連番エージェント名（例: `t1-w2`）を `herdr agent start` で起動する。
   - 後任用 spec 冒頭に [../task-spec-template.md](../task-spec-template.md) の「後任引き継ぎ用プレフィックス」を付け、前任の `HANDOFF.md` 読み込みを最優先指示する。

### 6.3 `context-guard` との連携

- [../context-guard.md](../context-guard.md) に従い、`pi` / `agy`（Antigravity）ワーカーを起動する前にワークスペースへ `context-guard` を導入できる。
- Herdr 上では Orca 司令塔への通知（`orca orchestration ask`）は不要なため、ペイン作成時に `--env` でサイレント設定を渡すとクリーンに動作する:
  ```bash
  herdr pane split --current --direction right --cwd "$PWD" --no-focus \
    --env AGY_CONTEXT_GUARD_SILENT=1 \
    --env PI_CONTEXT_GUARD_SILENT=1
  ```
- コンテキスト使用量が 80% を超えると、ワーカー自身の会話へ `HANDOFF.md` 更新＆終了指示が注入される。ワーカーが `HANDOFF.md` を保存して `idle` / `done` へ遷移したら、司令塔が `herdr agent read` と `HANDOFF.md` で引き継ぎ状態を確認し、同一 `(agent, model, effort)` で後任を起動する。

### 6.4 終了処理・クリーンアップと保持

- 完了したワーカーペインや worktree は Herdr 上で自動削除されない。ユーザーが結果を閲覧できるよう残すか、Run 完了報告後にユーザーの指示に従ってクリーンアップする。
- クリーンアップ時は必ず `.herdr-run/state.json` の `created_resources` に記録されたリソースだけを対象に、`herdr pane close <pane_id>` や `herdr worktree remove --workspace <workspace_id>`（必要時のみ `--force` をユーザー確認のうえ使用）を実行する。

### 6.5 司令塔セッションの復元

司令塔自身のコンテキストが尽きて新セッションへ引き継ぐ場合:
1. 新しい司令塔セッションも Herdr 管理ペイン内（`HERDR_ENV=1`）で起動し、本スキルと `<Run のルート>/HANDOFF.md` および `<Run のルート>/.herdr-run/state.json` を読み込む。
2. `herdr agent list`、`herdr workspace list`、`herdr pane list --workspace "$HERDR_WORKSPACE_ID"` を実行してライブ状態と `.herdr-run/state.json` を突き合わせる。
3. 稼働中・完了済み・`blocked` 中のワーカーを特定し、通常サイクル（①〜⑧）を再開する。

---

## 7. 参考コマンド早見表

```bash
# 前提・バージョン・公式ガイド
test "${HERDR_ENV:-}" = 1
herdr --version
herdr --skill
herdr status --json

# 状況把握
herdr workspace list
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr agent list
herdr api snapshot

# ペイン・ワークツリー作成（フォーカス維持）
herdr pane layout --pane "$HERDR_PANE_ID"
herdr pane split --current --direction right --cwd "$PWD" --no-focus
herdr worktree create --branch "orch/<task_id>" --base HEAD --label "<task_id>" --no-focus

# ワーカー起動・指示・待機・読取
herdr agent start <name> --kind <kind> --pane <pane_id> [-- <agent-args...>]
herdr agent prompt <name> "<text>" [--wait --timeout 120000]
herdr agent wait <name> [--until blocked] --timeout 120000
herdr agent get <name>
herdr agent explain <name>
herdr agent read <name> --source recent-unwrapped --lines 120
herdr agent send-keys <name> esc
herdr pane process-info --pane <pane_id>

# ユーザー通知・クリーンアップ（この Run で作成したもののみ）
herdr notification show "Orchestrator" --body "承認待ちまたはタスク完了のお知らせ"
herdr pane close <pane_id>
herdr worktree remove --workspace <workspace_id>
```
