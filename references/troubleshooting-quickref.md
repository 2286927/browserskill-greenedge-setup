# 故障速查表（一页版）

按现象直接查处置，不需要读设计说明。成因与细节见 `deployment-guide.md` 第六节。

## 1. 三步自检（先跑这个，多数问题一眼定位）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\detect_edge.ps1"
& "$env:USERPROFILE\.local\bin\bsk.exe" doctor
& "$env:USERPROFILE\.local\bin\bsk.exe" status --json
```

`detect_edge.ps1` 看 `edge.found` / `daemon.running`；`doctor` 看哪一项不是 `ok`；`status` 看 `browsers` 是否为空。

## 2. 速查

| 现象 | 一句话处置 |
|---|---|
| `os error 5` / Job Object breakaway | 别重试自动启动；用 Bash 工具后台任务跑 `daemon start --foreground` |
| daemon 没跑（`daemon.running=false`） | 同上；注意重装 bsk 会停掉 daemon，装完必须重起 |
| 扩展没连上（`browsers` 为空） | 让用户在扩展弹窗点「启用连接」，端口对照 `status` 的 `ws_port` |
| 扩展没装 | 交给用户从 Edge 商店装：`microsoftedge.microsoft.com/addons/detail/browserskill/emacgiaaaiojkkpkddmmdfhmokgmnikg` |
| `bsk: command not found` | 新 shell PATH 未刷新；直接用绝对路径 `& "$env:USERPROFILE\.local\bin\bsk.exe"` |
| GitHub 超时 / `ERR_CONNECTION_CLOSED` | 默认会自动回退镜像；仍失败则加 `-UseMirror` |
| `no pinned checksum ... came from a mirror` | 完整性保护，不是网络问题；改用 `-DirectOnly`，或把该版本 SHA256 固化进 `$KnownSha256` |
| `no SHA256 available` | 拒绝安装不可验证的制品；先确认官方 release 正常，再固化校验值 |
| `download failed on every allowed source` | `-CheckOnly` 看哪条通；换网络；新增镜像前先核实域名声誉 |
| 下载报「意外的 EOF」/ 404 | 脚本会自动切源；持续失败用官方 `install.ps1` 兜底 |
| `iex` 被拦截（Command blocked for security） | 改用「下载 → 审查 → `-ExecutionPolicy Bypass -File` 执行」 |
| 探测脚本找不到 Edge | 用 `-EdgeDir "<msedge.exe 所在文件夹>"` 指定；或去掉 `-SkipScan` |
| `detect_edge.ps1` 语法错误 / 乱码 | 用 UTF-8 **with BOM** 保存（PS 5.1 按 ANSI 读 .ps1） |
| `version_skew: true` | CLI 与扩展版本不匹配；重跑安装脚本升级 CLI，或对齐扩展版本 |
| `session start` 了但 `navigate` 无响应 | 让用户打开绿装 Edge（`App\msedge.exe` 或其启动器）后重试 |
| 装完想撤销 | 见 `deployment-guide.md` 第五节「卸载与回滚」 |

## 3. 两个方向性提醒

- **不要为了连通性削弱校验**：镜像只是传输通道，校验值必须来自包内固化值或官方直连的 manifest。
- **不要重启正在运行的 daemon**：客户端命令带 `BSK_AUTO_START=0` 即可复用，重启会打断用户正在进行的浏览器会话。
