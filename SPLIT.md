# 并行：grok + grok-3p 可同时开

## 结论

| 命令 | home | 改不改对方 |
|--|--|--|
| `grok` | `~/.grok` | 不碰 3p |
| `grok-3p` | `~/.grok-3p` | **永不写** `~/.grok/config.toml` |

skills / bin / bundled 等从官方 **symlink**，模型列表 / effort / session 在 3p 自己目录。

## 为什么必须隔离

共用一份 config 时：3p 注入中转模型 → 另开的裸 `grok` 也会读到 → JWT 打中转 → **401**。  
要同时开，只能两个 home。

## 仍保留

1. effort = 官方真实元数据  
2. 新模型 `3p-00` 在最上（`created` 降序）  
3. 直连中转、可流式  
