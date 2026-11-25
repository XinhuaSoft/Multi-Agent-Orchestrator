# Multi-Agent Orchestrator Skill (`multi-agent-orchestrator`)

[日本語](#日本語) | [English](#english) | [中文](#中文)

---

## 日本語

複数の AI ワーカーエージェントを司令塔（コーディネーター）として統括し、依存関係（DAG）のある多段階・並列タスクを計画・割り当て・監視・引き継ぎ・検証統合するための AI エージェントスキルです。

元の指示プロンプト（[orca-multi-agent-orchestrator.md](./orca-multi-agent-orchestrator.md)）と `context-guard` ソースをもとに、**コアプロトコル・モデル選定ポリシー・オーケストレーションバックエンド**の 3 層へ分離し、`context-guard` スクリプト一式を同梱して再設計しています。

### 主な特徴

- **バックエンド非依存のコア設計（`orca` / `herdr` 対応）**
  - スキル本体（`SKILL.md`）は 10 個の抽象操作だけで記述されており、特定のオーケストレーションツールに依存しません。
  - 現在 **`orca`**（既定）と **`herdr`** の 2 つのバックエンドに対応しており、さらに別のツールもアダプタ文書を追加するだけで拡張できます。
- **起動時の任意パラメータ指定（モデル＆バックエンド）**
  - **ワーカーモデル選定**: スキル起動時に一律指定・ロール別指定が可能で、省略しても既定の選定表（`model-routing.md`）で安全に開始できます。個人情報（PII）タスクには安全ガードが働きます。
  - **オーケストレーション＆通信バックエンド**: 起動時に `orca` / `herdr` を指定可能（省略時は既定の `orca`）。未実装バックエンドを指定した場合は暗黙にフォールバックせず確認を求めます。
- **コンテキスト枯渇に強い 2 段構えの引き継ぎ**
  - 第 1 段：`context-guard`（`scripts/context-guard/` に同梱、`pi` / `Antigravity` / `vibe` 対応。80% 到達時の事前通知・自己引き継ぎ。未対応エージェントや導入不可時もエラーにせず続行）
  - 第 2 段：`HANDOFF.md` 駆動の引き継ぎ（司令塔・ワーカー双方が進捗を記録し、後任へ復元）
- **証拠ベースの検証と安全規則**
  - 作業種別（コーディング／執筆／調査／複合）ごとの完了証拠、同一タスク 3 回失敗時のサーキットブレーカー、`unverifiable` な生存状態での独断停止禁止、人による承認プロンプトの代理許可禁止を組み込んでいます。

### ディレクトリ構成

```text
.
├── README.md                                                     # 本ドキュメント
├── orca-multi-agent-orchestrator.md                              # 設計元となった元の指示プロンプト
├── context-guard/                                                # 元の context-guard ソース
└── .agents/
    └── skills/
        └── multi-agent-orchestrator/
            ├── SKILL.md                                          # スキル本体（コアプロトコル・起動時 Intake）
            ├── references/
            │   ├── backends/
            │   │   ├── _contract.md                              # バックエンド共通契約（10 抽象操作・拡張手順）
            │   │   ├── orca.md                                   # Orca バックエンド実装（既定・イベント駆動）
            │   │   └── herdr.md                                  # Herdr バックエンド実装（Pull/Wait・ペイン＆worktree制御）
            │   ├── model-routing.md                              # 起動時モデル指定ルール・論理ロール・既定 9 パターン表
            │   ├── task-spec-template.md                         # 自己完結 Task spec / HANDOFF.md テンプレート
            │   └── context-guard.md                              # context-guard 導入・設定・フォールバックガイド
            └── scripts/
                └── context-guard/                                # 同梱 context-guard（global/project 導入・解除対応）
                    ├── pi/                                       # pi 拡張機能 (index.ts, install.sh, uninstall.sh)
                    ├── antigravity/                              # Antigravity hook (context-guard.sh, install.sh, uninstall.sh)
                    └── vibe/                                     # Mistral Vibe hook (context-guard.sh, install.sh, uninstall.sh)
```

### 使い方

#### 1. このワークスペースで使う

スキルは `.agents/skills/multi-agent-orchestrator/` に配置済みのため、Antigravity などの `.agents/skills/` 対応エージェントはこのワークスペース内でそのままスキルを自動認識します。

#### 2. 他のプロジェクトやマシン全体で使う

- **別プロジェクトへ導入**: `.agents/skills/multi-agent-orchestrator/` フォルダを、対象リポジトリの `.agents/skills/` 配下へコピーします（`scripts/context-guard/` も同梱されているためそのまま持ち運べます）。
- **マシン全体（グローバル）へ導入（Antigravity）**:
  ```bash
  mkdir -p ~/.gemini/config/skills
  cp -R .agents/skills/multi-agent-orchestrator ~/.gemini/config/skills/
  ```

#### 3. 起動時の指定例

スキルを起動する際、バックエンドやワーカーモデルは**指定しても省略しても**動作します。

- **指定なし（最短・既定構成）**
  > 「`multi-agent-orchestrator` を使って、〇〇の設計・実装・テストを進めてください」
  - バックエンドは `orca`、ワーカーモデルは [model-routing.md](./.agents/skills/multi-agent-orchestrator/references/model-routing.md) の既定構成（`complex` / `clerical` / `simple` / `pii`）が選ばれ、開始前に復唱・確認されます。

- **バックエンドに `herdr` を指定**
  > 「`multi-agent-orchestrator` で、バックエンドは `herdr` を使って〇〇を進めてください」
  - Herdr 管理ペイン内（`HERDR_ENV=1`）で [herdr.md](./.agents/skills/multi-agent-orchestrator/references/backends/herdr.md) に従い、ペイン分割／Git worktree・`herdr agent start` / `prompt` / `wait` / `read` とローカル DAG 状態ファイル（`.herdr-run/state.json`）で統括します。

- **ワーカーモデルを一律指定**
  > 「`multi-agent-orchestrator` を使って、ワーカーはすべて Antigravity の Gemini 4 Hydrogen で、〇〇を進めてください」
  - 全サブタスクに指定モデルを適用します（ただし PII を含むサブタスクがある場合は事前に安全確認が入ります）。

- **ロール別にワーカーモデルを指定**
  > 「`multi-agent-orchestrator` で、複雑タスクは Gemini 4 Neon、定型編集は Gemini 4 Hydrogen、個人情報処理は pi (Qwen3.8-Flash-Next High) を使って進めてください」

### 対応バックエンドと拡張手順

| Backend ID | 状態 | 待機・制御方式 | アダプタ文書 |
|---|---|---|---|
| `orca` | 対応済み（既定） | イベント駆動（wake / `end turn`）、ネイティブ DAG・メール | [.agents/skills/multi-agent-orchestrator/references/backends/orca.md](./.agents/skills/multi-agent-orchestrator/references/backends/orca.md) |
| `herdr` | 対応済み | Pull / Blocking Wait（`agent prompt --wait` / `agent wait`）、ペイン＆worktree 制御＋ローカル DAG 管理（要 `HERDR_ENV=1`） | [.agents/skills/multi-agent-orchestrator/references/backends/herdr.md](./.agents/skills/multi-agent-orchestrator/references/backends/herdr.md) |

#### さらに新しいバックエンドを追加する手順

詳細は [_contract.md](./.agents/skills/multi-agent-orchestrator/references/backends/_contract.md) に定義されています。概要は次のとおりです。

1. `.agents/skills/multi-agent-orchestrator/references/backends/<backend_id>.md` を新規作成し、`_contract.md` の 10 個の抽象操作（`run_create`, `task_create`, `task_list_ready`, `worker_start`, `worker_send`, `worker_reply`, `inbox_check`, `worker_inspect`, `worker_stop`, `wait_strategy`）および待機・隔離・モデル変換・復旧手順を記述する。
2. [SKILL.md](./.agents/skills/multi-agent-orchestrator/SKILL.md) の「リファレンス一覧」と「現在サポートしているバックエンド」一覧へ新しい Backend ID を追記する。
3. 最小の 2 タスク DAG（並列・依存あり）で通し検証を行う。

### `context-guard`（同梱ツール）について

ワーカーのコンテキスト使用量 80% 到達を事前検知して司令塔通知・`HANDOFF.md` 更新指示を行う `context-guard` は、スキル内の `.agents/skills/multi-agent-orchestrator/scripts/context-guard/` に同梱されています。

- **対応エージェント**: `pi`（pi 拡張機能）、`Antigravity`（`PreInvocation` hook）、`vibe`（`post_llm` / `post_agent` hook）の 3 種類。
- 各エージェントフォルダの `./install.sh <global | project [DIR] | status>` および `./uninstall.sh` で導入・確認・解除できます。
- `herdr` バックエンド上では `*_CONTEXT_GUARD_SILENT=1` を `--env` で渡すことで不要な Orca 通知を抑止しつつ、`HANDOFF.md` 更新指示の注入を活用できます。
- その他の未対応エージェント（`claude` / `codex` / `cursor` 等）や導入不可環境ではエラーにならず、`HANDOFF.md` 駆動の引き継ぎ（第 2 段）のみで安全に動作します。詳細は [context-guard.md](./.agents/skills/multi-agent-orchestrator/references/context-guard.md) を参照してください。

---

## English

An AI agent skill that turns the primary agent into a **coordinator** supervising multiple worker agents to plan, dispatch, monitor, hand off, verify, and integrate multi-stage and parallel tasks with DAG dependencies.

Redesigned from the original single-file prompt ([orca-multi-agent-orchestrator.md](./orca-multi-agent-orchestrator.md)) and bundled with `context-guard`, separated into three decoupled layers: **Core Protocol**, **Model Routing Policy**, and **Orchestration Backend Adapters**.

### Key Features

- **Backend-Agnostic Core (`orca` & `herdr` Supported)**
  - The main `SKILL.md` is written purely in terms of 10 abstract operations, without coupling to any specific orchestration CLI.
  - Supports both **`orca`** (default) and **`herdr`**, and additional backends can be plugged in via the adapter contract without modifying the core workflow.
- **Optional Invocation-Time Configuration (Models & Backend)**
  - **Worker Model Selection**: Specify a uniform model or role-based routing when invoking the skill, or omit it to fall back cleanly to the default presets in `model-routing.md`. Tasks handling personal data (PII) are protected by a safety guard.
  - **Orchestration & Communication Backend**: Select `orca` or `herdr` at invocation time (defaults to `orca`). If an unimplemented backend is requested, the coordinator will not silently fall back to `orca` and will ask how to proceed.
- **Two-Tier Context Exhaustion Continuity**
  - Tier 1: Bundled `context-guard` (`scripts/context-guard/`, supporting `pi`, `Antigravity`, and `vibe` for 80% context warning & proactive handoff; gracefully degrades for unsupported agents or restricted environments).
  - Tier 2: Mandatory `HANDOFF.md`-driven recovery for both coordinator and workers.
- **Evidence-Based Verification & Safety Rules**
  - Work-type completion evidence (coding / writing / research / composite), a 3-failure circuit breaker per task, strict prohibition against assuming exit from `unverifiable` liveness, and never auto-approving human-only approval prompts.

### Directory Structure

```text
.
├── README.md                                                     # This document
├── orca-multi-agent-orchestrator.md                              # Original source prompt
├── context-guard/                                                # Original context-guard source
└── .agents/
    └── skills/
        └── multi-agent-orchestrator/
            ├── SKILL.md                                          # Core skill protocol & invocation-time intake
            ├── references/
            │   ├── backends/
            │   │   ├── _contract.md                              # Backend adapter contract (10 abstract ops & extension guide)
            │   │   ├── orca.md                                   # Orca backend adapter (default, event-driven)
            │   │   └── herdr.md                                  # Herdr backend adapter (pull/wait, pane & worktree control)
            │   ├── model-routing.md                              # Invocation override rules, logical roles & 9 default presets
            │   ├── task-spec-template.md                         # Self-contained Task spec & HANDOFF.md templates
            │   └── context-guard.md                              # Bundled context-guard setup, env vars & fallback guide
            └── scripts/
                └── context-guard/                                # Bundled context-guard (global/project install & uninstall)
                    ├── pi/                                       # pi extension (index.ts, install.sh, uninstall.sh)
                    ├── antigravity/                              # Antigravity hook (context-guard.sh, install.sh, uninstall.sh)
                    └── vibe/                                     # Mistral Vibe hook (context-guard.sh, install.sh, uninstall.sh)
```

### Usage

#### 1. Use in This Workspace

The skill is placed at `.agents/skills/multi-agent-orchestrator/`, so Antigravity and other agents supporting `.agents/skills/` discover it automatically in this workspace.

#### 2. Install in Another Project or Globally

- **Another project**: Copy `.agents/skills/multi-agent-orchestrator/` into `<target-repo>/.agents/skills/` (it is self-contained, including `scripts/context-guard/`).
- **Machine-wide (Antigravity global config)**:
  ```bash
  mkdir -p ~/.gemini/config/skills
  cp -R .agents/skills/multi-agent-orchestrator ~/.gemini/config/skills/
  ```

#### 3. Invocation Examples

Both backend and worker model configuration are optional when invoking the skill:

- **Default (no overrides)**
  > "Use `multi-agent-orchestrator` to design, implement, and test feature X."
  - Defaults to `backend=orca` and the preset routing table in [model-routing.md](./.agents/skills/multi-agent-orchestrator/references/model-routing.md) (`complex` / `clerical` / `simple` / `pii`), echoing the resolved configuration before creating a Run.

- **Explicitly Select `herdr` Backend**
  > "Use `multi-agent-orchestrator` with backend `herdr` to complete X."
  - Inside a Herdr-managed pane (`HERDR_ENV=1`), follows [herdr.md](./.agents/skills/multi-agent-orchestrator/references/backends/herdr.md) using pane splits / Git worktrees, `herdr agent start` / `prompt` / `wait` / `read`, and local DAG state tracking (`.herdr-run/state.json`).

- **Uniform Worker Model**
  > "Use `multi-agent-orchestrator` with Antigravity Gemini 4 Hydrogen for all workers to complete X."
  - Applies the specified model across tasks (still prompting for confirmation if any subtask involves PII).

- **Role-Based Worker Models**
  > "Use `multi-agent-orchestrator` with Gemini 4 Neon for complex tasks, Gemini 4 Hydrogen for clerical edits, and pi (Qwen3.8-Flash-Next High) for PII tasks."

### Supported Backends & Adding More Backends

| Backend ID | Status | Control & Waiting Model | Adapter Document |
|---|---|---|---|
| `orca` | Supported (Default) | Event-driven wake (`end turn`), native DAG & mail | [.agents/skills/multi-agent-orchestrator/references/backends/orca.md](./.agents/skills/multi-agent-orchestrator/references/backends/orca.md) |
| `herdr` | Supported | Pull / blocking wait (`agent prompt --wait` / `agent wait`), pane & Git worktree control + local DAG state (requires `HERDR_ENV=1`) | [.agents/skills/multi-agent-orchestrator/references/backends/herdr.md](./.agents/skills/multi-agent-orchestrator/references/backends/herdr.md) |

#### How to Add Another Backend

See [_contract.md](./.agents/skills/multi-agent-orchestrator/references/backends/_contract.md) for full details. In short:

1. Create `.agents/skills/multi-agent-orchestrator/references/backends/<backend_id>.md` mapping all 10 abstract operations (`run_create`, `task_create`, `task_list_ready`, `worker_start`, `worker_send`, `worker_reply`, `inbox_check`, `worker_inspect`, `worker_stop`, `wait_strategy`), plus waiting, workspace isolation, model flag conversion, and recovery semantics.
2. Register the new Backend ID in the reference table and supported backends list in [SKILL.md](./.agents/skills/multi-agent-orchestrator/SKILL.md).
3. Run an end-to-end smoke test with a minimal 2-task DAG (parallel + dependent).

### Bundled `context-guard` Tool

`context-guard` (which detects 80% context usage, notifies the coordinator, and instructs the worker to save `HANDOFF.md` and wrap up) is bundled inside `.agents/skills/multi-agent-orchestrator/scripts/context-guard/`:

- **Supported agents**: `pi` (pi extension), `Antigravity` (`PreInvocation` hook), and `vibe` (`post_llm` / `post_agent` hooks).
- Each agent directory provides `./install.sh <global | project [DIR] | status>` and `./uninstall.sh`.
- On `herdr`, pass `*_CONTEXT_GUARD_SILENT=1` via `--env` when splitting panes to suppress Orca-specific calls while keeping `HANDOFF.md` handoff prompt injection active.
- For other agents (`claude`, `codex`, `cursor`, etc.) or environments where installation is unavailable, the workflow does not fail and safely falls back to Tier 2 (`HANDOFF.md`-driven continuity). See [context-guard.md](./.agents/skills/multi-agent-orchestrator/references/context-guard.md).

---

## 中文

这是一个 AI Agent 技能（Skill），用于让主会话作为**总控协调者（Coordinator）**统筹多个 Worker Agent，对包含依赖关系（DAG）的多阶段及并行任务进行规划、分发、监控、交接、验证与集成。

本技能基于原始单文件提示词（[orca-multi-agent-orchestrator.md](./orca-multi-agent-orchestrator.md)）与 `context-guard` 源码重构，解耦为**核心协议、模型路由策略、编排后端适配器**三层架构，并内置了完整的 `context-guard` 工具脚本。

### 核心特性

- **与编排后端解耦的核心设计（支持 `orca` 与 `herdr`）**
  - 主文件 `SKILL.md` 仅通过 10 个抽象操作描述协调流程，不绑定任何具体编排工具的命令。
  - 当前已支持 **`orca`**（默认）和 **`herdr`** 两种编排后端，未来也可按适配器契约轻松扩展更多后端，无需修改核心流程。
- **启动时可选参数配置（模型与后端）**
  - **Worker 模型选择**：触发技能时可统一指定或按任务角色指定，也可省略（自动回退至 `model-routing.md` 中的默认预设表）。涉及个人信息（PII）的子任务受安全护栏保护。
  - **编排与通信后端**：触发技能时可指定 `orca` 或 `herdr`（未指定时默认使用 `orca`）。若指定尚未实现的其他后端，不会静默回退到 `orca`，而是明确提示并征询处理方式。
- **双层防上下文耗尽交接机制**
  - 第一层：内置 `context-guard`（位于 `scripts/context-guard/`，支持 `pi`、`Antigravity`、`vibe`，上下文占用达 80% 时预警并触发自我交接；不支持的 Agent 或无法安装时优雅降级，不报错中断）。
  - 第二层：基于 `HANDOFF.md` 的强制交接恢复机制（覆盖总控与所有 Worker）。
- **基于证据的验收与安全规则**
  - 按任务类型（编码 / 写作 / 调研 / 复合任务）明确完成证据；单任务失败 3 次触发熔断并上报用户；严禁仅凭 `unverifiable` 或静默就判定 Worker 已退出；严禁擅自代替人类批准审批请求。

### 目录结构

```text
.
├── README.md                                                     # 本文档
├── orca-multi-agent-orchestrator.md                              # 原始参考提示词
├── context-guard/                                                # 原始 context-guard 源码
└── .agents/
    └── skills/
        └── multi-agent-orchestrator/
            ├── SKILL.md                                          # 技能主文件（核心协议与启动参数解析）
            ├── references/
            │   ├── backends/
            │   │   ├── _contract.md                              # 后端适配器契约（10 个抽象操作与扩展指南）
            │   │   ├── orca.md                                   # Orca 后端适配器（默认・事件驱动）
            │   │   └── herdr.md                                  # Herdr 后端适配器（Pull/Wait・窗格与 worktree 控制）
            │   ├── model-routing.md                              # 启动时模型覆盖规则、逻辑角色与 9 组默认预设
            │   ├── task-spec-template.md                         # 自包含 Task spec 与 HANDOFF.md 模板
            │   └── context-guard.md                              # 内置 context-guard 安装、环境变量与降级指南
            └── scripts/
                └── context-guard/                                # 内置 context-guard（支持 global/project 安装与卸载）
                    ├── pi/                                       # pi 扩展 (index.ts, install.sh, uninstall.sh)
                    ├── antigravity/                              # Antigravity hook (context-guard.sh, install.sh, uninstall.sh)
                    └── vibe/                                     # Mistral Vibe hook (context-guard.sh, install.sh, uninstall.sh)
```

### 使用方法

#### 1. 在当前工作区直接使用

技能已放置于 `.agents/skills/multi-agent-orchestrator/`，支持 `.agents/skills/` 的 Agent（如 Antigravity）在当前工作区内会自动发现并加载。

#### 2. 部署到其他项目或全局环境

- **部署到其他项目**：将 `.agents/skills/multi-agent-orchestrator/` 复制到目标仓库的 `.agents/skills/` 目录下（已内置 `scripts/context-guard/`，可直接完整迁移）。
- **全局部署（Antigravity）**：
  ```bash
  mkdir -p ~/.gemini/config/skills
  cp -R .agents/skills/multi-agent-orchestrator ~/.gemini/config/skills/
  ```

#### 3. 触发调用示例

启动技能时，编排后端与 Worker 模型均为**可选配置**：

- **不指定参数（默认配置）**
  > “使用 `multi-agent-orchestrator` 完成 XX 的设计、实现与测试。”
  - 默认选用 `backend=orca` 及 [model-routing.md](./.agents/skills/multi-agent-orchestrator/references/model-routing.md) 中的默认角色配置（`complex` / `clerical` / `simple` / `pii`），并在创建 Run 前向用户复述确认。

- **指定使用 `herdr` 后端**
  > “使用 `multi-agent-orchestrator`，编排后端指定为 `herdr` 来推进 XX。”
  - 在 Herdr 管理的终端窗格内（`HERDR_ENV=1`），按 [herdr.md](./.agents/skills/multi-agent-orchestrator/references/backends/herdr.md) 规范，通过窗格切分 / Git worktree、`herdr agent start` / `prompt` / `wait` / `read` 以及本地 DAG 状态文件（`.herdr-run/state.json`）完成统筹。

- **统一指定 Worker 模型**
  > “使用 `multi-agent-orchestrator`，所有 Worker 统一用 Antigravity 的 Gemini 4 Hydrogen 来完成 XX。”
  - 将指定模型应用于所有子任务（如检测到包含 PII 的子任务，仍会先进行安全确认）。

- **按角色分别指定 Worker 模型**
  > “使用 `multi-agent-orchestrator`，复杂任务用 Gemini 4 Neon，常规整理用 Gemini 4 Hydrogen，个人信息处理用 pi (Qwen3.8-Flash-Next High)。”

### 支持的后端与扩展方式

| Backend ID | 状态 | 控制与等待模型 | 适配器文档 |
|---|---|---|---|
| `orca` | 已支持（默认） | 事件驱动唤醒（`end turn`）、原生 DAG 与消息邮箱 | [.agents/skills/multi-agent-orchestrator/references/backends/orca.md](./.agents/skills/multi-agent-orchestrator/references/backends/orca.md) |
| `herdr` | 已支持 | Pull / 阻塞等待（`agent prompt --wait` / `agent wait`）、窗格与 Git worktree 控制 + 本地 DAG 管理（需 `HERDR_ENV=1`） | [.agents/skills/multi-agent-orchestrator/references/backends/herdr.md](./.agents/skills/multi-agent-orchestrator/references/backends/herdr.md) |

#### 新增其他编排后端的步骤

完整规范请参阅 [_contract.md](./.agents/skills/multi-agent-orchestrator/references/backends/_contract.md)，核心步骤如下：

1. 新建 `.agents/skills/multi-agent-orchestrator/references/backends/<backend_id>.md`，实现 `_contract.md` 中的 10 个抽象操作（`run_create`、`task_create`、`task_list_ready`、`worker_start`、`worker_send`、`worker_reply`、`inbox_check`、`worker_inspect`、`worker_stop`、`wait_strategy`），并写明等待方式、工作区隔离、模型参数映射与异常恢复规则。
2. 在 [SKILL.md](./.agents/skills/multi-agent-orchestrator/SKILL.md) 的参考文档列表和受支持后端列表中注册新的 Backend ID。
3. 使用最小的 2 任务 DAG（包含并行与依赖关系）进行端到端验证。

### 内置 `context-guard` 工具说明

用于检测上下文使用率达到 80%、通知总控并指示 Worker 保存 `HANDOFF.md` 后退出的 `context-guard` 已内置于 `.agents/skills/multi-agent-orchestrator/scripts/context-guard/`：

- **支持的 Agent**：`pi`（pi 扩展）、`Antigravity`（`PreInvocation` hook）、`vibe`（`post_llm` / `post_agent` hook）。
- 各 Agent 目录下均提供 `./install.sh <global | project [DIR] | status>` 与 `./uninstall.sh`。
- 在 `herdr` 后端下，可在切分窗格时通过 `--env` 传入 `*_CONTEXT_GUARD_SILENT=1`，跳过不必要的 Orca 通知，同时保留 `HANDOFF.md` 交接提示注入功能。
- 若目标 Agent 暂不支持（如 `claude`、`codex`、`cursor` 等）或受环境限制无法安装，不会中断流程，而是自动降级为仅使用第二层 `HANDOFF.md` 驱动的交接机制。详情见 [context-guard.md](./.agents/skills/multi-agent-orchestrator/references/context-guard.md)。
