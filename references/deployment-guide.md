# BrowserSkill 绿装 Edge 接入 — 部署细节与故障排查

本文件是 SKILL.md 五步流程的详细参考。所有内容来自真实机器上的实战验证记录。

- 只想快速定位某个报错 → 直接看 `troubleshooting-quickref.md`（一页速查表）
- 想理解设计取舍与坑的成因 → 看本文件

## 一、绿装 Edge 的目录形态与判定

绿色安装版 Edge（非标准安装，整包放置）的典型目录：

```
D:\Program Files\Microsoft Edge\
├── App\
│   ├── msedge.exe                    ← 主程序入口（部分绿装包直接放这里）
│   ├── 139.0.3405.119\               ← 版本子目录（内含真正的 msedge.exe）
│   ├── chrome++.ini                  ← chrome++ 增强补丁配置（绿装常见标志）
│   └── version.dll / version-x64.dll ← chrome++ 注入 DLL
├── Data\                             ← 便携化用户数据目录（扩展/登录态都在这里）
├── msedge.lnk                        ← 快捷方式启动器
├── 开始.bat                          ← 启动脚本（文件名可能是中文，脚本不硬编码，动态列出）
└── Tools\ / BAK\ / Cache\            ← 其他绿装附属目录
```

官方安装版对照：`C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`。

判定要点：

- `App\` 子目录存在、包内 `Data\`/`User Data\` 存在、`chrome++.ini` 存在 → 绿装（`is_portable: true`，`markers` 会列出命中的标志）
- 启动方式在 `launchers` 里全部列出：`direct_exe`（直启 exe）、`bat_files`、`lnk_files`；文件名动态读取，不写死中文名
- 扩展检测在用户数据目录下查找 `*/Extensions/emacgiaaaiojkkpkddmmdfhmokgmnikg`，覆盖 `Default`、`Profile 1` 等所有 profile

## 二、探测脚本的 4 层识别策略

非标准布局（改名文件夹、放在 `D:\Tools\...`、厂商子目录嵌套）靠单一候选路径一定漏，因此 `detect_edge.ps1` 按「便宜优先」顺序尝试 4 层，命中的层级记录在 `edge.found_via`：

| 层 | 策略 | 说明 |
|---|---|---|
| 1 | 显式 `-EdgeDir "<目录>"` | 用户已知位置时最快；该层失败会继续往下走 |
| 2 | 各固定盘符的常见绿装路径 | `Program Files` / `Program Files (x86)` / 盘根 / `Apps` / `Software` / `Tools` / `Portable` 下的 `Microsoft Edge\App\msedge.exe`、`Application\msedge.exe`；再加官方 `Microsoft\Edge\Application` |
| 3 | 注册表 `App Paths\msedge.exe` | `HKLM`、`HKLM\WOW6432Node`、`HKCU` 三处，官方安装器与部分重打包会注册 |
| 4 | 有界目录扫描（最多 3 层） | 只枚举盘根一层与 `Program Files`/`Apps`/`Software`/`Tools`/`Green`/`Portable`/`应用`/`软件`/`工具`/`绿色`/`便携` 等容器目录的下一层，跳过 `Windows`、`$Recycle.Bin`、`AppData` 等，**不会全盘遍历** |

- 本机实测：4 层全部开启时耗时约 1.9 秒（第 2 层即命中）
- 追求最快可用 `-SkipScan` 跳过第 4 层
- 4 层都没找到时，输出 `edge.found=false` + `searched`（已搜范围）+ `hint`（请用户给出 msedge.exe 所在文件夹）

## 三、bsk CLI 安装

### 设计取舍（v1.1.3）

历史：v1.1.0 被 SkillHub 安全扫描判为「可疑风险」（安全健康度 55；科恩、云鼎两家实验室均判「可疑」，恶意行为检出 0），原因是：从第三方代理下载、SHA256 期望值也取自同一代理通道、缺校验时跳过校验。

v1.1.2 在修复这些问题的同时保住了国内可用性（官方直连优先 + 镜像回退）。v1.1.3 补齐了最后一处不一致——**校验值来源的信任边界**，使「镜像不参与信任判断」这句话在代码层面真正成立。

### 校验值信任规则（v1.1.3 核心）

| 顺序 | 期望 SHA256 来源 | 是否采信 | 行为 |
|---|---|---|---|
| 1 | 包内固化 `$KnownSha256` | ✅ 始终采信 | 与下载通道无关；当前固化 bsk 0.4.0 = `6feeb22e608e63e3049b2611cf48fce73daac2420945c35174c16e784cdb2677` |
| 2 | 官方 manifest（`version.json`），**且该 manifest 由 github.com 直连取得** | ✅ 采信 | 打印黄色提示：该版本未固化，使用直连取得的官方值 |
| 3 | 官方 manifest，但 manifest 来自镜像 | ❌ **不采信** | 硬失败退出，提示 pin 进 `$KnownSha256` 或改用 `-DirectOnly` |
| 4 | 两者都没有 | ❌ | 硬失败退出，绝不跳过校验安装 |

推论（可以据此向审核/用户解释）：

- 经代理传输的校验值一律不可信，因此不存在「代理同时篡改制品与校验值」的路径
- 镜像只可能造成「安装失败」，不可能造成「装入被篡改的 bsk」
- 未固化的新版本在纯镜像网络下会装不上——这是刻意的取舍：宁可装不上，不装不可验证的东西

### 三种运行模式

```powershell
# 默认：官方直连优先，直连不通才回退镜像
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\install_bsk.ps1"

# 国内 GitHub 极慢/被封：镜像优先，官方作为最后兜底
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\install_bsk.ps1" -UseMirror

# 最严格：任何镜像都不用
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\install_bsk.ps1" -DirectOnly

# 只探测各源连通性，不安装（排障）
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\install_bsk.ps1" -CheckOnly

# 固定版本 / 调整超时
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\install_bsk.ps1" -Version 0.4.0 -TimeoutSec 30
```

安装流程：解析版本 → 确定校验值来源 → 逐源下载并校验 → 打印完整性报告 → 解压 → 停旧 daemon → 替换 `~/.local/bin/bsk.exe`（带重试，防文件锁）→ 写用户 PATH 与 `~/.bashrc` → 仅执行 `bsk --version` 验证。

### 镜像清单

**保留**（`mirror-lib.ps1` 中的尝试顺序）：

| 用途 | 域名 |
|---|---|
| Release / zip | `gh-proxy.org` → `ghproxy.net` → `wget.la` |
| Raw | `gh-proxy.org` → `wget.la` |
| Clone（仅文档参考，手工 `git clone` 用） | `gh-proxy.org` → `githubfast.com` → `gitclone.com` |

**已移除，勿再加回**（2026-11-01 腾讯威胁情报标记）：

| 域名 | 情报计数 |
|---|---|
| `cdn.gh-proxy.org` | m=8 |
| `ghfast.top` | m=8 |
| `hk.gh-proxy.org` | m=5 |

新增镜像的门槛：

1. 自行核实域名声誉（不复用未验证的第三方代理列表）
2. 只允许「前缀 + 原始 URL 的 PathAndQuery」型镜像，即 `镜像地址 = 前缀 + 原始 URL`，例：`https://gh-proxy.org/https://github.com/Tencent/BrowserSkill/releases/latest/download/version.json`
3. 加进 `mirror-lib.ps1` 后跑一次 `-UseMirror -CheckOnly` 确认可用
4. **不要为连通性牺牲校验逻辑**——v1.1.0 被拒就是先例

镜像列表可对照上游定期更新：`https://raw.githubusercontent.com/XIU2/UserScript/master/GithubEnhanced-High-Speed-Download.user.js`

### 技能涉及的全部 GitHub 下载环节（5 处）

| # | 环节 | 地址 | 类型 | 默认行为 |
|---|---|---|---|---|
| 1 | install.ps1 官方安装脚本 | `raw.githubusercontent.com/Tencent/BrowserSkill/main/install.ps1` | Raw | 仅兜底，直连 + 人工审查后执行 |
| 2 | version.json 版本清单 | `github.com/Tencent/BrowserSkill/releases/latest/download/version.json` | Release | 直连优先；其 sha256 仅在直连取得时采信 |
| 3 | bsk 主程序 zip | `github.com/Tencent/BrowserSkill/releases/download/cli-v{ver}/bsk-v{ver}-x86_64-pc-windows-msvc.zip` | Release | 直连 + 校验（包内固定值优先） |
| 4 | 技能自身分发包 zip | `github.com/2286927/browserskill-greenedge-setup/releases/download/v1.1.3/BrowserSkill绿装Edge接入技能.zip` | Release | 直连；需要时手工加镜像前缀 |
| 5 | git clone 仓库 | `github.com/2286927/browserskill-greenedge-setup.git` | Clone | 直连；需要时用 Clone 类镜像 |

### 兜底：官方安装脚本

WorkBuddy 安全策略会拦截 `Invoke-Expression`（别名 `iex`），官方文档的 `irm ... | iex` 一行式安装**会直接报错**；本技能也**禁止**一行式执行（不可预审）。

```powershell
# 1. 下载脚本到本地（下载不执行）
irm https://raw.githubusercontent.com/Tencent/BrowserSkill/main/install.ps1 -OutFile "$env:TEMP\bsk_install.ps1"

# 2. 审查该脚本内容（约 11KB，确认只做下载+校验+解压+写 PATH）

# 3. 审查后再以 Bypass 策略执行
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\bsk_install.ps1"

# 4. 绝对路径验证
& "$env:USERPROFILE\.local\bin\bsk.exe" --version
```

## 四、daemon 托管启动（WorkBuddy 宿主约束）

### 为什么不能让它自己启动

`bsk doctor` 报错 `cannot start an independent Windows daemon ... (os error 5)`：WorkBuddy 沙箱禁止 daemon 作为独立进程脱离 Job Object。这是宿主行为，不是权限配置问题，**不要反复重试自动启动**。

### 正确启动方式（Bash 工具 + 托管后台任务）

```sh
# run_in_background: true
BSK_AUTO_START=0 "/c/Users/<用户名>/.local/bin/bsk.exe" daemon start --foreground
```

daemon 启动日志中出现以下内容才算成功（但**仍需另起调用验证**，日志不等于就绪）：

```
ws server listening addr=127.0.0.1:52800
daemon ready pid=26660 ws_port=52800 sock=\\.\pipe\bsk-daemon-xxxx
ipc named-pipe server listening ...
browser connected id=xxxx name=edge   ← 扩展自动连上的标志
```

独立调用验证（每次客户端调用都要带 `BSK_AUTO_START=0`）：

```sh
BSK_AUTO_START=0 "/c/Users/<用户名>/.local/bin/bsk.exe" status --json
```

### daemon 生命周期

- 宿主会话结束 / 机器重启 → daemon 停止，下次使用前重新拉起
- 安装脚本替换 `bsk.exe` 前会 `daemon stop`（best effort），因此**重装后必须重新拉起 daemon**
- 后台任务保持运行是预期状态，不要当作残留任务清理
- daemon 已在运行时**绝不重启**（`BSK_AUTO_START=0` + `status` 探测即可复用）

## 五、卸载与回滚

### 卸载（完全移除 bsk CLI，保留浏览器扩展可选）

```powershell
# 1) 停掉 daemon（不存在时报错可忽略）
& "$env:USERPROFILE\.local\bin\bsk.exe" daemon stop

# 2) 删除二进制目录
Remove-Item -LiteralPath "$env:USERPROFILE\.local\bin\bsk.exe" -Force

# 3) 从用户 PATH 移除该目录
$dir = "$env:USERPROFILE\.local\bin"
$cur = @([Environment]::GetEnvironmentVariable("PATH","User") -split ';' | Where-Object { $_ -and ($_ -ine $dir) })
[Environment]::SetEnvironmentVariable("PATH", ($cur -join ';'), "User")

# 4) 从 ~/.bashrc 移除本技能写入的那一行
$rc = "$env:USERPROFILE\.bashrc"
if (Test-Path -LiteralPath $rc) {
    (Get-Content -LiteralPath $rc) | Where-Object { $_ -notmatch '# bsk CLI' } | Set-Content -LiteralPath $rc -Encoding UTF8
}
```

`~/.local/bin` 里可能还有别的工具，因此只删 `bsk.exe`，不要整目录删除。浏览器扩展如需移除，在 Edge 的扩展管理页卸载即可（不影响其他环境）。

### 回滚到旧版本

1. 从 GitHub Releases 下载目标版本的 zip（`v1.1.2`、`v1.1.1` …）
2. 解压 `bsk.exe` 覆盖 `%USERPROFILE%\.local\bin\bsk.exe`
3. 重新按第四节拉起 daemon，用 `bsk --version` 与 `bsk doctor` 确认

> 注意：扩展与 CLI 需保持协议兼容。`status --json` 里 `version_skew: true` 表示 CLI 与扩展版本不匹配，回滚后如果出现该字段，请升级/降级扩展至匹配版本，或改装较新的 CLI。

### 只回滚技能文件（不动已装的 CLI）

技能本身是 `~/.workbuddy/skills/browserskill-greenedge-setup/` 下的纯文本（`SKILL.md` + `scripts/*.ps1` + `references/*.md`）。要回到旧版技能：

```powershell
# 备份当前版本后，用目标版本 zip 解压覆盖同名目录即可
Copy-Item "$env:USERPROFILE\.workbuddy\skills\browserskill-greenedge-setup" "$env:USERPROFILE\.workbuddy\skills\browserskill-greenedge-setup.bak" -Recurse
```

## 六、故障排查（成因分析）

| 现象 | 原因 | 处理 |
|---|---|---|
| 访问 `github.com` / `raw.githubusercontent.com` 超时或 `ERR_CONNECTION_CLOSED` | 国内网络对 GitHub 不稳定 | 默认会在直连失败后自动回退镜像；仍不行则显式 `-UseMirror` |
| 报 `no pinned checksum ... came from a mirror` | 该版本未在包内固化，且 manifest 经镜像取得（v1.1.3 的信任边界） | 改用 `-DirectOnly`（让 manifest 与制品都来自直连），或把该版本 SHA256 固化进 `$KnownSha256` |
| 报 `no SHA256 available` | 包内无固化值且 manifest 无值 | 不要绕过；先确认官方 releases 是否正常，再固化校验值 |
| 报 "download failed on every allowed source" | 所有源同时不可用 | `-CheckOnly` 看哪条通；换网络/等恢复；新增镜像前先核实域名声誉 |
| 某个镜像下载到一半报 "意外的 EOF" | 该镜像连接被中断 | 脚本自动切下一个；留意最终报告的 `source=` |
| 镜像返回 404 | 镜像不支持该路径，或原始文件不存在 | 先 `-CheckOnly` 验证镜像本身；确认原始 URL |
| SHA256 校验不符 | 镜像缓存了旧文件或内容被篡改 | 脚本会自动换源重试；持续失败则用官方 install.ps1 直连重装并核对官方 checksum |
| `irm \| iex` 报 "Command blocked for security: iex" | WorkBuddy 安全策略拦截 Invoke-Expression | 按第三节兜底流程：下载→审查→`-ExecutionPolicy Bypass -File` 执行 |
| doctor 报 daemon "os error 5" / Job Object breakaway | 宿主禁止 daemon 独立脱离 | 用托管后台任务 + `--foreground`，不要重试独立启动 |
| 重装 bsk 后所有浏览器命令失效 | 安装脚本替换二进制前停掉了 daemon | 按第四节重新拉起 daemon（这是预期行为） |
| `bsk` 命令找不到 | 新 shell PATH 未刷新 | 一律用绝对路径：PowerShell `& "$env:USERPROFILE\.local\bin\bsk.exe"`；Bash `/c/Users/<用户>/.local/bin/bsk.exe` |
| doctor: `extension connected` 失败 | 扩展未装 / 扩展弹窗未启用连接 / 端口不匹配 | 新装扩展后需用户点启用连接；对照 daemon 的 `ws_port` |
| `status` 里 `version_skew: true` | CLI 与扩展版本不匹配 | 重跑安装脚本升级 CLI（会先 stop 旧 daemon 再替换） |
| `session start` 成功但 `navigate` 无响应 | 浏览器未开 / 扩展休眠 | 让用户打开绿装 Edge（`App\msedge.exe` 或其启动器）后重试 |
| 探测脚本找不到 Edge，但确实装了 | 非标准目录，且不在扫描覆盖的容器目录里 | 用 `-EdgeDir "<msedge.exe 所在文件夹>"` 直接指定 |
| 端口每次不同（如 52800） | daemon 每次启动随机分配 | 正常现象；扩展自动发现，无需固定端口 |
| `detect_edge.ps1` 报语法错误 / 中文乱码 | PS 5.1 按 ANSI 读 .ps1，文件缺 UTF-8 BOM | 本仓库脚本均带 BOM；自行编辑后用 UTF-8 with BOM 保存，或改为纯 ASCII |

## 七、验证基线（真实机器通过记录）

以下为本 skill 提炼来源机器（绿装 Edge 139，Windows 10 IoT Enterprise LTSC 2019）上的实测基线：

- `bsk doctor` 全绿：daemon running / IPC identity / protocol 1.7 / extension connected / browser protocol compatible
- 端到端：`session start` → `navigate example.com` → `observe` 读到页面文本与元素 ref（`@e1`/`@e2`）→ `session stop`
- `status` 关键字段：`browser_name=edge`、`extension_version=0.4.0`、`version_skew=false`、`unresponsive=false`
- `detect_edge.ps1`：`found_via=well-known path`、`is_portable=true`、markers 含 `App-dir`/`DataDir:Data`/`chrome++.ini(App)`、`browserskill_extension_installed=true`，耗时约 1.9s
- `install_bsk.ps1` 默认模式：`source=origin(direct)`、`checksum from=pinned in package`、`verified=OK`、6,820,462 字节

在任何新机器上部署后，达到同等基线即视为接入成功。
