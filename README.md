# codex-ThridPartyAPI

在保留官方 `codex` 登录态的前提下，额外安装一个第三方 API 入口，用不同命令在官方订阅和第三方 API 之间切换。

## 作用

- `codex`：继续走官方订阅
- `codex-3p`：走你配置的第三方兼容接口
- 两套入口可以并存，适合把官方账号使用和第三方 API 使用拆开

这个仓库里的 `codex-thirdparty` 是安装脚本。运行一次后，会在本机安装 `codex-3p` 启动命令。

## 前提

- 已经安装官方 `codex`
- 至少启动过一次官方 `codex`
- 本机存在 `~/.codex/config.toml`

如果没有先跑过官方 `codex`，第三方入口第一次拉模型目录时可能缺少 `models_cache.json`。

## 安装

先打开 `codex-thirdparty`，把脚本顶部这两个值改成你自己的：

```bash
THIRDPARTY_BASE_URL="YOUR-BASE-URL"
THIRDPARTY_API_KEY="YOUR-API-KEY"
```

改完后直接执行：

```bash
chmod +x ./codex-thirdparty
./codex-thirdparty
```

脚本会自动：

- 把 `THIRDPARTY_BASE_URL` 写入 `~/.codex/config.toml`
- 把 `THIRDPARTY_API_KEY` 写入 `~/.codex/thirdparty.env`
- 安装 `~/.local/bin/codex-3p`

不需要再手动编辑 `~/.codex/config.toml` 或 `~/.codex/thirdparty.env`。

## 使用方式

```bash
codex
```

上面这条继续使用官方订阅。

```bash
codex-3p
```

上面这条走第三方 API。

也就是说，日常使用时可以直接按入口区分：

- 想走官方账号时，启动 `codex`
- 想走第三方接口时，启动 `codex-3p`

## 已知问题

当前 `sessions` 仍然会混在 Codex 自己的会话存储里一起显示，但因为 Codex 本身的会话恢复机制和 provider 绑定，官方订阅会话与第三方 API 会话之间目前不能共享，也不能互相 `resume`。

实际影响是：

- 会话列表里可能同时看到两边的 session
- 但官方开的 session 不能切到第三方 API 去恢复
- 第三方 API 开的 session 也不能切回官方入口恢复

所以目前应把 `codex` 和 `codex-3p` 视为两套并行入口，只做“并存”，不要把它们理解成可互通的同一套 session。

## 备注

- 如果你后面想换第三方地址或 API Key，直接修改 `codex-thirdparty` 顶部两个变量后重新运行一次脚本即可
- 如果 `codex-3p` 首次提示 `models_cache.json` 缺失，先运行一次官方 `codex`，再重试 `codex-3p`
- 本仓库只建议上传安装脚本和说明文件，不要把包含私钥或真实配置的本地变体脚本提交到 GitHub
