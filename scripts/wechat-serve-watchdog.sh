#!/usr/bin/env bash
# 微信桥接看门狗：serve 挂了自动拉起；token 失效只通知一次。
# dry-run (HATCH_HOOK_DRY_RUN=1) 时不做任何实际变更。
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

DATA="$HOME/workspace/wechat-bridge-data"
CODE="$HOME/workspace/wechat-bridge"
PIDFILE="$DATA/state/serve.pid"
NOTIFIED="$HOME/hooks/state/wechat-bridge/notified_relogin"
DRY="${HATCH_HOOK_DRY_RUN:-0}"

decision="silent"
reason="serve 运行中"
payload='{}'

if [ ! -f "$DATA/state/session.json" ]; then
  reason="未登录，看门狗休眠"
elif [ -f "$DATA/state/NEEDS_RELOGIN" ]; then
  mkdir -p "$(dirname "$NOTIFIED")"
  if [ ! -f "$NOTIFIED" ]; then
    if [ "$DRY" != "1" ]; then touch "$NOTIFIED"; fi
    decision="wake"
    reason="微信桥接 token 失效，需要 Ryan 重新扫码登录"
    payload='{"event":"needs_relogin"}'
  else
    reason="token 失效已通知，等待重新登录"
  fi
else
  # 登录恢复后清除"已通知"标记，下次过期可再次通知
  if [ -f "$NOTIFIED" ] && [ "$DRY" != "1" ]; then rm -f "$NOTIFIED"; fi
  alive=0
  if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then alive=1; fi
  fi
  if [ "$alive" -eq 1 ]; then
    reason="serve 运行中"
  elif [ "$DRY" = "1" ]; then
    reason="dry-run：serve 未运行，正式运行会重启"
  else
    log "serve 未运行，尝试重启"
    cd "$CODE"
    WECHAT_BRIDGE_DIR="$DATA" nohup .venv/bin/python -m wechat_bridge serve >> "$DATA/state/serve.log" 2>&1 &
    disown 2>/dev/null || true
    sleep 3
    newpid=""
    [ -f "$PIDFILE" ] && newpid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$newpid" ] && kill -0 "$newpid" 2>/dev/null; then
      log "serve 重启成功 pid=$newpid"
      reason="serve 已自动重启"
      payload="{\"pid\":\"$newpid\"}"
    else
      log "serve 重启失败"
      decision="wake"
      reason="微信桥接 serve 挂了且自动重启失败，需要人工检查"
      payload='{"event":"serve_restart_failed"}'
    fi
  fi
fi

if [ "$decision" = "wake" ]; then
  wake "$reason" "$payload"
else
  silent "$reason" "$payload"
fi
