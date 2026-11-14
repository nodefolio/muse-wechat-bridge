#!/usr/bin/env bash
# 微信 inbox 新消息检查：有未处理消息就唤醒回复 worker。
# dry-run (HATCH_HOOK_DRY_RUN=1) 时不写任何状态文件。
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

DATA="$HOME/workspace/wechat-bridge-data"
INBOX="$DATA/inbox"
PROCESSED="$DATA/state/processed.json"
DRY="${HATCH_HOOK_DRY_RUN:-0}"

decision="silent"
reason="无新消息"
payload='{}'

mkdir -p "$DATA/state"
[ -f "$PROCESSED" ] || echo "[]" > "$PROCESSED"

if [ ! -f "$DATA/state/session.json" ]; then
  reason="未登录"
elif [ -f "$DATA/state/NEEDS_RELOGIN" ]; then
  reason="token 失效，等待重新登录"
else
  new_ids=()
  for f in "$INBOX"/*.json; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .json)"
    if jq -e --arg id "$id" 'index($id) != null' "$PROCESSED" >/dev/null 2>&1; then
      continue
    fi
    if [ -f "$DATA/outbox/sent/$id.json" ] || [ -f "$DATA/outbox/pending/$id.json" ]; then
      if [ "$DRY" != "1" ]; then
        add_json="$(printf '%s\n' "$id" | jq -R . | jq -s -c '.')"
        tmp="$(mktemp)"
        jq --argjson add "$add_json" '. + $add | unique' "$PROCESSED" > "$tmp" && mv "$tmp" "$PROCESSED"
      fi
      continue
    fi
    new_ids+=("$id")
  done
  if [ "${#new_ids[@]}" -gt 0 ]; then
    if [ "$DRY" != "1" ]; then
      add_json="$(printf '%s\n' "${new_ids[@]}" | jq -R . | jq -s -c '.')"
      tmp="$(mktemp)"
      jq --argjson add "$add_json" '. + $add | unique' "$PROCESSED" > "$tmp" && mv "$tmp" "$PROCESSED"
    fi
    decision="wake"
    reason="微信收到 ${#new_ids[@]} 条新消息待回复"
    payload="$(printf '%s\n' "${new_ids[@]}" | jq -R . | jq -s -c '{message_ids: .}')"
  fi
fi

if [ "$decision" = "wake" ]; then
  wake "$reason" "$payload"
else
  silent "$reason" "$payload"
fi
