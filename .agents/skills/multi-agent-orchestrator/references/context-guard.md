# context-guard 導入・運用ガイド（同梱ツール）

このリファレンスは、スキルに同梱されているコンテキスト枯渇予防ツール **`context-guard`**（[../scripts/context-guard/](../scripts/context-guard/)）の導入・設定・運用手順、および未対応エージェント／導入不可環境でのグレースフルデグラデーション方針を定義する。

対応エージェントは **`pi`（pi coding agent）**、**`Antigravity`**、**`vibe`（Mistral Vibe CLI）** の 3 種類である。

---

## 1. 役割と 2 段構えの引き継ぎ

多くの AI エージェントは自身のコンテキスト使用量を正確には把握できず、オーケストレーションバックエンド側も使用量を自動通知しないことが多い。そのため、本スキルではコンテキスト枯渇対策を **2 段構え** で設計している。

1. **第 1 段：`context-guard`（同梱・予防的引き継ぎ）**
   - ワーカーのコンテキスト使用量が閾値（既定 **80%**）に達した時点で自動検知する。
   - 司令塔へ通知を送り（現在 Orca 向け `orca orchestration ask --question` をベストエフォート実行）、同時にワーカー自身へ `HANDOFF.md` の更新とクリーンな終了処理をメッセージ注入で指示する。
   - 突然の打ち切りや記憶劣化が起きる前に、状態を保全したうえで後任へバトンを渡せる。
2. **第 2 段：`HANDOFF.md` 駆動の引き継ぎ（必須基盤・事後復元）**
   - ワーカーは作業の区切りごとに `<自分のワークスペース>/HANDOFF.md` を更新し続ける。
   - `context-guard` が未導入・未対応・未発火のままワーカーが停止・クラッシュしても、直近の `HANDOFF.md` と成果物から後任ワーカーが状況を復元できる（詳細は [./task-spec-template.md](./task-spec-template.md)）。

---

## 2. 同梱構成と探索順序

スキル内の標準パスは `<スキルディレクトリ>/scripts/context-guard/` である。

```text
scripts/context-guard/
├── pi/
│   ├── context-guard/index.ts   # pi 拡張機能本体
│   ├── install.sh               # global / project / status
│   └── uninstall.sh             # global / project / all
├── antigravity/
│   ├── context-guard.sh         # Antigravity PreInvocation hook 本体
│   ├── install.sh               # global / project / status
│   └── uninstall.sh             # global / project / all
└── vibe/
    ├── context-guard.sh         # Vibe post_llm / post_agent hook 本体
    ├── install.sh               # global / project / status
    └── uninstall.sh             # global / project / all
```

探索順序（外部オーバーライドがある場合にも対応）:
1. `<スキルディレクトリ>/scripts/context-guard/`（同梱・標準）
2. `./context-guard/`（ワークスペース直下に最新版が置かれている場合）
3. ユーザー指定の外部パス

---

## 3. エージェント種別ごとの導入・解除手順

導入は **ワーカー起動の直前**（推奨）、またはワーカー起動後の最初の作業指示を送る前に実施する。以下では配置先を `<context-guard-dir>`（標準は `<スキルディレクトリ>/scripts/context-guard`）と表記する。

### 事前チェック：グローバル導入済みならプロジェクト導入はスキップ可

対象エージェントのインストーラで状態を確認する。

```bash
<context-guard-dir>/<pi | antigravity | vibe>/install.sh status <ワーカーのワークスペース>
```

- `pi` / `antigravity` で `グローバル  : インストール済み`、または `vibe` で `グローバル  : 登録済み` と表示された場合は、ワーカー個別のワークスペースへの追加インストールは不要（スキップしてよい）。
- グローバル導入を行いたい場合は各エージェントで `./install.sh global`、解除は `./uninstall.sh <global | project [DIR] | all>` を使用する。

### エージェント別のプロジェクト導入

グローバル未導入の場合、ワーカーに割り当てたエージェント種別（[./model-routing.md](./model-routing.md) で確定した `agent`）に応じて次のコマンドを実行する。

#### 1. `pi`（pi coding agent）ワーカー

```bash
<context-guard-dir>/pi/install.sh project <ワーカーのワークスペース>
```

- **配置先**: `<ワーカーのワークスペース>/.pi/extensions/context-guard/index.ts`（グローバル時は `~/.pi/agent/extensions/context-guard/index.ts`）
- **有効化タイミング**: 次に `pi` を起動したとき（既存セッションの場合は `/reload` 実行後）。初回起動時に拡張機能の信頼（trust）を求められたら許可する。
- **動作**: `agent_end` で `ctx.getContextUsage()` を監視し、`pi.sendUserMessage(..., { deliverAs: "followUp" })` で引き継ぎ指示を注入（1 セッション 1 回）。`session_compact`（自動圧縮発生時）でも `HANDOFF.md` 保存を促す。

#### 2. `Antigravity` ワーカー

```bash
<context-guard-dir>/antigravity/install.sh project <ワーカーのワークスペース>
```

- **配置先**: `<ワーカーのワークスペース>/.agents/context-guard.sh` および `.agents/hooks.json`（グローバル時は `~/.gemini/config/context-guard/context-guard.sh` と `~/.gemini/config/hooks.json`）
- **前提**: JSON マージに `python3` または `node` のいずれかが必要。既存の `hooks.json`（例: Orca の `orca-status`）はバックアップ（`.bak-context-guard`）を取ったうえで安全にマージされる。
- **有効化タイミング**: ワークスペースの信頼（trust）後に有効。
- **動作**: `PreInvocation` フックで `transcriptPath` の最終トークン記録（`input_tokens + cache_read_tokens`）から使用率を計算し、`{"injectSteps": [{"userMessage": "..."}]}` で引き継ぎ指示を注入。二重発火防止マーカーを持ち、使用率が `REARM`（既定 50%）未満へ下がると自動で再発火可能に戻る。

#### 3. `vibe`（Mistral Vibe CLI）ワーカー

```bash
<context-guard-dir>/vibe/install.sh project <ワーカーのワークスペース>
```

- **配置先**: `<ワーカーのワークスペース>/.vibe/hooks/context-guard.sh` および `.vibe/hooks.toml`（グローバル時は `~/.vibe/hooks/context-guard.sh` と `~/.vibe/hooks.toml`）
- **既存設定の保護**: 既存の `hooks.toml` を壊さず managed block のみを追記・削除する。スコープ別の hook 名（`context-guard-{global|project}-post-llm` / `-post-agent`）を使うため、global と project の両方に導入しても `Duplicate hook name` 警告は出ず、マーカー共有により発火も 1 セッション 1 回に保たれる。
- **有効化タイミング**: プロジェクト設定はワークスペースの信頼（trust）後にのみ有効（初回起動時に許可、または `vibe --trust`）。既存セッションには再起動が必要。
- **動作**: `post_llm` フックで使用量（`input_tokens + output_tokens`、プロバイダ未報告 `usage: null` 時は無害スキップ）をセッション状態ファイルに記録し、`post_agent` フックで閾値判定して `{"decision":"deny","reason":"..."}` により引き継ぎ指示を会話に注入する。`REARM`（既定 50%）未満で使用量が下がると再発火可能に戻る。

#### 4. その他の未対応エージェント（`claude`, `codex`, `cursor` 等）

- 専用インストーラが提供されていないエージェントにはインストールを試みず、[6. グレースフルデグラデーション](#6-グレースフルデグラデーション) に従って運用する。

---

## 4. 設定（環境変数）

閾値検知は概算のため、安全マージンを取りたい場合は閾値を `0.75` 等へ下げて運用できる。

| エージェント | 発火閾値（既定 `0.8`） | ウィンドウ上限 | HANDOFF ファイル名（既定 `HANDOFF.md`） | 司令塔通知無効化（`1` で無効） | 再発火許可閾値（既定 `0.5`） |
|---|---|---|---|---|---|
| `pi` | `PI_CONTEXT_GUARD_THRESHOLD` | 自動取得 | `PI_CONTEXT_GUARD_HANDOFF` | `PI_CONTEXT_GUARD_SILENT` | —（1 セッション 1 回） |
| `Antigravity` | `AGY_CONTEXT_GUARD_THRESHOLD` | `AGY_CONTEXT_GUARD_WINDOW`（未設定時はモデル名推定、既定 1048576） | `AGY_CONTEXT_GUARD_HANDOFF` | `AGY_CONTEXT_GUARD_SILENT` | `AGY_CONTEXT_GUARD_REARM` |
| `vibe` | `VIBE_CONTEXT_GUARD_THRESHOLD` | `VIBE_CONTEXT_GUARD_WINDOW`（未設定時は `meta.json` 推定、不可時は 262144） | `VIBE_CONTEXT_GUARD_HANDOFF` | `VIBE_CONTEXT_GUARD_SILENT` | `VIBE_CONTEXT_GUARD_REARM`（`0` で再発火なし） |

> **非 Orca バックエンド（`herdr` 等）での挙動**: 司令塔通知（`orca orchestration ask`）はベストエフォートであり、Orca 非稼働・`herdr` バックエンド下でもワーカーへの `HANDOFF.md` 更新＆終了指示の注入は正常に機能する。`herdr` 等で不要な `orca` 呼び出しを止めたい場合は、対応する `*_CONTEXT_GUARD_SILENT=1` を環境変数（例: `herdr pane split --env AGY_CONTEXT_GUARD_SILENT=1 --env PI_CONTEXT_GUARD_SILENT=1 ...`）で渡す。詳細は [./backends/herdr.md](./backends/herdr.md) を参照。

---

## 5. 動作確認（手動スモークテスト）

導入前後で動作を単体確認したい場合は以下を実行できる。

```bash
# Antigravity hook の単体テスト（偽 transcript で発火を確認）
echo '{"step_index":1,"type":"PLANNER_RESPONSE","input_tokens":900000,"cache_read_tokens":0}' > /tmp/t.jsonl
echo '{"transcriptPath":"/tmp/t.jsonl","modelName":"gemini-3-pro","conversationId":"test"}' \
  | AGY_CONTEXT_GUARD_SILENT=1 <context-guard-dir>/antigravity/context-guard.sh
# → {"injectSteps": [{"userMessage": "[context-guard] ..."}]} が出れば OK

# vibe hook の単体テスト（post_llm で記録 → post_agent で発火を確認）
mkdir -p /tmp/vibe-test
echo '{"hook_event_name":"post_llm","session_id":"test","transcript_path":"/tmp/vibe-test","usage":{"input_tokens":220000,"output_tokens":0}}' \
  | <context-guard-dir>/vibe/context-guard.sh
echo '{"hook_event_name":"post_agent","session_id":"test","transcript_path":"/tmp/vibe-test","cwd":"/tmp"}' \
  | VIBE_CONTEXT_GUARD_SILENT=1 <context-guard-dir>/vibe/context-guard.sh
# → {"decision":"deny","reason":"[context-guard] ..."} が出れば OK
```

---

## 6. グレースフルデグラデーション

`context-guard` は第 1 段の予防機構であり、導入できなくてもオーケストレーション全体を止めない。次のいずれかに該当する場合は、**エラーにせず第 2 段（`HANDOFF.md` 駆動）のみで安全に続行する**。

- 対象ワーカーが未対応エージェント（`pi` / `Antigravity` / `vibe` 以外）である
- 権限不足・読み取り専用環境・ネットワーク分離・`python3`/`node` 不在（Antigravity 用）などによりインストールできない
- プロジェクトの trust 許可が取れずフックが有効化できない

### フォールバック時の必須対応

1. **Task spec に自己終了ルールを明記する**
   - [./task-spec-template.md](./task-spec-template.md) に従い、Task spec へ以下を必ず含める：
     > 「コンテキストが尽きそうだと感じたら作業を続けず、それまでの成果・現在地・残作業を `HANDOFF.md` に更新して終了報告せよ」
2. **区切りごとの `HANDOFF.md` 更新を徹底する**
   - ワーカーの動作規則として、小ステップ完了ごとに `<自分のワークスペース>/HANDOFF.md` を更新させる。
3. **司令塔の記録に状態を明記する**
   - `<Run のルート>/HANDOFF.md` に、該当ワーカーは「`context-guard` 未適用（HANDOFF 駆動のみで運用）」である旨を記録しておく。

---

## 7. `[context-guard]` 通知を受けたときの司令塔の対応フロー

稼働中のワーカーからバックエンドの質問・通知チャンネル経由で次のような通知が届いた場合の対応手順を定める。

> `[context-guard] ... コンテキスト使用量が 80%...`

司令塔は特別な例外処理を行わず、**通常の引き継ぎフロー**として次の順に処理する。

1. **即座に強制停止せず、ワーカーの終了報告を待つ**
   - ワーカーは通知と同時に `HANDOFF.md` の更新と終了処理を進めている。応答が必要なチャンネル（質問形式）であれば、「承知しました。`HANDOFF.md` を最新化して終了報告してください」と簡潔に返答し、バックエンドの `wait_strategy` に従ってワーカーの終了報告を待つ。
2. **停止の確認と `HANDOFF.md` の精査**
   - ワーカーから終了報告（またはバックエンドからの停止通知）を受けたら、バックエンドの状態確認手段（`worker_inspect`）で終了を確かめたうえで、`<ワーカーのワークスペース>/HANDOFF.md` と成果物・直近ログを確認する。
3. **`HANDOFF.md` が古い／空だった場合の補完**
   - 元ワーカーがまだ応答可能な状態なら、`worker_send` で現状を `HANDOFF.md` にまとめさせてから次へ進む。
   - すでに応答不可であれば、ワークスペース上の成果物ファイルと `worker_inspect` の出力ログから司令塔が状況を再構築し、後任の Task spec へ追記する。
4. **後任ワーカーの起動**
   - [./model-routing.md](./model-routing.md) の継続性ルールに従い、前任と**同一の `(agent, model, effort)`**（特に `pii` タスクは安全設定を厳格維持）で同じタスクに対する後任を `worker_start` で起動する。
   - [./task-spec-template.md](./task-spec-template.md) の「後任引き継ぎ用 Task spec 追記テンプレート」を先頭に付け、「まず `HANDOFF.md` を読んで状況を復元せよ」と明示する。
5. **司令塔の `HANDOFF.md` を更新して待機**
   - `<Run のルート>/HANDOFF.md` の進行中ワーカー情報を後任へ更新し、バックエンドの `wait_strategy` に従って次の通知を待つ。
