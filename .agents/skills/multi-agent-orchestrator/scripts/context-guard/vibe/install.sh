#!/bin/bash
# context-guard — Vibe CLI (mistral-vibe) hook インストーラー
#
# 使い方:
#   ./install.sh global           すべての Vibe セッション向け(~/.vibe/hooks.toml)
#   ./install.sh project [DIR]    特定プロジェクト(<DIR>/.vibe/hooks.toml、既定: カレント)
#   ./install.sh status           インストール状態を表示
#
# - hooks.toml は TOML(設定は [config.toml とは別ファイル])。既存の hooks.toml は
#   絶対に壊さない:
#     ① 編集前に <hooks.toml>.bak-context-guard バックアップを作成
#     ② 既に context-guard エントリがあれば追記しない(冪等)
#     ③ 追記はテキストレベルの追記(既存の内容には 1 バイトも触れない)
# - hooks.toml の name はファイル内だけでなく global/project 間でも一意である
#   必要があります(Vibe の load_hooks_from_fs は全 hooks.toml を横断して
#   重複チェックし、Duplicate hook name の後読みを config issue で skip
#   します)。そのため scope ごとに name を分けます:
#     global : "context-guard-global-post-llm" / "context-guard-global-post-agent"
#     project: "context-guard-project-post-llm" / "context-guard-project-post-agent"
#   marker/usage 状態ファイルはスコープに依らずセッション単位で共用なので、
#   両方に install しても post_agent の発火は marker により 1 回のまま無害です。
#   (両方とも単一スクリプト context-guard.sh を type 分岐で使う)
# - プロジェクト設定はそのフォルダを信頼(trust)した後にのみ有効になります。
#   未 trust のフォルダの .vibe/hooks.toml は Vibe に読み込まれません
#   (1 回だけなら `vibe --trust` 、恒常的なら trust を選択してください)。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/context-guard.sh"
VIBE_DIR="${VIBE_HOME:-$HOME/.vibe}"
GLOBAL_HOOKS_TOML="$VIBE_DIR/hooks.toml"
GLOBAL_SCRIPT="$VIBE_DIR/hooks/context-guard.sh"
HOOK_TIMEOUT=30.0
BLOCK_START='# --- context-guard managed block start (added by install.sh) ---'
BLOCK_END='# --- context-guard managed block end ---'

usage() {
	sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

# hooks.toml 内に context-guard のエントリ(name = "context-guard...")があるか
has_our_entries() {
	grep -Eq '^[[:space:]]*name[[:space:]]*=[[:space:]]*"context-guard' "$1" 2>/dev/null
}

append_block() {
	# $1: hooks.toml のパス, $2: hook スクリプトの絶対パス, $3: scope(global|project)
	# name は global/project 横断で一意である必要があるため scope 接尾辞を付ける
	# (F2: Duplicate hook name の Warning を防ぐ)。marker/usage ファイルは
	# スクリプト側でセッション単位に共用されるため両スコープ併存時も発火は 1 回。
	local file="$1" script="$2" scope="$3"
	[ -n "$scope" ] || scope="project"
	if [ ! -f "$file" ]; then
		touch "$file"
	else
		cp "$file" "$file.bak-context-guard"
	fi
	# 既に末尾が改行で終わるようにする(テキストレベル追記のため)
	if [ -s "$file" ] && [ "$(tail -c 1 "$file" | od -An -tx1 | tr -d ' \n')" != "0a" ]; then
		printf '\n' >> "$file"
	fi
	{
		printf '\n%s\n\n' "$BLOCK_START"
		printf '[[hooks]]\n'
		printf 'name = "context-guard-%s-post-llm"\n' "$scope"
		printf 'type = "post_llm"\n'
		printf 'command = "'"'"'%s'"'"'"\n' "$script"
		printf 'timeout = %s\n' "$HOOK_TIMEOUT"
		printf 'description = "context-guard: コンテキスト使用量をセッション状態ファイルに記録"\n'
		printf '\n'
		printf '[[hooks]]\n'
		printf 'name = "context-guard-%s-post-agent"\n' "$scope"
		printf 'type = "post_agent"\n'
		printf 'command = "'"'"'%s'"'"'"\n' "$script"
		printf 'timeout = %s\n' "$HOOK_TIMEOUT"
		printf 'description = "context-guard: 閾値超過時に HANDOFF 引き継ぎ指示を注入・司令塔へ通知"\n'
		printf '\n'
		printf '%s\n' "$BLOCK_END"
	} >> "$file"
	echo "  $file に context-guard の hook エントリ(2 件, scope: $scope)を追加しました"
}

install_to() {
	# $1: hooks.toml のパス, $2: hook スクリプトの配置先絶対パス, $3: 表示名, $4: scope
	local hooks="$1" script="$2" label="$3" scope="$4"
	[ -f "$SRC" ] || { echo "エラー: $SRC が見つかりません" >&2; exit 1; }
	case "$script" in
		*'"'*|*'\'*) echo "エラー: スクリプトパスに \" または \\ を含められません: $script" >&2; exit 1 ;;
	esac
	mkdir -p "$(dirname "$script")"
	cp "$SRC" "$script"
	chmod 755 "$script"
	echo "スクリプト配置: $script"
	if has_our_entries "$hooks"; then
		echo "  $hooks には既に context-guard エントリがあります(重複追記はせず既存内容を保持)"
		echo "  実行コマンドのパスが変わった場合は uninstall → install をやり直してください"
	else
		append_block "$hooks" "$script" "$scope"
	fi
	echo "インストール完了($label)"
	if [ "$label" = "プロジェクト" ]; then
		echo "  → このフォルダを信頼(trust)した後にのみ有効になります(vibe --trust)"
	fi
	echo "  → 使用量閾値は VIBE_CONTEXT_GUARD_THRESHOLD(既定 0.8)で調整できます"
}

show_status() {
	local dir="${1:-$PWD}"
	dir="$(cd "$dir" 2>/dev/null && pwd)" || dir="$1"
	echo "== context-guard (Vibe hook) インストール状態 =="
	if [ -f "$GLOBAL_SCRIPT" ] && has_our_entries "$GLOBAL_HOOKS_TOML"; then
		echo "  グローバル  : 登録済み ($GLOBAL_SCRIPT)"
	elif [ -f "$GLOBAL_SCRIPT" ]; then
		echo "  グローバル  : スクリプトのみ存在(hooks.toml に未登録)"
	elif has_our_entries "$GLOBAL_HOOKS_TOML"; then
		echo "  グローバル  : 登録済み・スクリプト不明(hooks.toml の command を確認) ($VIBE_DIR)"
	else
		echo "  グローバル  : 未インストール ($VIBE_DIR)"
	fi
	local phooks="$dir/.vibe/hooks.toml" pscript="$dir/.vibe/hooks/context-guard.sh"
	if [ -f "$pscript" ] && has_our_entries "$phooks"; then
		echo "  プロジェクト: 登録済み ($pscript)"
	elif [ -f "$pscript" ]; then
		echo "  プロジェクト: スクリプトのみ存在(hooks.toml に未登録) ($dir)"
	elif [ -f "$phooks" ] && has_our_entries "$phooks"; then
		echo "  プロジェクト: 登録済み・スクリプト不明(hooks.toml の command を確認) ($dir)"
	else
		echo "  プロジェクト: 未インストール ($dir)"
	fi
}

[ $# -ge 1 ] || usage

case "$1" in
	global)
		install_to "$GLOBAL_HOOKS_TOML" "$GLOBAL_SCRIPT" "グローバル" "global"
		echo "  → すべての Vibe セッション(main/subagent)で有効になります"
		;;
	project)
		dir="${2:-$PWD}"
		dir="$(cd "$dir" && pwd)"
		install_to "$dir/.vibe/hooks.toml" "$dir/.vibe/hooks/context-guard.sh" "プロジェクト" "project"
		;;
	status)
		show_status "${2:-}"
		;;
	*)
		usage
		;;
esac
