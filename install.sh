#!/bin/sh
# agent-beacon 安裝程式。可以重複執行（重跑 = 修復）。
#
#   curl -fsSL https://raw.githubusercontent.com/ddd-dong/agent-beacon/main/install.sh | sh -s -- --token <機器 token>
#
# 選項：
#   --token T        這台機器的 token（安裝時必填）
#   --url URL        儀表板位址（預設見 DEFAULT_URL）
#   --cacert FILE    用這個 CA 憑證驗證儀表板（自簽憑證時用）
#   --cacert-b64 B   同上，但直接給 base64 編碼的憑證內容（儀表板產生的安裝指令用這個）
#   --insecure       不驗證儀表板憑證（不建議，只在暫時沒有正式憑證時用）
#   --uninstall      移除 plugin、Codex 設定與本機設定
set -eu

REPO="${AGENT_BEACON_REPO:-ddd-dong/agent-beacon}"
REF="${AGENT_BEACON_REF:-main}"
DEFAULT_URL="https://173.249.194.251"
MARKET="agent-beacon"
PLUGIN="agent-beacon@agent-beacon"

CONF_DIR="$HOME/.config/agent-beacon"
SHARE_DIR="$HOME/.local/share/agent-beacon"
BEACON="$SHARE_DIR/beacon"
CODEX_CONF="${CODEX_HOME:-$HOME/.codex}/config.toml"

token="" url="$DEFAULT_URL" cacert="" cacert_b64="" insecure=0 uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --token) token="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    --cacert) cacert="$2"; shift 2 ;;
    --cacert-b64) cacert_b64="$2"; shift 2 ;;
    --insecure) insecure=1; shift ;;
    --uninstall) uninstall=1; shift ;;
    *) echo "未知選項：$1" >&2; exit 2 ;;
  esac
done

say() { printf '[agent-beacon] %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- Codex：notify 只認檔案開頭（第一個 [table] 之前）的 notify = [...] ----------

codex_notify_line() {
  [ -f "$CODEX_CONF" ] || return 0
  awk '/^[[:space:]]*\[/ { exit } /^[[:space:]]*notify[[:space:]]*=/ { print; exit }' "$CODEX_CONF"
}

codex_remove_notify() {
  awk 'BEGIN { t = 0 } /^[[:space:]]*\[/ { t = 1 } t || !/^[[:space:]]*notify[[:space:]]*=/' "$CODEX_CONF" > "$CODEX_CONF.tmp"
  mv "$CODEX_CONF.tmp" "$CODEX_CONF"
}

codex_install() {
  if ! have codex && [ ! -d "$(dirname "$CODEX_CONF")" ]; then
    say "沒有 Codex，略過"
    return 0
  fi
  mkdir -p "$(dirname "$CODEX_CONF")"
  touch "$CODEX_CONF"
  line="$(codex_notify_line)"
  ours="notify = [\"$BEACON\", \"codex\"]"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # Windows：Codex 不能直接執行 sh 腳本，改由 Git Bash 的 bash.exe 執行（路徑用正斜線）
      ours="notify = [\"$(cygpath -m /usr/bin/bash)\", \"$(cygpath -m "$BEACON")\", \"codex\"]" ;;
  esac
  case "$line" in
    *agent-beacon*)
      say "Codex notify 已指向 beacon"
      return 0 ;;
    "") ;;
    *\]*)
      # 已有 notify：保留原指令（一行一個參數），beacon 會串接執行
      cp "$CODEX_CONF" "$CODEX_CONF.agent-beacon.bak"
      printf '%s\n' "$line" > "$CONF_DIR/codex-notify-orig.line"
      printf '%s\n' "$line" | sed 's/^[^[]*\[//; s/\][^]]*$//' \
        | grep -oE "\"[^\"]*\"|'[^']*'" | sed "s/^[\"']//; s/[\"']\$//" > "$CONF_DIR/codex-notify-orig"
      codex_remove_notify
      say "已保留原本的 Codex notify，會串接執行" ;;
    *)
      say "Codex 的 notify 是多行陣列，無法自動處理；請手動把它改成：$ours"
      return 0 ;;
  esac
  { printf '%s\n' "$ours"; cat "$CODEX_CONF"; } > "$CODEX_CONF.tmp" && mv "$CODEX_CONF.tmp" "$CODEX_CONF"
  say "Codex notify 已設定"
}

codex_uninstall() {
  [ -f "$CODEX_CONF" ] || return 0
  case "$(codex_notify_line)" in
    *agent-beacon*) codex_remove_notify ;;
    *) return 0 ;;
  esac
  if [ -s "$CONF_DIR/codex-notify-orig.line" ]; then
    { cat "$CONF_DIR/codex-notify-orig.line"; cat "$CODEX_CONF"; } > "$CODEX_CONF.tmp" && mv "$CODEX_CONF.tmp" "$CODEX_CONF"
    say "已還原原本的 Codex notify"
  else
    say "已移除 Codex notify"
  fi
}

# ---------- Claude Code plugin ----------

claude_settings_autoupdate() {
  settings="$HOME/.claude/settings.json"
  [ -f "$settings" ] || return 0
  # Windows 的 python3 常是開 Microsoft Store 的空殼：先確認真的能跑
  if have python3 && python3 -c "" >/dev/null 2>&1; then
    python3 - "$settings" "$MARKET" <<'PY' || { say "開啟 auto-update 失敗，請在 Claude Code 裡用 /plugin → Marketplaces 開啟"; return 0; }
import json, sys
path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
entry = data.setdefault("extraKnownMarketplaces", {}).get(name)
if entry is not None and entry.get("autoUpdate") is not True:
    entry["autoUpdate"] = True
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
PY
  elif have jq; then
    tmp="$(mktemp)"
    jq --arg n "$MARKET" 'if .extraKnownMarketplaces[$n] then .extraKnownMarketplaces[$n].autoUpdate = true else . end' \
      "$settings" > "$tmp" && mv "$tmp" "$settings"
  elif have powershell.exe && have cygpath; then
    cp "$settings" "$settings.agent-beacon.bak"
    ps1="$SHARE_DIR/set-autoupdate.ps1"
    cat > "$ps1" <<'PS'
param([string]$Path, [string]$Name)
$j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
$m = $j.extraKnownMarketplaces.$Name
if ($null -eq $m) { exit 0 }
$m | Add-Member -NotePropertyName autoUpdate -NotePropertyValue $true -Force
$out = $j | ConvertTo-Json -Depth 100
$null = $out | ConvertFrom-Json   # 寫回前確認是合法 JSON
[IO.File]::WriteAllText($Path, $out)   # UTF-8 無 BOM
PS
    if ! powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$ps1")" \
        "$(cygpath -w "$settings")" "$MARKET" >/dev/null 2>&1; then
      mv "$settings.agent-beacon.bak" "$settings"
      say "開啟 auto-update 失敗（已還原 settings.json），請在 Claude Code 裡用 /plugin → Marketplaces 開啟"
      return 0
    fi
    rm -f "$ps1"
  else
    say "沒有 python3 或 jq，請在 Claude Code 裡用 /plugin → Marketplaces → agent-beacon 開啟 auto-update"
    return 0
  fi
  say "已開啟 auto-update"
}

claude_install() {
  if ! have claude; then
    say "沒有 Claude Code，略過"
    return 0
  fi
  if claude plugin marketplace list 2>/dev/null | grep -q "$MARKET"; then
    claude plugin marketplace update "$MARKET" >/dev/null 2>&1 || true
  else
    claude plugin marketplace add "$REPO" --scope user
  fi
  if claude plugin list 2>/dev/null | grep -q "$PLUGIN"; then
    # 重跑 = 修復：已安裝就更新到最新版
    claude plugin update "$PLUGIN" --scope user 2>&1 | tail -n 1
  else
    claude plugin install "$PLUGIN" --scope user -y
  fi
  claude_settings_autoupdate
}

claude_uninstall() {
  have claude || return 0
  claude plugin marketplace remove "$MARKET" >/dev/null 2>&1 && say "已移除 Claude Code plugin" || true
}

# ---------- main ----------

if [ "$uninstall" = 1 ]; then
  claude_uninstall
  codex_uninstall
  rm -rf "$CONF_DIR" "$SHARE_DIR"
  say "已移除"
  exit 0
fi

[ -n "$token" ] || { echo "需要 --token" >&2; exit 2; }
have curl || { echo "需要 curl" >&2; exit 1; }

umask 077
mkdir -p "$CONF_DIR" "$SHARE_DIR"

# Windows（Git for Windows）的 curl 用 Schannel：自簽 CA 沒有撤銷清單可查，會被當成驗證失敗。
# 憑證本身仍用 --cacert 驗證，只是不查撤銷狀態。
curl_extra=""
curl -V 2>/dev/null | grep -qi schannel && curl_extra="--ssl-no-revoke"

# Codex 用的 beacon 固定放在這裡（Claude Code 用 plugin 自己的那份）
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -f "$here/plugins/agent-beacon/bin/beacon" ]; then
  cp "$here/plugins/agent-beacon/bin/beacon" "$BEACON.tmp"
else
  curl -fsSL "https://raw.githubusercontent.com/$REPO/$REF/plugins/agent-beacon/bin/beacon" -o "$BEACON.tmp"
fi
chmod 755 "$BEACON.tmp" && mv "$BEACON.tmp" "$BEACON"

if [ -n "$cacert_b64" ]; then
  # GNU 用 -d，舊版 macOS 用 -D
  printf '%s' "$cacert_b64" | base64 -d > "$CONF_DIR/ca.crt" 2>/dev/null \
    || printf '%s' "$cacert_b64" | base64 -D > "$CONF_DIR/ca.crt"
  grep -q "BEGIN CERTIFICATE" "$CONF_DIR/ca.crt" || { echo "--cacert-b64 不是有效的憑證" >&2; exit 2; }
  cacert="$CONF_DIR/ca.crt"
elif [ -n "$cacert" ]; then
  cp "$cacert" "$CONF_DIR/ca.crt"
  cacert="$CONF_DIR/ca.crt"
fi
{
  printf 'BEACON_URL=%s\n' "$url"
  printf 'BEACON_TOKEN=%s\n' "$token"
  [ -n "$cacert" ] && printf 'BEACON_CACERT=%s\n' "$cacert"
  [ "$insecure" = 1 ] && printf 'BEACON_INSECURE=1\n'
  [ -n "$curl_extra" ] && printf 'BEACON_CURL_EXTRA=%s\n' "$curl_extra"
} > "$CONF_DIR/env"
chmod 600 "$CONF_DIR/env"
say "設定寫入 $CONF_DIR/env"

# 先確認連得上、token 有效（送一筆測試事件不影響狀態：未知事件只更新時間）
set -- -sS -o /dev/null -w '%{http_code}' -m 5
[ -n "$cacert" ] && set -- "$@" --cacert "$cacert"
[ "$insecure" = 1 ] && set -- "$@" -k
[ -n "$curl_extra" ] && set -- "$@" $curl_extra
code="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -K - "$@" -X POST \
  -H 'Content-Type: application/json' \
  --data "{\"event\":\"InstallCheck\",\"session_id\":\"install-check\",\"agent\":\"install\"}" \
  "${url%/}/api/agent/events" || true)"
case "$code" in
  204) say "儀表板連線正常" ;;
  401) say "token 無效（401），中止安裝"; exit 1 ;;
  *) say "警告：連不到儀表板（$code），之後的事件會靜默丟棄" ;;
esac

claude_install
codex_install
say "完成"
