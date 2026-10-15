# agent-beacon

把 Claude Code 與 Codex 的 session 狀態轉發到個人儀表板。客戶端只轉發事件，狀態判斷全在儀表板後端。

## 安裝

```sh
curl -fsSL https://raw.githubusercontent.com/ddd-dong/agent-beacon/main/install.sh | sh -s -- --token <機器 token>
```

儀表板用自簽憑證時，加上 `--cacert <儀表板的 root.crt>`（或暫時用 `--insecure`）。

重跑同一行 = 修復。移除：`... | sh -s -- --uninstall`。

安裝做的事：

1. `~/.config/agent-beacon/env`：儀表板位址與 token（權限 600）
2. Claude Code：加入這個 repo 當 marketplace、安裝 `agent-beacon` plugin、開 auto-update
3. Codex：`~/.codex/config.toml` 的 `notify` 指向 `~/.local/share/agent-beacon/beacon`；原本已有 notify 會保留並串接執行（備份在 `config.toml.agent-beacon.bak`）。沒裝 Codex 就略過

## 送出的資料

只有：事件名、session id、cwd、hostname、agent（claude / codex）、時間、notification 類型。
prompt、Claude 回覆、工具指令與檔案內容一律不送，也不掛 PreToolUse。PostToolUse 只用來知道「核准權限後 Claude 繼續在跑」，它的 payload 含工具輸入輸出，beacon 連 cwd 都不從裡面取。

## 掛的事件

| Agent | 事件 |
| --- | --- |
| Claude Code | SessionStart、UserPromptSubmit、PostToolUse（只送事件名，不送工具內容）、Notification（權限、等輸入、elicitation）、Stop、SessionEnd |
| Codex | notify 的 `agent-turn-complete` |

`beacon` 永遠 exit 0、不輸出任何東西、背景 POST（2 秒 timeout），不會卡住 agent。
