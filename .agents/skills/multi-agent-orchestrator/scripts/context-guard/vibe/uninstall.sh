#!/bin/bash
# context-guard — Vibe CLI hook アンインストーラー
#
# 使い方:
#   ./uninstall.sh global          グローバルから削除(~/.vibe/hooks.toml + ~/.vibe/hooks/)
#   ./uninstall.sh project [DIR]   指定プロジェクト(既定: カレント)から削除
#   ./uninstall.sh all             グローバルとカレントの両方から削除
#
# 他の hook エントリ・コメント・空行構成は保持します。削除するのは:
#   - install.sh が追記した managed ブロック(start/end マーカーで囲まれた部分)
#     **と BLOCK_START 直前の空行 1 行**(install.sh が必ず 1 つ足すもの。
#     これも一緒に除去することで install→uninstall 往復で末尾の空行が
#     蓄積しない。既存内容のうち元からあった空行は 1 バイトも変わらない)
#   - マーカーがない場合(手動書き込みなど)は name = "context-guard..." の
#     [[hooks]] ブロックのみ
#   - 除去後の hooks.toml が実質空(改行/空白のみ)になった場合は、install.sh が
#     新規作成した hooks.toml の残骸なので hooks.toml と .bak-context-guard を
#     削除して完全に元どおりにする
# 編集前のバックアップは <hooks.toml>.bak-context-guard として残します。

set -euo pipefail

VIBE_DIR="${VIBE_HOME:-$HOME/.vibe}"
GLOBAL_HOOKS_TOML="$VIBE_DIR/hooks.toml"
GLOBAL_SCRIPT="$VIBE_DIR/hooks/context-guard.sh"
BLOCK_START='# --- context-guard managed block start (added by install.sh) ---'
BLOCK_END='# --- context-guard managed block end ---'

usage() {
	sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

remove_our_entries() {
	# $1: hooks.toml のパス
	local file="$1"
	if [ ! -f "$file" ]; then
		echo "  $file は存在しません(削除不要)"
		return 0
	fi
	if ! grep -Eq '^[[:space:]]*name[[:space:]]*=[[:space:]]*"context-guard' "$file"; then
		echo "  $file に context-guard エントリはありません"
	else
		cp "$file" "$file.bak-context-guard"
		if grep -Fq "$BLOCK_START" "$file" && grep -Fq "$BLOCK_END" "$file"; then
			# ① managed ブロック(マーカー間)+ BLOCK_START 直前の空行 1 行 を
			#    除去。他の行は 1 バイトも触らない。直前の空行は install.sh が
			#    必ず 1 つ足すものなので 1 行だけ保留(pending)し、BLOCK_START が
			#    来たら破棄、それ以外(ブロック直前が非空行)なら通常どおり出力。
			awk -v start="$BLOCK_START" -v end="$BLOCK_END" '
				BEGIN { inblk = 0; haspend = 0; pend = "" }
				{
					if (inblk) {
						if ($0 == end) inblk = 0
						next
					}
					if ($0 == start) {
						haspend = 0
						inblk = 1
						next
					}
					if ($0 == "") {
						if (haspend) print pend
						pend = $0; haspend = 1
						next
					}
					if (haspend) { print pend; haspend = 0 }
					print $0
				}
				END { if (!inblk && haspend) print pend }
			' "$file" > "$file.tmp-context-guard"
		else
			# ② マーカーがない場合のフォールバック:name = "context-guard..." を
			#    含む [[hooks]] ブロックのみを除去し、他のブロック・行はそのまま。
			awk '
				function flush() { if (n > 0 && ours == 0) for (i = 1; i <= n; i++) print b[i]; n = 0; ours = 0 }
				BEGIN { n = 0; ours = 0 }
				/^[[:space:]]*\[\[hooks\]\]/ { flush(); n = 1; b[1] = $0; next }
				n > 0 && /^[[:space:]]*\[/ { flush(); print; next }
				{
					if (n > 0) {
						b[++n] = $0
						if ($0 ~ /^[[:space:]]*name[[:space:]]*=[[:space:]]*"context-guard/) ours = 1
					} else print
				}
				END { flush() }
			' "$file" > "$file.tmp-context-guard"
		fi
		# 除去後が実質空(改行/空白のみ)なら、install.sh が新規作成した
		# hooks.toml の残骸なのでファイルもバックアップも削除して完全に元どおり。
		# (実質的な TOML 内容が残る場合は絶対に壊さない既存挙動のまま据置)
		if [ ! -s "$file.tmp-context-guard" ] || ! grep -q '[^[:space:]]' "$file.tmp-context-guard" 2>/dev/null; then
			rm -f "$file.tmp-context-guard" "$file" "$file.bak-context-guard"
			echo "  $file は実質空になったため削除しました(残骸の $file.bak-context-guard も削除)"
		elif [ -e "$file.tmp-context-guard" ]; then
			mv "$file.tmp-context-guard" "$file"
			echo "  $file から context-guard の hook エントリを削除しました(バックアップ: $file.bak-context-guard)"
		else
			rm -f "$file.tmp-context-guard"
			echo "  $file からは削除できませんでした(手動で確認してください)" >&2
		fi
	fi
}

remove_script() {
	# $1: スクリプトパス
	local script="$1"
	if [ -f "$script" ]; then
		rm -f "$script"
		echo "  削除: $script"
		rmdir "$(dirname "$script")" 2>/dev/null || true
	else
		echo "  $script は存在しません"
	fi
}

remove_global() {
	echo "グローバルから削除します($VIBE_DIR)"
	remove_our_entries "$GLOBAL_HOOKS_TOML"
	remove_script "$GLOBAL_SCRIPT"
	echo "削除完了(グローバル)"
}

remove_project() {
	local dir="${1:-$PWD}"
	dir="$(cd "$dir" && pwd)"
	echo "プロジェクトから削除します($dir)"
	remove_our_entries "$dir/.vibe/hooks.toml"
	remove_script "$dir/.vibe/hooks/context-guard.sh"
	echo "削除完了(プロジェクト): $dir"
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
