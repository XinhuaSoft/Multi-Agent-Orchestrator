#!/bin/bash
# context-guard — Antigravity hook アンインストーラー
#
# 使い方:
#   ./uninstall.sh global          グローバルから削除(~/.gemini/config/)
#   ./uninstall.sh project [DIR]   指定ワークスペース(既定: カレント)から削除
#   ./uninstall.sh all             グローバルとカレントの両方から削除
#
# 既存の他の hook(例: Orca の orca-status)には触れません。

set -euo pipefail

KEY="context-guard"
GLOBAL_DIR="$HOME/.gemini/config"

usage() {
	sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

json_tool() {
	if command -v python3 >/dev/null 2>&1; then
		echo python3
	elif command -v node >/dev/null 2>&1; then
		echo node
	else
		echo ""
	fi
}

remove_global() {
	local hooks="$GLOBAL_DIR/hooks.json"
	local tool
	tool="$(json_tool)"
	if [ -f "$hooks" ] && [ -n "$tool" ]; then
		if [ "$tool" = python3 ]; then
			HOOK_KEY="$KEY" python3 - "$hooks" <<'PYEOF'
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
}' "$hooks"
		fi
	else
		echo "  $hooks は存在しないか、編集ツールがありません"
	fi
	if [ -d "$GLOBAL_DIR/$KEY" ]; then
		rm -rf "$GLOBAL_DIR/$KEY"
		echo "  削除: $GLOBAL_DIR/$KEY"
	fi
	echo "削除完了(グローバル)"
}

remove_project() {
	local dir="${1:-$PWD}"
	dir="$(cd "$dir" && pwd)"
	local hooks="$dir/.agents/hooks.json"
	local tool
	tool="$(json_tool)"
	if [ -f "$hooks" ] && [ -n "$tool" ]; then
		if [ "$tool" = python3 ]; then
			HOOK_KEY="$KEY" python3 - "$hooks" <<'PYEOF'
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
}' "$hooks"
		fi
	else
		echo "  $hooks は存在しないか、編集ツールがありません"
	fi
	if [ -f "$dir/.agents/$KEY.sh" ]; then
		rm -f "$dir/.agents/$KEY.sh"
		echo "  削除: $dir/.agents/$KEY.sh"
	fi
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
