#!/bin/bash
# context-guard — pi extension アンインストーラー
#
# 使い方:
#   ./uninstall.sh global          グローバルから削除(~/.pi/agent/extensions/context-guard/)
#   ./uninstall.sh project [DIR]   指定プロジェクト(既定: カレント)から削除
#   ./uninstall.sh all             グローバルとカレントプロジェクトの両方から削除

set -euo pipefail

GLOBAL_DIR="$HOME/.pi/agent/extensions/context-guard"
EXT_NAME="context-guard"

usage() {
	sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

remove_global() {
	if [ -d "$GLOBAL_DIR" ]; then
		rm -rf "$GLOBAL_DIR"
		echo "削除完了(グローバル): $GLOBAL_DIR"
	else
		echo "グローバルにはインストールされていません"
	fi
}

remove_project() {
	local dir="${1:-$PWD}"
	dir="$(cd "$dir" && pwd)"
	local target="$dir/.pi/extensions/$EXT_NAME"
	if [ -d "$target" ]; then
		rm -rf "$target"
		echo "削除完了(プロジェクト): $target"
	else
		echo "このプロジェクトにはインストールされていません: $dir"
	fi
}

[ $# -ge 1 ] || usage

case "$1" in
	global)
		remove_global
		;;
	project)
		remove_project "${2:-}"
		;;
	all)
		remove_global
		remove_project "$PWD"
		;;
	*)
		usage
		;;
esac
