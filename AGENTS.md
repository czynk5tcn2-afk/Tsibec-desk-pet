# 给 AI 助手的开发说明

这是一个 macOS 桌宠：透明无边框窗口，浮在最上层，可以拖动。独立小程序，Swift + AppKit + Core Animation，全部代码在一个文件 `Sources/main.swift`，没有第三方依赖。用户多半不是程序员，请用中文、通俗地解释你做了什么。

## 编译和安装

```bash
./build.sh install
```

编译到 `build/薰子.app`，复制到 `~/Applications/薰子.app` 并启动（会先关掉正在跑的那只）。改了代码把 `VERSION` 加一。

## 文件

- `Sources/main.swift`：全部逻辑。主要类：`Pet`（窗口、动画、互动、菜单）、`QuotaWatcher`（quota-log 插件的 CSV 表格）、`CodexWatcher`（Codex 额度）、`FolderWatcher`（通用额度文件夹）、`BubbleView`（气泡）。
- `Resources/frames/`：8 张透明 PNG 立绘，`day_` / `night_` × `idle`（睁眼）`blink`（闭眼笑）`read`（看书）`hold`（抱着要换的衣服）。8 张必须同尺寸、脚底对齐。
- `tools/cutout.py`：把白底立绘抠成透明（需要 Pillow、numpy、scipy）。
- `extras/claude-statusline.sh`：Claude Code 状态栏脚本，把官方 `rate_limits` 写成 `~/.pet-quota/claude.json`。
- `docs/额度来源.md`：接入新额度来源的说明（通用 JSON 格式）。
- 偏好存在 UserDefaults（`com.emma.kaoruko-pet`）：位置、大小、安静模式、额度提醒档位、换装时间等。

## 额度来源

- **Codex**：读 `~/.codex/sessions/年/月/日/rollout-*.jsonl` 里最新一条 `token_count` 事件的 `rate_limits`（primary = 5 小时、secondary = 每周，`resets_at` 是秒级时间戳）。只看最近 4 天里最新的那份、只读文件最后 256KB。
- **通用文件夹** `~/.pet-quota/*.json`：格式见 `docs/额度来源.md`。叫 `Claude` 且 6 小时内更新过的文件，优先于 quota-log 的 CSV。
- **quota-log 的 CSV**：默认路径 `~/Documents/forai/额度记录.csv`，可以 `defaults write com.emma.kaoruko-pet csvPath <路径>` 改。没有这个插件的话忽略即可。
- 只读本机文件。不要加任何读取登录凭证、调用非公开接口或联网上传的代码。

## 调试（不用截屏权限）

自带一个调试口，默认关着：

1. `defaults write com.emma.kaoruko-pet debug -bool true`，然后 `pkill -x Kaoruko; open ~/Applications/薰子.app`（刚装完第一次启动要等几秒）。
2. 往 `~/Library/Caches/kaoruko/cmd` 写一行或多行动作名，一秒内依次执行。下一批命令至少隔 1.5 秒，不然会覆盖。
   - 动作：`greet` `pat` `cake` `read` `nap` `day` `night` `quota` `chat` `study` `studydone` `autonap` `fakequota` `hop` `spin` `fidget` `petal` `twinkle` `swing` `codexpoll` `folderpoll`
   - `snap:<名字>`：把窗口画成 `~/Library/Caches/kaoruko/<名字>.png`（深色底），同时写 `.txt` 记录窗口位置、是否穿透点击、衣服、状态、Codex 读数。`snap:<名字>@0.3` 是 0.3 秒后再拍，用来抓动画中间那一帧。
3. 测完：`defaults delete com.emma.kaoruko-pet debug`、`defaults delete com.emma.kaoruko-pet studyLog`，重启她。手动换过装的话再发一次 `day` 或 `night`。

拖动、点击穿透、右键菜单要真鼠标，只能请用户试。

## 动画结构

全用 Core Animation，动画在显卡上跑，程序本身 CPU 不到 1%、内存约 20MB。改动画时别破坏这一点（不要每帧手动重画整张图）。

- 立绘套了几层，各管一种动作，互不打架：`mover`（跳、压扁拉伸、换装转圈）› `swing`（拎起来绕头顶摆，60 帧弹簧，只在拖动和停下的那一两秒跑）› `lean`（歪头、看鼠标、睡着时头歪）› `body`（呼吸、轻晃）。
- 头发裙摆的风：`body` 里把立绘横切成 36 条，共用同一张图，各显示自己那一段。头（0~0.35）和脚（0.85~1）不动，中间按正弦摆 ±1.4 点，从上往下传。每条往下多盖 1 点，不然接缝会露细线。
- 白天花瓣、晚上星星；闲着时 40~90 秒做一次小动作；看书时点头翻页。
- 气泡：带小尾巴的整块路径，弹出来后逐字显示（没打出来的字先透明占位，排版不跳）。话多时窗口往上长，脚不动。
- 只有鼠标落在她身上（按图的透明度判断）或气泡上时，窗口才接收点击；其余透明处点击直接穿到下面的软件。

## 常见改法

- **换角色**：替换 `Resources/frames/` 的 8 张图（白底图先用 `tools/cutout.py` 抠），再在代码里搜 `lines` 改台词，然后 `./build.sh install`。
- **改台词**：搜 `lines`、`say(`。“安静陪伴”只关闲聊，额度提醒照常。
- **接新额度来源**：优先让那个工具往 `~/.pet-quota/` 写文件（见 `docs/额度来源.md`），不要改 Swift 代码。
