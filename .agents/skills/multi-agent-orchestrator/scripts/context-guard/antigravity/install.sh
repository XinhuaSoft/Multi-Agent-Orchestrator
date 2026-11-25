#!/bin/bash
# context-guard — Antigravity hook インストーラー
#
# 使い方:
#   ./install.sh global            全ワークスペース向けにインストール(~/.gemini/config/)
#   ./install.sh project [DIR]     指定ワークスペース(既定: カレント)にインストール(<DIR>/.agents/)
#   ./install.sh status            インストール状態を表示
#
# グローバル: ~/.gemini/config/hooks.json に "context-guard" キーを追加(MERGE、既存キーは保持)
#             スクリプトは ~/.gemini/config/context-guard/context-guard.sh にコピー
# プロジェクト: <DIR>/.agents/hooks.json に追加、スクリプトは <DIR>/.agents/context-guard.sh
#
# 注意: 既存の hooks.json(例: Orca の orca-status)は壊しません。
#       JSON 編集には python3 または node を使用します。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/context-guard.sh"
KEY="context-guard"
GLOBAL_DIR="$HOME/.gemini/config"

usage() {
	sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

# --- JSON 編集ヘルパー: python3 または node を使う -----------------------------

json_tool() {
	if command -v python3 >/dev/null 2>&1; then
		echo python3
	elif command -v node >/dev/null 2>&1; then
		echo node
	else
		echo ""
	fi
}

merge_hook_entry() {
	# $1: hooks.json のパス, $2: hook スクリプトの絶対パス
	local file="$1" script="$2" tool
	tool="$(json_tool)"
	if [ -z "$tool" ]; then
		echo "エラー: python3 または node が必要です(JSON のマージに使用)" >&2
		exit 1
	fi

	mkdir -p "$(dirname "$file")"
	[ -f "$file" ] || printf '{}\n' > "$file"
	cp "$file" "$file.bak-context-guard"

	if [ "$tool" = python3 ]; then
		HOOK_KEY="$KEY" SCRIPT_PATH="$script" python3 - "$file" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
data[os.environ["HOOK_KEY"]] = {
    "PreInvocation": [
        {
            "type": "command",
            "command": os.environ["SCRIPT_PATH"],
            "timeout": 30
        }
    ]
}
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f'  {path} に "{os.environ["HOOK_KEY"]}" を追加しました')
PYEOF
	else
		HOOK_KEY="$KEY" SCRIPT_PATH="$script" node -e '
const fs = require("fs");
const path = process.argv[1];
const data = JSON.parse(fs.readFileSync(path, "utf8"));
data[process.env.HOOK_KEY] = {
  PreInvocation: [
    { type: "command", command: process.env.SCRIPT_PATH, timeout: 30 }
  ]
};
fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
console.log(`  ${path} に "${process.env.HOOK_KEY}" を追加しました`);
' "$file"
	fi
}

remove_hook_entry() {
	local file="$1" tool
	tool="$(json_tool)"
	if [ ! -f "$file" ]; then
		echo "  $file は存在しません(削除不要)"
		return 0
	fi
	if [ -z "$tool" ]; then
		echo "エラー: python3 または node が必要です" >&2
		exit 1
	fi
	if [ "$tool" = python3 ]; then
		HOOK_KEY="$KEY" python3 - "$file" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
if os.environ["HOOK_KEY"] in data:
    del data[os.environ["HOOK_KEY"]]
    with open(path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f'  {path} から "{os.environ["HOOK_KEY"]}" を削除しました')
else:
    print(f'  {path} に "{os.environ["HOOK_KEY"]}" はありません')
PYEOF
	else
		HOOK_KEY="$KEY" node -e '
const fs = require("fs");
const path = process.argv[1];
const data = JSON.parse(fs.readFileSync(path, "utf8"));
if (data[process.env.HOOK_KEY]) {
  delete data[process.env.HOOK_KEY];
  fs.writeFileSync(path, JSON.stringify(data, null, 2) + "\n");
  console.log(`  ${path} から "${process.env.HOOK_KEY}" を削除しました`);
} else {
  console.log(`  ${path} に "${process.env.HOOK_KEY}" はありません`);
}' "$file"
	fi
}

install_global() {
	[ -f "$SRC" ] || { echo "エラー: $SRC が見つかりません" >&2; exit 1; }
	local script_dir="$GLOBAL_DIR/$KEY"
	local script_path="$script_dir/context-guard.sh"
	mkdir -p "$script_dir"
	cp "$SRC" "$script_path"
	chmod +x "$script_path"
	echo "スクリプト配置: $script_path"
	merge_hook_entry "$GLOBAL_DIR/hooks.json" "$script_path"
	echo "インストール完了(グローバル)"
	echo "  → すべての Antigravity セッション(App / CLI / IDE)で有効になります"
	echo "  → 設定 > Customizations > Hooks で確認・無効化できます"
}

install_project() {
	local dir="${1:-$PWD}"
	dir="$(cd "$dir" && pwd)"
	[ -f "$SRC" ] || { echo "エラー: $SRC が見つかりません" >&2; exit 1; }
	local agents_dir="$dir/.agents"
	local script_path="$agents_dir/$KEY.sh"
	mkdir -p "$agents_dir"
	cp "$SRC" "$script_path"
	chmod +x "$script_path"
	echo "スクリプト配置: $script_path"
	merge_hook_entry "$agents_dir/hooks.json" "$script_path"
	echo "インストール完了(プロジェクト): $dir"
	echo "  → このワークスペースを信頼(trust)すると有効になります"
}

show_status() {
	echo "== context-guard (Antigravity hook) インストール状態 =="
	local dir="${1:-$PWD}"
	if [ -f "$GLOBAL_DIR/$KEY/context-guard.sh" ] && grep -q "\"$KEY\"" "$GLOBAL_DIR/hooks.json" 2>/dev/null; then
		echo "  グローバル  : インストール済み ($GLOBAL_DIR/$KEY/context-guard.sh)"
	elif [ -f "$GLOBAL_DIR/$KEY/context-guard.sh" ]; then
		echo "  グローバル  : スクリプトのみ存在(hooks.json に未登録)"
	else
		echo "  グローバル  : 未インストール"
	fi
	if [ -f "$dir/.agents/$KEY.sh" ] && grep -q "\"$KEY\"" "$dir/.agents/hooks.json" 2>/dev/null; then
		echo "  プロジェクト: インストール済み ($dir/.agents/$KEY.sh)"
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
