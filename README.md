# 把 Muse 接入微信：不用 API，接的是「本人」

在微信里直接和你的个人 AI 助手 Muse 对话：发文字、图片、语音、文件，
它带着对你的全部记忆和上下文回复你——不是那种接了个大模型 API、
聊完就忘的失忆版机器人。

走的是**微信官方 iLink / ClawBot 通道**，不是第三方协议逆向，
不用担心封号那一套。桥接只出站长轮询，**不开任何端口**。

> 本仓库是部署教程 + 增补件（hook 脚本、worker 提示词、延迟补丁）。
> 桥接本体是开源项目 [Liu-zhongxian/wechat-bridge](https://github.com/Liu-zhongxian/wechat-bridge)（MIT），
> 本教程的所有步骤都在真实环境里跑通并持续运行了一个多月。

## 架构

```
微信 ──iLink 长轮询──▶ wechat-bridge serve ──▶ inbox/*.json
                                                    │
                              hook 每 15 秒检查 inbox（有新消息就唤醒 worker）
                                                    │
                              worker（Muse 本人，带记忆）写回复
                                                    ▼
微信 ◀──iLink 发送──── serve 发送线程 ◀── outbox/pending/*.json
```

- `serve`：桥接的常驻进程，只负责收发和媒体加解密。
- `hook + worker`：Muse 平台的事件钩子。每 15 秒看一眼 inbox，
  有新消息才唤醒一个 worker 来读消息、写回复；没有就静默，不烧资源。
- 回复带记忆的关键在 worker 提示词第 2 步：回复前先读长期记忆。

## 前提

- 一台常开的机器：Linux / macOS 都行（家里的电脑、NAS、VPS 均可）。
- Python 3.8+。
- 一个能操作这台机器的 Muse（本教程的 hook 部分用 Muse 的钩子机制；
  换其他 agent 框架时，把「hook 轮询 + 唤醒」换成 cron + 拉起 agent 即可，思路通用）。
- 一个微信账号，手机能扫码。

## 步骤

### 1. 拿桥接代码，装依赖

```bash
git clone https://github.com/Liu-zhongxian/wechat-bridge
cd wechat-bridge
python3 -m venv .venv
.venv/bin/pip install qrcode pycryptodome pillow
.venv/bin/python tests/test_crypto.py   # 输出「全部通过」再往下走
```

**坑**：上游 README 的依赖清单漏了 `pillow`。不装它，`login` 生成
二维码图片时直接报 `ModuleNotFoundError: No module named 'PIL'`，
卡在第一步。先装上。

### 2. 扫码登录

数据和代码分开放，后面升级代码不丢登录态：

```bash
export WECHAT_BRIDGE_DIR=~/wechat-bridge-data
.venv/bin/python -m wechat_bridge login        # 生成二维码图片 qrcode.png
.venv/bin/python -m wechat_bridge wait-login   # 后台等扫码确认
```

把 `qrcode.png` 发到你能用手机看到的地方，微信扫一扫，手机上点确认。

**坑**：二维码有效期只有约 **2 分钟**。先把手机拿在手里、微信打开，
再运行 `login`。过期了 `wait-login` 会自动刷新（最多 3 次），
但图片要重新发给你，节奏就乱了。

登录成功后凭据只存在数据目录的 `state/session.json`（0600 权限）。
**bot_token 绝不进仓库、绝不发到任何聊天里**，status 输出也是脱敏的。

### 3. 你先发一条消息（官方规矩，绕不过去）

登录完成后，**先用微信给这个 Bot 发一条消息**，比如「你好」。

**坑**：官方限制——助手不能主动发起会话，用户先发的那条消息里带着
`context_token`，没有它回复根本发不出去。serve 会把最新会话上下文
缓存下来（`state/last_context.json`），后续发送靠它。

### 4. 启动 serve，手动验一次收发

```bash
WECHAT_BRIDGE_DIR=~/wechat-bridge-data \
  nohup .venv/bin/python -m wechat_bridge serve \
  > ~/wechat-bridge-data/state/serve.log 2>&1 &
```

看 `inbox/` 里有没有你刚发的那条消息的 JSON；有，就用它里面的
`context_token` 手动回一条试试：

```bash
.venv/bin/python -m wechat_bridge send --text "接通了"
```

微信里收到这条回复，说明收发链路都通了。

### 5. 打补丁：修掉「回复慢一分钟」的坑（重要）

原版 serve 只在 getupdates 长轮询（45 秒）返回时顺手发一次 outbox，
回复最坏要等大半分钟，体感就是「发了没人理」。

补丁把发送改成独立守护线程、每 5 秒发一次，主循环不再管发送：

```bash
# 在 wechat-bridge 仓库目录里
git apply /path/to/serve-flush-thread.patch   # 本仓库 patches/ 里
# 重启 serve 生效
```

补丁文件：[`patches/serve-flush-thread.patch`](patches/serve-flush-thread.patch)。
打完之后，回复写进 `outbox/pending/` 后 5 秒内必发。

### 6. 配自动回复：hook + worker

在 Muse 里建一个 hook，每 **15 秒**运行
[`scripts/wechat-inbox-watch.sh`](scripts/wechat-inbox-watch.sh)：

- 脚本只做一件事：对比 `inbox/` 和 `state/processed.json`，
  有未处理的新消息就 `wake`，并把 message_id 列表交给 worker；
  没有就 `silent`。
- worker 的提示词全文在
  [`prompts/reply-worker.md`](prompts/reply-worker.md)，照抄即可。
  几个要点都是踩出来的：
  - **多条消息合并成一条回复**（≤200 字，用最新一条的 context_token），
    既不刷屏，也避开官方「连续约 10 条不回复会被限流」；
  - 回复文件名用 message_id，天然幂等，重复唤醒不会重复发；
  - 处理过的 id 记进 `processed.json` 去重；
  - worker 处理不了的重活（查资料、读链接），先回一句「收到」
    再转主 agent 跟进，别让消息掉地上。

启用 hook 前，先把 inbox 里已有的历史消息 id 全部写进
`processed.json`，免得上线第一分钟把旧消息全回一遍。

### 7. 配看门狗：serve 挂了自己爬起来

再建一个 hook，每 **60 秒**运行
[`scripts/wechat-serve-watchdog.sh`](scripts/wechat-serve-watchdog.sh)：

- serve 进程不在了 → 自动拉起，静默，不打扰你；
- 发现 `state/NEEDS_RELOGIN`（token 失效）→ 只通知一次，
  唤醒维护 worker 刷出新二维码等你重扫（提示词在
  [`prompts/watchdog-worker.md`](prompts/watchdog-worker.md)）。

机器重启同理：hook 是常驻的，serve 被拉起来之前你只是晚几分钟收到
回复，不会丢消息（消息都存在 inbox 里）。

## 实测数据（本机真实运行）

- 上线时间：2026-10-11；到 2026-11-14 登录态仍有效，
  **一个多月没重新扫过码**（token 寿命比预想的长，但官方没有
  refresh 机制，失效就重扫，没有例外）。
- 回复延迟：普通聊天约 30 秒–1 分钟（15 秒轮询 + worker 组织语言）；
  带链接、要读完内容再回的，约 2 分钟。
- serve 日志里偶见微信服务端主动断连
  （`Remote end closed connection without response`），桥接自带
  指数退避重试，不影响收发，不用管。

## 限制（微信官方，明说在前）

- **仅一对一私聊**，不支持群聊。
- **不能主动发起会话**：用户必须先发消息，你才能回。
- 连续约 10 条不回复会被限流，用户回一句重置。
- 二维码有效期约 2 分钟；token 失效无 refresh，只能重扫。

## 安全

- 全部通信走 iLink 出站长轮询，本机**不开任何入站端口**。
- `session.json` 是唯一的凭据文件，0600 权限，只放本地数据目录。
- 桥接只处理机主本人微信 ID 发来的消息，群消息和其他人的消息
  直接忽略。
- 本仓库不含任何真实凭据、账号 ID 或聊天记录，脚本里只有路径和逻辑，
  可以放心 fork。

## 适合 / 不适合

适合：把微信当成和自己 AI 助手的主入口——随手问事、发链接让它看、
发图让它认，不用在两个 App 之间来回切。

不适合：群聊机器人、客服系统、主动推送通知。这条通道生来就只做
一对一、被动回复这一件事，把它用在对的地方，它就非常稳。

## 致谢

桥接本体：[Liu-zhongxian/wechat-bridge](https://github.com/Liu-zhongxian/wechat-bridge)，
媒体加解密思路参考其 README 致谢的 wx-bot。本仓库只贡献教程、
hook 脚本、worker 提示词和延迟补丁，协议层没有任何改动。
