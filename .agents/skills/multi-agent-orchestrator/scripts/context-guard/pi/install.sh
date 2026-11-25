#!/bin/bash
# context-guard — pi extension インストーラー
#
# 使い方:
#   ./install.sh global            全プロジェクト向けにインストール(~/.pi/agent/extensions/)
#   ./install.sh project [DIR]     指定プロジェクト(既定: カレント)にインストール(<DIR>/.pi/extensions/)
#   ./install.sh status            インストール状態を表示
#
# アンインストールは ./uninstall.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/context-guard/index.ts"
GLOBAL_DIR="$HOME/.pi/agent/extensions/context-guard"
EXT_NAME="context-guard"

usage() {
	sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

json_merge() {
	# settings.json への追記は不要(自動検出)。予約用のダミー関数なし
	:
}

install_global() {
	[ -f "$SRC" ] || { echo "エラー: $SRC が見つかりません" >&2; exit 1; }
	mkdir -p "$GLOBAL_DIR"
	cp "$SRC" "$GLOBAL_DIR/index.ts"
	echo "インストール完了(グローバル): $GLOBAL_DIR/index.ts"
	echo "  → すべての pi セッションで自動読み込みされます"
	echo "  → プロジェクトごとに無効化する場合は settings.json の extensions で -context-guard を指定してください"
}

install_project() {
	local dir="${1:-$PWD}"
	dir="$(cd "$dir" && pwd)"
	[ -f "$SRC" ] || { echo "エラー: $SRC が見つかりません" >&2; exit 1; }
	mkdir -p "$dir/.pi/extensions/context-guard"
	cp "$SRC" "$dir/.pi/extensions/context-guard/index.ts"
	echo "インストール完了(プロジェクト): $dir/.pi/extensions/context-guard/index.ts"
	echo "  → このプロジェクトで pi を初回起動する際、拡張機能の信頼(trust)を求められたら許可してください"
}

show_status() {
	echo "== context-guard (pi extension) インストール状態 =="
	if [ -f "$GLOBAL_DIR/index.ts" ]; then
		echo "  グローバル  : インストール済み ($GLOBAL_DIR/index.ts)"
	else
		echo "  グローバル  : 未インストール"
	fi
	local dir="${1:-$PWD}"
	if [ -f "$dir/.pi/extensions/context-guard/index.ts" ]; then
		echo "  プロジェクト: インストール済み ($dir/.pi/extensions/context-guard/index.ts)"
	else
		echo "  プロジェクト: 未インストール ($dir)"
	fi
}

[ $# -ge 1 ] || usage

case "$1" in
	global)
		install_global
		;;
	project)
		install_project "${2:-}"
		;;
	status)
		show_status "${2:-$PWD}"
		;;
	*)
		usage
		;;
esac
