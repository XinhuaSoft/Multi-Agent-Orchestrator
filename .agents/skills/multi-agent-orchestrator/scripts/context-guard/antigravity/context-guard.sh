#!/bin/sh
# context-guard — Antigravity hook script
#
# Antigravity の PreInvocation フックから呼ばれ、transcript.jsonl の
# トークン記録からコンテキスト使用量を計算し、閾値(既定 80%)を超えていたら:
#   1. Orca のコーディネーター(司令塔)に通知(best-effort)
#   2. injectSteps でエージェント自身に HANDOFF.md 更新と終了処理を指示
#
# 入力(stdin): Antigravity フックの共通 JSON
#   { "conversationId": "...", "transcriptPath": "...", "modelName": "...", ... }
# 出力(stdout): JSON
#   閾値未満 / 二重発火防止中: {}
#   閾値超過: { "injectSteps": [ { "userMessage": "..." } ] }
#
# 環境変数:
#   AGY_CONTEXT_GUARD_THRESHOLD  発火閾値 0.0〜1.0(既定 0.8)
#   AGY_CONTEXT_GUARD_WINDOW     コンテキストウィンドウサイズ(トークン数)。
#                                未設定時は modelName から推定(既定 1048576)
#   AGY_CONTEXT_GUARD_HANDOFF    HANDOFF ファイル名(既定 HANDOFF.md)
#   AGY_CONTEXT_GUARD_SILENT     "1" でコーディネーター通知を止める
#   AGY_CONTEXT_GUARD_REARM      使用量がこの比率を下回ったら再発火許可(既定 0.5)

set -u

THRESHOLD="${AGY_CONTEXT_GUARD_THRESHOLD:-0.8}"
HANDOFF_FILE="${AGY_CONTEXT_GUARD_HANDOFF:-HANDOFF.md}"
REARM="${AGY_CONTEXT_GUARD_REARM:-0.5}"
SILENT="${AGY_CONTEXT_GUARD_SILENT:-0}"

# --- stdin の JSON から必要なフィールドを取り出す -----------------------------
INPUT=$(cat 2>/dev/null || true)

json_str() {
	# $1: field name — "key":"value" の value を素朴に抽出(エスケープ無視)
	printf '%s' "$INPUT" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
		| sed "s/\"$1\"[[:space:]]*:[[:space:]]*\"//; s/\"$//"
}

TRANSCRIPT=$(json_str transcriptPath)
CONV_ID=$(json_str conversationId)
MODEL=$(json_str modelName)

# 出力は必ず有効な JSON で終わるようにする
emit() { printf '%s\n' "$1"; exit 0; }

[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || emit '{}'

# --- コンテキストウィンドウサイズの決定 ---------------------------------------
window_for_model() {
	case "$1" in
		*pro*) echo 1048576 ;;
		*flash*) echo 1048576 ;;
		*) echo "${AGY_CONTEXT_GUARD_WINDOW:-1048576}" ;;
	esac
}

WINDOW="${AGY_CONTEXT_GUARD_WINDOW:-$(window_for_model "$MODEL")}"
case "$WINDOW" in ''|*[!0-9]*) WINDOW=1048576 ;; esac

# --- 使用量の計算: トークン記録のある最後の行を使う ----------------------------
LAST=$(grep '"input_tokens"' "$TRANSCRIPT" 2>/dev/null | tail -1)
[ -n "$LAST" ] || emit '{}'

INPUT_TOKENS=$(printf '%s' "$LAST" | grep -o '"input_tokens":[0-9]*' | head -1 | grep -o '[0-9]*$')
CACHE_TOKENS=$(printf '%s' "$LAST" | grep -o '"cache_read_tokens":[0-9]*' | head -1 | grep -o '[0-9]*$')
INPUT_TOKENS="${INPUT_TOKENS:-0}"
CACHE_TOKENS="${CACHE_TOKENS:-0}"
USAGE=$((INPUT_TOKENS + CACHE_TOKENS))

# 整数演算で比率を計算(USAGE*100 / WINDOW >= THRESHOLD*100)
PERCENT_X100=$((USAGE * 100 / WINDOW))
THRESHOLD_X100=$(awk -v t="$THRESHOLD" 'BEGIN { printf "%d", t * 100 }')
REARM_X100=$(awk -v t="$REARM" 'BEGIN { printf "%d", t * 100 }')

# --- 二重発火防止マーカー ------------------------------------------------------
MARKER="$(dirname "$TRANSCRIPT" 2>/dev/null)/.context-guard-fired"
[ -n "$CONV_ID" ] && MARKER="$(dirname "$TRANSCRIPT")/.context-guard-fired-$CONV_ID"

if [ -f "$MARKER" ]; then
	# 圧縮などで使用量が下がったら再発火を許可する
	if [ "$PERCENT_X100" -lt "$REARM_X100" ]; then
		rm -f "$MARKER" 2>/dev/null
	else
		emit '{}'
	fi
fi

[ "$PERCENT_X100" -ge "$THRESHOLD_X100" ] || emit '{}'

# --- 発火: マーカー作成 + コーディネーター通知 + エージェントへの指示 ---------
touch "$MARKER" 2>/dev/null || true

if [ "$SILENT" != "1" ] && command -v orca >/dev/null 2>&1; then
	(
		orca orchestration ask --question \
			"[context-guard] Antigravity ワーカーのコンテキスト使用量が ${PERCENT_X100}% に達しました(モデル: ${MODEL:-unknown})。このワーカーは HANDOFF.md を更新して終了報告を行います。準備が整い次第、後任ワーカーの起動(worker-start --retry-of)を検討してください。" \
			>/dev/null 2>&1
	) &
fi

MSG="[context-guard] コンテキスト使用量が ${PERCENT_X100}% を超えました。作業を続けず、今すぐ次の引き継ぎ処理を行ってください: 1) ${HANDOFF_FILE} に現状を整理して保存する(完了したこと+証拠、進行中のこと、残タスク、重要な発見、次の一歩)。2) Orca ワーカーの場合は worker_done で終了報告する(コーディネーターが後任を立てます)。3) それ以外の場合は報告して終了する。追加の作業はしないでください。"

# PreInvocation の出力契約: injectSteps でエージェントに指示を届ける
# (userMessage はユーザーからのメッセージとして会話に注入される)
emit "{\"injectSteps\": [{\"userMessage\": \"${MSG}\"}]}"
