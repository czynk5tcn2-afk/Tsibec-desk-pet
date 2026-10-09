# Tsibec-desk-pet · 薰子桌宠

Mac 桌面上的二次元桌宠：她站在你的桌面上陪你学习，顺便盯着你的 AI 额度（Claude、Codex，也能自己接别的）。

![薰子：吃蛋糕、一起看书、看额度](docs/screenshot.png)

*A tiny macOS desktop companion that keeps you company while you study and watches your AI usage limits (Claude, Codex, or anything you plug in).*

## 她会做什么

- **站在桌面上**：透明、没有边框、浮在所有窗口上面；按住拖到哪就待在哪。点她身边的空白处（连头发缝里）都能直接点到下面的软件。
- **会动**：呼吸、眨眼、头发和裙摆随风轻轻摆；跳起来会压扁拉伸，拎起来会荡，鼠标停在她身上会歪头看你；白天偶尔飘花瓣，晚上身边有星星。
- **互动**：单击打招呼或摸头；右键菜单里可以喂蛋糕、一起看书、小睡。
- **一起学习**：番茄钟 25 / 50 分钟，她捧着书陪你，时间到了提醒你休息，还记着今天学了几轮。
- **作息**：早上换常服、晚上换睡衣（时间可调），换的时候会转一圈；午后或深夜很久没理她，她会自己睡着。
- **额度提醒**：Claude、Codex 的 5 小时 / 每周额度一变就冒气泡；右键“看看额度”一眼看全。
- 内存约 20MB，CPU 不到 1%（动画在显卡上跑）。右键菜单还有“省电模式”。

## 安装（从源码编译）

需要 macOS 13 以上，和苹果的命令行开发工具（没装的话终端里运行 `xcode-select --install`）。

```bash
git clone https://github.com/czynk5tcn2-afk/Tsibec-desk-pet.git
cd Tsibec-desk-pet
./build.sh install
```

会装到 `~/Applications/薰子.app` 并启动。屏幕顶部菜单栏会多一个 ✿，菜单和右键她是一样的。想开机自动出来：右键 → 开机自动出来。

## 额度从哪来

全部只读你自己电脑上的文件：**不联网、不读登录信息、不上传任何东西**。

| 来源 | 怎么接 | 前提 |
|---|---|---|
| **Codex** | 自动。读 Codex 自己写在 `~/.codex/sessions/` 里的对话记录 | 用过一次 Codex |
| **Claude** | 在 `~/.claude/settings.json` 里加 `"statusLine": {"type": "command", "command": "/你的路径/Tsibec-desk-pet/extras/claude-statusline.sh"}` | Claude Pro / Max 订阅；新开会话、回答过一次后才有数据；需要 `jq`（macOS 自带） |
| **其它任何工具** | 往 `~/.pet-quota/名字.json` 写一个小文件，见 [docs/额度来源.md](docs/额度来源.md) | 那个工具能拿到用量数字 |

想接豆包、Kimi 之类的：把 [docs/额度来源.md](docs/额度来源.md) 发给你的 AI，说“帮我把 XX 的额度接到桌宠上”。文档本来就是写给 AI 看的，不用改桌宠代码。

## 自己改

- **换角色**：替换 `Resources/frames/` 里的 8 张透明 PNG（文件名不变：`day_` / `night_` × `idle` 睁眼、`blink` 闭眼、`read` 看书、`hold` 抱着要换的衣服），尺寸一致、脚底对齐即可；白底图可以用 `tools/cutout.py` 抠。然后 `./build.sh install`。
- **改台词**：在 `Sources/main.swift` 里搜 `lines`，都是中文字符串。
- 让 AI 帮你改的话，先让它读 [AGENTS.md](AGENTS.md)。

## 版权说明

- 代码按 [MIT 协议](LICENSE) 开源。
- **角色和立绘不在 MIT 协议范围内。** 和栗薰子是漫画《薫る花は凛と咲く》（三香見サカ／讲谈社）中的角色，版权归原作者和出版社所有。本项目的立绘是 AI 生成的同人图，仅供个人学习交流，不得商用；与原作、出版社、动画制作方无任何关系。如版权方认为不妥，请开 issue 联系，会立即移除。
- 公开分发或二次发布时，建议换成自己的原创角色。
