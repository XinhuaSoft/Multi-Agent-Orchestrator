#!/bin/sh
# context-guard — Vibe CLI (mistral-vibe) hook
#
# mistral-vibe の hooks.toml から呼ばれ、コンテキスト使用量が閾値(既定 80%)を
# 超えていたら(pi / Antigravity 版の vibe 相当):
#   1. Orca のコーディネーター(司令塔)に通知(best-effort、Orca 非稼働なら静かに無視)
#   2. エージェント自身に HANDOFF.md の更新と終了処理を指示(post_agent の
#      {"decision":"deny","reason":"..."} は reason を retry user message
#      として会話に注入する = pi 版 sendUserMessage(followUp) 相当)
#
# === 設計(採用): 2 つの hook エントリからこの 1 スクリプトを type 分岐で使う ===
#   post_llm  : usage を session_id でキーした状態ファイルに記録(発火しない)
#   post_agent: 状態ファイルの使用量が閾値超過かつ未発火マーカーなら
#               ① 司令塔へ通知 ② deny+reason で引き継ぎ指示を注入
#   post_llm の deny は「その応答の破棄 + reason を feedback にモデル再試行」を伴うため
#   使わない。post_llm/post_agent の retry は 1 ターン合計 3 回予算で有界 + 発火は
#   marker により 1 セッション 1 回(+REARM 解除後 1 回)に限定される。
#
# === usage 計算の根拠(vibe 3.1.4 実装から検証) ===
#   ペイロードの usage = TokenUsage{input,output,total,cached_input,cache_write,reasoning}:
#   (a) 正規化は mistralai/vibe/harness/runtime/completion/profile/formats.py read_usage():
#       input_tokens = 生 input + extra_input(ANTHROPIC では cache_read + cache_creation、
#       MISTRAL/OPENAI では prompt_tokens が元々 cached を含む)。
#   (b) core/protocol.py の検証: total_tokens == input + output、
#       cached_input_tokens <= input_tokens(= cached は input に含まれる)。
#   (c) Vibe 自身の context ゲージ(_unified_harness_backend_adapter.py _context_tokens)は
#       直近呼び出しの input_tokens + output_tokens。
#   → 使用量 = usage.input_tokens + usage.output_tokens(= total_tokens)。
#     cached_input_tokens / cache_write_tokens を加算すると二重計上になる。
#   usage:null(プロバイダが報告しない)は要件どおり「無害」: 何もせず空出力で終了。
#
# === コンテキストウィンドウの既定値の根拠 ===
#   VIBE_CONTEXT_GUARD_WINDOW 未設定時は <transcript_path>/meta.json の
#   config.model_name(正規名)→ config.active_model(alias)の順で推定する
#   (vibe/core/types.py: 新規セッションは最初のユーザーターン前に両者を記録。
#   正規名 model_name を優先するため、alias がカスタム名「my-large-model」等
#   でも正規名から推定できる。model_name の無い旧セッションは alias で判定)。
#   known_models.py(vibe 3.1.4)の context_window 表:
#     mistral-large-4 系 1048576 / mistral-medium-3.5 系・large(latest/2512) 262144 /
#     zai-glm-5 系 1048576 / claude 系 1000000(haiku-4-5 のみ 200000)/
#     gpt-6 系・gpt-5.5(±pro)・gpt-5.4(±pro)・gpt-5.6(sol/terra/luna) 1050000 /
#     gpt-5.2(±pro)・gpt-5.4-mini・gpt-5.6-cyber・gpt-5(±pro/mini/nano) 400000
#   (gpt-5.2/5.4-mini/5.6-cyber は 400000 — 広域パターン(1050000)より前に
#    置かないと 80% 閾値=840000 に達する前に実ウィンドウ 400000 を overflow する)
#   推定不能なら 262144(bounds.py DEFAULT_CONTEXT_WINDOW — Vibe 自身が不明モデルに
#   使う保守値。実ウィンドウより小さいので発火が早まり過敏になるだけで、
#   「閾値を検み逃す」方向のリスクは実質ない)。
#
# === 状態ファイルとフック実行に関する注意事项 ===
#   - 状態/marker は <transcript_path>/.context-guard/usage-<sid> / fired-<sid>。
#     transcript_path = セッションの保存ディレクトリ(session 単位で自動分離、subagent は
#     別 session_id で分離される)。書けない場合は ${TMPDIR:-/tmp} に fallback。
#   - フック終了時にプロセスグループ全体が SIGKILL されるため、司令塔通知は
#     perl で setsid して新セッションに逃してから実行する。
#   - stdout は「空」or 厳密な {"decision":"deny","reason":"..."} のみ。壊れた出力は絶対に
#     出さない(それ以外は fail-open + UI warning になる)。例外パスはすべて exit 0 + 空出力。
#   - hooks.toml の name はファイル内一意に加え、Vibe は global/project の全
#     hooks.toml を横断して重複チェックし、Duplicate hook name の後読みを
#     config issue(skip)にする。そのためインストーラはスコープ別の
#     context-guard-{global|project}-post-llm / -post-agent の 2 entry を書く。
#     marker/usage ファイルはスコープに依らず transcript 単位で共用なので、
#     両スコープに定義されても post_agent の発火は marker により 1 回のまま。
#
# 入力(stdin): hooks.toml 共通 JSON(hook_event_name で分岐)
# 出力(stdout): 空、または {"decision":"deny","reason":"<引き継ぎ指示>"}(post_agent のみ)
# 終了コード: 常に 0(stderr は診断用 — 何も出さない)
#
# 環境変数:
#   VIBE_CONTEXT_GUARD_THRESHOLD  発火閾値 0.05〜1.0(既定 0.8、clamp)
#   VIBE_CONTEXT_GUARD_WINDOW     コンテキストウィンドウ(トークン数)。未設定時は
#                                 meta.json のモデル名から推定(不可なら 262144)
#   VIBE_CONTEXT_GUARD_HANDOFF    HANDOFF ファイル名(既定 HANDOFF.md)
#   VIBE_CONTEXT_GUARD_SILENT     "1" でコーディネーター通知を止める
#   VIBE_CONTEXT_GUARD_REARM      使用量がこの比率を下回ったら再発火許可(既定 0.5)。
#                                 実稼働では THRESHOLD > REARM になるよう設定すること
#                                 (THRESHOLD < REARM の場合、使用量が REARM 未満に
#                                 なるたびに毎ターン再発火し retry 予算を消費する。
#                                 ループは post_llm/post_agent の共有 retry 予算 3 で
#                                 常に有界)。0 にすると再発火なし(1 セッション 1 回)。

set -u

# --- 設定(環境変数) ----------------------------------------------------------

THRESHOLD="${VIBE_CONTEXT_GUARD_THRESHOLD:-0.8}"
HANDOFF_FILE="${VIBE_CONTEXT_GUARD_HANDOFF:-HANDOFF.md}"
REARM="${VIBE_CONTEXT_GUARD_REARM:-0.5}"
SILENT="${VIBE_CONTEXT_GUARD_SILENT:-0}"

case "$THRESHOLD" in ''|*[!0-9.]*) THRESHOLD=0.8 ;; esac
THRESHOLD_X100=$(awk -v t="$THRESHOLD" 'BEGIN { if (t != t || t <= 0) t = 0.8; if (t < 0.05) t = 0.05; if (t > 1.0) t = 1.0; printf "%d", t * 100 }')
case "$THRESHOLD_X100" in ''|*[!0-9]*) THRESHOLD_X100=80 ;; esac

case "$REARM" in ''|*[!0-9.]*) REARM=0.5 ;; esac
REARM_X100=$(awk -v t="$REARM" 'BEGIN { if (t != t || t < 0) t = 0.5; if (t > 1.0) t = 1.0; printf "%d", t * 100 }')
case "$REARM_X100" in ''|*[!0-9]*) REARM_X100=50 ;; esac

# --- stdin ペイロード ----------------------------------------------------------
# hooks.toml のフックには JSON payload が 1 行で渡される(json.dumps)。
INPUT_ALL=$(cat 2>/dev/null || true)
[ -n "$INPUT_ALL" ] || exit 0

# JSON 文字列フィールド抽出(素朴なパターンマッチ; エスケープは無視 — 既存
# Antigravity 版と同じアプローチ。base payload の先頭(session_id / transcript_path /
# cwd / hook_event_name)はユーザ影響可能な内容(response_text / tool_input)より
# 前に現れるため先頭マッチで安全)。
json_str_first() {
	_jv=$(printf '%s' "$INPUT_ALL" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1)
	printf '%s' "$_jv" | sed "s/^\"$1\"[[:space:]]*:[[:space:]]*\"//; s/\"$//"
}

# JSON 数値フィールド抽出(対象文字列は $2 で指定)。post_llm では usage オブジェ
# クト本体のみを渡すため、response_text / tool_input 等に偽の "input_tokens":N
# が含まれていても決して拾わない(review Finding 3 対策)。
json_num_last() {
	_jv=$(printf '%s' "$2" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" | tail -1)
	printf '%s' "$_jv" | grep -o '[0-9][0-9]*$'
}

# インタポレーション用サニタイズ(JSON 出力の壊れ防止)
clean() { printf '%s' "$1" | sed 's/["\\]//g'; }

EVENT=$(json_str_first hook_event_name)
SESSION_ID=$(printf '%s' "$(json_str_first session_id)" | sed 's/["\\/]//g')
TRANSCRIPT=$(json_str_first transcript_path)
CWD=$(clean "$(json_str_first cwd)")
HANDOFF=$(clean "$HANDOFF_FILE")

# --- 状態ディレクトリ: session ディレクトリ直下の .context-guard/ -----------------
STATE_DIR=""
if [ -n "$TRANSCRIPT" ] && [ -d "$TRANSCRIPT" ]; then
	if mkdir -p "$TRANSCRIPT/.context-guard" 2>/dev/null && [ -w "$TRANSCRIPT/.context-guard" ]; then
		STATE_DIR="$TRANSCRIPT/.context-guard"
	fi
fi
if [ -z "$STATE_DIR" ]; then
	_td="${TMPDIR:-/tmp}/context-guard-state"
	if mkdir -p "$_td" 2>/dev/null; then
		STATE_DIR="$_td"
	fi
fi

# --- コンテキストウィンドウ ----------------------------------------------------
window_for_model() {
	case "$1" in
		*mistral-large-4*|*mistral-large-4-*) echo 1048576 ;;
		*mistral-large*|*mistral-medium*|*magistral*|*mistral-vibe-cli*) echo 262144 ;;
		*zai-glm-5*|*zai-glm*) echo 1048576 ;;
		*claude-haiku-4-5*) echo 200000 ;;
		*claude*) echo 1000000 ;;
		*gpt-5.2*|*gpt-5.4-mini*|*gpt-5.6-cyber*) echo 400000 ;;
		*gpt-6*|*gpt-5.5*|*gpt-5.6*|*gpt-5.4*) echo 1050000 ;;
		*gpt-5*) echo 400000 ;;
		*) echo 262144 ;;
	esac
}

resolve_window() {
	if [ -n "${VIBE_CONTEXT_GUARD_WINDOW:-}" ]; then
		case "$VIBE_CONTEXT_GUARD_WINDOW" in
			''|*[!0-9]*) ;;
			*)
				# 先行ゼロを除去(0 埋めは $(( )) で 8 進数と解釈されるため)
				_w=$(printf '%s' "$VIBE_CONTEXT_GUARD_WINDOW" | sed 's/^0*//')
				: "${_w:=0}"
				if [ "$_w" -gt 0 ]; then
					echo "$_w"
					return
				fi
				;;
		esac
	fi
	# meta.json の config snapshot(vibe/core/types.py: 新規セッションは最初の
	# ユーザーターン前に active_model(alias)と model_name(正規名)を記録)。
	# 正規の model_name を優先し、無ければ alias の active_model で判定する。
	_m=$(sed -n 's/.*"model_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/meta.json" 2>/dev/null | head -1)
	[ -n "$_m" ] || _m=$(sed -n 's/.*"active_model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/meta.json" 2>/dev/null | head -1)
	if [ -n "$_m" ]; then
		window_for_model "$_m"
	else
		echo 262144
	fi
}

# --- 使い回し: marker / state ファイル ----------------------------------------
# STATE_DIR が空でもこれ以降の変数は空文字になり、[ -f "" ] は失敗するだけ。
MARKER=""
USAGE_FILE=""
if [ -n "$STATE_DIR" ] && [ -n "$SESSION_ID" ]; then
	MARKER="$STATE_DIR/fired-$SESSION_ID"
	USAGE_FILE="$STATE_DIR/usage-$SESSION_ID"
fi

percent_x100() {
	# $1: usage(total tokens)  $2: window — USAGE*100/WINDOW(整数%)
	# 常に数値を返す(失敗時 0)
	if [ -n "$1" ] && [ -n "$2" ] && [ "$2" -gt 0 ] 2>/dev/null; then
		echo $(( $1 * 100 / $2 ))
	else
		echo 0
	fi
}

# ==============================================================================
# post_llm: usage を記録するだけ(このイベントでは何も出力しない)
# ==============================================================================
if [ "$EVENT" = "post_llm" ]; then
	# --- F3(review Finding 3): "usage":null 明示検出 + usage オブジェクト内のみ -----
	# (a) "usage":null(プロバイダが usage を報告しない)を明示的に検出して
	#     何も記録しない(要件: 無害 = 空出力)。
	if printf '%s' "$INPUT_ALL" | grep -q '"usage"[[:space:]]*:[[:space:]]*null'; then
		exit 0
	fi
	# (b) usage オブジェクト本体のみを切り出して、その中だけで数値を探す。
	#     usage はフラットなオブジェクト(TokenUsage: 数値/null のみ)なので
	#     {[^}]*} で切れる。JSON 文字列値(response_text / tool_input)内の引用
	#     符は必ず \" にエスケープされるため、未エスケープの "usage" キーに
	#     マッチするのはペイロード直下の本物だけ(vibe 3.1.4 _foreign_hooks.py
	#     _post_llm_payload: usage は最尾のキー)。よって response_text に埋め込
	#     まれた偽の "input_tokens":N / "usage":{...} 表記は全く拾われない。
	USAGE_JSON=$(printf '%s' "$INPUT_ALL" | grep -o '"usage"[[:space:]]*:[[:space:]]*{[^}]*}' | tail -1)
	[ -n "$USAGE_JSON" ] || exit 0
	IN_TOK=$(json_num_last input_tokens "$USAGE_JSON")
	OUT_TOK=$(json_num_last output_tokens "$USAGE_JSON")
	# usage:null または破損 → 何もしない(要件: 無害 = 空出力)
	[ -n "$IN_TOK" ] || exit 0
	[ -n "$OUT_TOK" ] || exit 0
	# 念のため数値検証(巨大すぎる値も除外)+ 先行ゼロ除去(8 進数誤解釈防止)
	case "$IN_TOK" in *[!0-9]*) exit 0 ;; esac
	case "$OUT_TOK" in *[!0-9]*) exit 0 ;; esac
	IN_TOK=$(printf '%s' "$IN_TOK" | sed 's/^0*//')
	OUT_TOK=$(printf '%s' "$OUT_TOK" | sed 's/^0*//')
	: "${IN_TOK:=0}"
	: "${OUT_TOK:=0}"
	[ "$IN_TOK" -lt 1000000000 ] || exit 0
	[ "$OUT_TOK" -lt 1000000000 ] || exit 0

	USAGE=$(( IN_TOK + OUT_TOK ))
	if [ -n "$USAGE_FILE" ]; then
		printf '%s\n' "$USAGE" > "$USAGE_FILE" 2>/dev/null || true
	fi

	# 自動圧縮後など使用量が REARM を下回ったら marker を解除(再発火を許可)
	if [ -n "$MARKER" ] && [ -f "$MARKER" ] && [ -n "$TRANSCRIPT" ]; then
		_win=$(resolve_window "$TRANSCRIPT")
		_pct=$(percent_x100 "$USAGE" "$_win")
		if [ "$_pct" -lt "$REARM_X100" ]; then
			rm -f "$MARKER" 2>/dev/null || true
		fi
	fi
	exit 0
fi

# ==============================================================================
# post_agent: 判定 → ① 司令塔通知 ② deny+reason 注入
# ==============================================================================
if [ "$EVENT" = "post_agent" ]; then
	[ -n "$USAGE_FILE" ] || exit 0
	[ -f "$USAGE_FILE" ] || exit 0
	USAGE=$(cat "$USAGE_FILE" 2>/dev/null || true)
	case "$USAGE" in ''|*[!0-9]*) exit 0 ;; esac
	USAGE=$(printf '%s' "$USAGE" | sed 's/^0*//')
	: "${USAGE:=0}"
	[ -n "$TRANSCRIPT" ] || exit 0

	WINDOW=$(resolve_window "$TRANSCRIPT")
	case "$WINDOW" in ''|*[!0-9]*) WINDOW=262144 ;; esac
	[ "$WINDOW" -gt 0 ] || WINDOW=262144

	PCT=$(percent_x100 "$USAGE" "$WINDOW")

	# marker 済み → 使用量が下がるまで再発火しない
	if [ -f "$MARKER" ]; then
		if [ "$PCT" -lt "$REARM_X100" ]; then
			rm -f "$MARKER" 2>/dev/null || true
		fi
		exit 0
	fi

	# 閾値未満 → 何もしない(空出力)
	[ "$PCT" -ge "$THRESHOLD_X100" ] || exit 0

	# --- 発火: marker 作成 → ① 通知 → ② 注入 --------------------------------
	touch "$MARKER" 2>/dev/null || true

	# ① Orca 司令塔へ通知(best-effort)。フック終了時にプロセスグループごと
	#    kill されるため、perl で setsid して新セッションで実行する。
	#    orca は PATH から、なければ /opt/homebrew/bin / /usr/local/bin から探す。
	ORCA_BIN=""
	if command -v orca >/dev/null 2>&1; then
		ORCA_BIN=orca
	elif [ -x /opt/homebrew/bin/orca ]; then
		ORCA_BIN=/opt/homebrew/bin/orca
	elif [ -x /usr/local/bin/orca ]; then
		ORCA_BIN=/usr/local/bin/orca
	fi
	if [ "$SILENT" != "1" ] && [ -n "$ORCA_BIN" ]; then
		NOTIFY="[context-guard] vibe ワーカーのコンテキスト使用量が ${PCT}% に達しました(session: ${SESSION_ID}, cwd: ${CWD})。このワーカーは ${HANDOFF} を更新して終了報告を行います。準備が整い次第、後任ワーカーの起動(worker-start --retry-of)を検討してください。"
		if command -v perl >/dev/null 2>&1; then
			perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' \
				"$ORCA_BIN" orchestration ask --question "$NOTIFY" >/dev/null 2>&1 &
		fi
	fi

	# ② エージェント自身への指示(pi 版 sendUserMessage(followUp) 相当:
	#    post_agent の deny+reason は reason を retry user message として注入)
	MSG="[context-guard] コンテキスト使用量が ${PCT}% を超えました。作業を続けず、今すぐ次の引き継ぎ処理を行ってください: 1) ${HANDOFF} に現状を整理して保存する(完了したこと+証拠、進行中のこと、残タスク、重要な発見、次の一歩)。2) Orca ワーカーの場合は worker_done で終了報告する(コーディネーターが後任を立てます)。3) それ以外の場合は報告して終了する。追加の作業はしないでください。"
	printf '{"decision":"deny","reason":"%s"}\n' "$MSG"
	exit 0
fi

# その他のイベント / 不明なペイロード → 空出力で終了(無害)
exit 0
