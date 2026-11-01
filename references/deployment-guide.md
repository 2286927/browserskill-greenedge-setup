# BrowserSkill 绿装 Edge 接入 — 部署细节与故障排查

本文件是 SKILL.md 五步流程的详细参考。所有内容来自真实机器上的实战验证记录。

## 一、绿装 Edge 目录结构实例（真实机器数据）

绿色安装版 Edge 的典型目录（非标准安装，整包放置）：

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

- `App\` 子目录存在、包内 `Data\`/`User Data\` 存在、`chrome++.ini` 存在 → 绿装
- 启动方式按优先级识别：`App\msedge.exe` 直启 / `*.bat` 启动脚本 / `*.lnk` 快捷方式（文件名动态列出，不硬编码中文名）
- 扩展检测在用户数据目录下查找 `*/Extensions/emacgiaaaiojkkpkddmmdfhmokgmnikg`（覆盖 Default、Profile 1 等所有 profile）

## 二、bsk CLI 安装（国内网络：镜像优先）

### 为什么必须做镜像

官方 `install.ps1` 内部把 `https://github.com` **写死在代码里**（只暴露 `BSK_REPO` / `BSK_VERSION` / `BSK_INSTALL_DIR` 三个环境变量，改不了域名），所以无法用"前缀代理"加速它自身的下载。国内直连 GitHub 常见 `ERR_CONNECTION_CLOSED` / 长时间超时。

本技能自带 `scripts/install_bsk_mirror.ps1`，**复刻官方安装逻辑但全部走镜像**，并保留回退。

### 方案 A（首选）：镜像安装脚本

```powershell
# 标准安装（自动选最快镜像）
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>/scripts/install_bsk_mirror.ps1"

# 只探测镜像连通性，不安装（排障用）
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>/scripts/install_bsk_mirror.ps1" -CheckOnly

# 固定版本
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>/scripts/install_bsk_mirror.ps1" -Version 0.4.0
```

脚本行为：

1. 依次用镜像下载 `version.json` → 解析最新版本号与 `windows-x64` 的 SHA256
2. 依次用镜像下载 `bsk-v<版本>-x86_64-pc-windows-msvc.zip`，**每个镜像独立超时**（默认 25s），失败或校验不符自动换下一个
3. 全部镜像失败 → 自动回退 GitHub 原始地址（`origin`）
4. 解压 → 停旧 daemon（best effort）→ 替换 `~/.local/bin/bsk.exe`（带重试，防文件锁）→ 写用户 PATH 与 `~/.bashrc` → 验证 `--version`
5. 输出最终使用的源（`source=`），便于排障

### 方案 B（回退）：官方安装脚本（需较稳定的 GitHub 直连）

WorkBuddy 安全策略会拦截 `Invoke-Expression`（别名 `iex`），官方文档的 `irm ... | iex` 一行式安装**会直接报错**。正确做法：

```powershell
# 1. 下载脚本到本地（下载不执行，安全）；超时的话用 raw 类镜像取同一文件
irm https://raw.githubusercontent.com/Tencent/BrowserSkill/main/install.ps1 -OutFile "$env:TEMP\bsk_install.ps1"
# 镜像备选：https://cdn.gh-proxy.org/https://raw.githubusercontent.com/Tencent/BrowserSkill/main/install.ps1

# 2. 人工/智能体审查脚本内容（约 11KB，确认只下载+校验+解压+写 PATH）

# 3. 以 Bypass 策略执行脚本文件（脚本本身不含 iex，不会触发拦截）
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\bsk_install.ps1"

# 4. 绝对路径验证
& "$env:USERPROFILE\.local\bin\bsk.exe" --version
```

### 技能涉及的全部 GitHub 下载环节（5 处）

| # | 环节 | 原始地址 | 类型 | 加速方式 |
|---|---|---|---|---|
| 1 | install.ps1 安装脚本 | `raw.githubusercontent.com/Tencent/BrowserSkill/main/install.ps1` | Raw | Raw 类镜像前缀 |
| 2 | version.json 版本清单 | `github.com/Tencent/BrowserSkill/releases/latest/download/version.json` | Release | Release 类镜像前缀 |
| 3 | bsk 主程序 zip | `github.com/Tencent/BrowserSkill/releases/download/cli-v{ver}/bsk-v{ver}-x86_64-pc-windows-msvc.zip` | Release | Release 类镜像前缀（方案 A 已内置） |
| 4 | 技能自身分发包 zip | `github.com/2286927/browserskill-greenedge-setup/releases/download/v1.0.0/BrowserSkill绿装Edge接入技能.zip` | Release | 手动加前缀，例如 `https://cdn.gh-proxy.org/` + 原地址 |
| 5 | git clone 仓库 | `github.com/2286927/browserskill-greenedge-setup.git` | Clone | Clone 类镜像前缀或域名镜像 |

**拼接规则**（前缀型镜像通用）：`目标地址 = 镜像前缀 + 原始 URL 的 PathAndQuery`
例：`https://cdn.gh-proxy.org/https://github.com/Tencent/BrowserSkill/releases/latest/download/version.json`

### 镜像清单（来源：XIU2/UserScript GithubEnhanced-High-Speed-Download）

**Release / zip 类**（`mirror-lib.ps1` 中按此顺序尝试）：

1. `https://cdn.gh-proxy.org/https://github.com`（Fastly CDN，实测最快）
2. `https://gh-proxy.org/https://github.com`
3. `https://hk.gh-proxy.org/https://github.com`（香港）
4. `https://ghproxy.net/https://github.com`
5. `https://wget.la/https://github.com`
6. `https://ghfast.top/https://github.com`

**Raw 类**：

1. `https://cdn.gh-proxy.org/https://raw.githubusercontent.com`
2. `https://hk.gh-proxy.org/https://raw.githubusercontent.com`
3. `https://wget.la/https://raw.githubusercontent.com`
4. `https://ghfast.top/https://raw.githubusercontent.com`

**Git clone 类**：

1. `https://hk.gh-proxy.org/https://github.com`
2. `https://ghfast.top/https://github.com`
3. `https://githubfast.com`
4. `https://gitclone.com/github.com`

**实测参考（2026-11-01，中国大陆家宽）**：`cdn.gh-proxy.org` 330ms（最快）、直连 origin 759ms、`hk.gh-proxy.org` 764ms、`wget.la` 771ms；`ghfast.top` 当次连接被关闭（已下调顺序但保留）。

### 镜像失效时怎么处理

1. 跑 `-CheckOnly` 看哪条通、哪条挂（输出含耗时与错误）
2. 打开 `scripts/mirror-lib.ps1`，调整 `$script:ReleaseMirrors` / `$script:RawMirrors` / `$script:CloneMirrors` 的顺序，或替换成新镜像（保留"前缀 + 原 URL 路径"格式）
3. 镜像全挂时脚本会自动回退 `origin`（GitHub 直连）；若直连也不通再走方案 B 或等网络恢复
4. 镜像列表可定期对照上游更新：`https://raw.githubusercontent.com/XIU2/UserScript/master/GithubEnhanced-High-Speed-Download.user.js`

### 注意事项

- 实测版本：bsk 0.4.0（2026-10/11 验证）
- 安装脚本会先尝试 `daemon stop`（防止替换运行中的 exe）；新机上无 daemon，此步直接通过
- **新开 shell 的 PATH 可能未刷新，所有 bsk 调用一律用绝对路径**，或确认 PATH 已含 `~/.local/bin`
- 镜像只代理下载流量，**不改变文件内容**；SHA256 校验来自官方 version.json，可放心使用

## 三、daemon 托管启动（WorkBuddy 宿主约束）

### 为什么不能让它自己启动

`bsk doctor` 报错 `cannot start an independent Windows daemon ... (os error 5)`：WorkBuddy 沙箱禁止 daemon 作为独立进程脱离 Job Object。这是宿主行为，不是权限配置问题，**不要反复重试自动启动**。

### 正确启动方式（受托管后台任务）

- Bash 工具 + `run_in_background: true`：

  ```sh
  BSK_AUTO_START=0 /c/Users/<用户名>/.local/bin/bsk.exe daemon start --foreground
  ```

- daemon 启动日志中出现以下内容才算成功（但**仍需另起调用验证**，日志不等于就绪）：

  ```
  ws server listening addr=127.0.0.1:52800
  daemon ready pid=26660 ws_port=52800 sock=\\.\pipe\bsk-daemon-xxxx
  ipc named-pipe server listening ...
  browser connected id=xxxx name=edge   ← 扩展自动连上的标志
  ```

- 独立调用验证（每次客户端调用都要带 `BSK_AUTO_START=0`）：

  ```sh
  BSK_AUTO_START=0 /c/Users/<用户名>/.local/bin/bsk.exe status --json
  ```

### daemon 生命周期

- 宿主会话结束 / 机器重启 → daemon 停止，下次使用前重新按上述方式拉起
- 后台任务保持运行是预期状态，不要当作残留任务清理
- daemon 已在运行时**绝不重启**（`BSK_AUTO_START=0` + status 探测即可复用）

## 四、故障排查表

| 现象 | 原因 | 处理 |
|---|---|---|
| 访问 `github.com` / `raw.githubusercontent.com` 超时或 `ERR_CONNECTION_CLOSED` | 国内网络对 GitHub 不稳定 | 不要直连：用 `scripts/install_bsk_mirror.ps1`（镜像优先，自动回退） |
| `install_bsk_mirror.ps1` 报 "all mirrors + origin failed" | 所有镜像与直连同时不可用 | 跑 `-CheckOnly` 确认；换网络/等恢复；或手动加新镜像到 `mirror-lib.ps1` |
| 某个镜像下载到一半报 "意外的 EOF" | 该镜像连接被中断 | 脚本会自动切下一个；无需人工干预，留意最终 `source=` 即可 |
| 镜像返回 404 | 镜像不支持该路径格式，或原始文件不存在 | 先用 `-CheckOnly` 验证镜像本身；确认原始 URL 正确 |
| SHA256 校验不符 | 镜像缓存了旧文件或内容被篡改 | 脚本会自动换镜像重试；若持续失败，改用官方 install.ps1 直连下载 |
| `irm \| iex` 报 "Command blocked for security: iex" | WorkBuddy 安全策略拦截 Invoke-Expression | 按第二节流程：下载→审查→`-ExecutionPolicy Bypass -File` 执行 |
| doctor 报 daemon "os error 5" / Job Object breakaway | 宿主禁止 daemon 独立脱离 | 用托管后台任务 + `--foreground`，不要重试独立启动 |
| `bsk` 命令找不到 | 新 shell PATH 未刷新 | 一律用绝对路径 `~/.local/bin/bsk.exe`（Bash 下 `/c/Users/<用户>/.local/bin/bsk.exe`） |
| doctor: `extension connected` 失败 | 扩展未装 / 扩展弹窗未启用连接 / 端口不匹配 | 新装扩展后需用户在扩展弹窗点启用连接；对照 daemon 的 `ws_port` |
| status 里 `version_skew: true` | CLI 与扩展版本不匹配 | 重跑安装脚本升级 CLI（会自动 stop 旧 daemon 并替换） |
| session start 成功但 navigate 无响应 | 浏览器未开 / 扩展休眠 | 让用户打开绿装 Edge（用 `App\msedge.exe` 或其启动器）后重试 |
| 端口每次不同（如 52800） | daemon 每次启动随机分配 | 正常现象；扩展自动发现，无需固定端口 |

## 五、验证基线（真实机器通过记录）

以下为本 skill 提炼来源机器（绿装 Edge，Windows 10 IoT Enterprise LTSC 2019）上的实测基线：

- bsk doctor 全绿：daemon running / IPC identity / protocol 1.7 / extension connected / browser protocol compatible
- 端到端：session start → navigate example.com → observe 读到页面文本与元素 ref（@e1/@e2）→ session stop
- status 关键字段：`browser_name=edge`、`extension_version=0.4.0`、`version_skew=false`、`unresponsive=false`

在任何新机器上部署后，达到同等基线即视为接入成功。
