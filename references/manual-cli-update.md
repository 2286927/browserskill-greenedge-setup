# 手动更新 bsk CLI（不依赖技能脚本）

技能默认就会装**最新版**，正常情况下不需要看这里。本文用于：脚本因完整性策略拒绝、网络环境特殊、想装指定版本、或想完全不跑脚本。

> 判断是否需要升级：浏览器扩展弹窗提示「扩展协议 v1.8，CLI 协议 v1.7，协议版本不同」，或 `status --json` 里 `version_skew: true`。

## 第 0 步：先看官方最新版本号

```powershell
# PowerShell（会自动读取 http_proxy/https_proxy，沙箱与公司代理下都可用）
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:https_proxy; $a=@{Uri='https://github.com/Tencent/BrowserSkill/releases/latest/download/version.json';UseBasicParsing=$true}; if($p){$a.Proxy=$p}; (Invoke-WebRequest @a).Content"
```

```sh
# Bash / curl（国内直连不通时把域名换成镜像前缀）
curl -s https://github.com/Tencent/BrowserSkill/releases/latest/download/version.json
curl -s https://gh-proxy.org/https://github.com/Tencent/BrowserSkill/releases/latest/download/version.json
```

记下返回里的 `version`（如 `0.4.1`）和 `assets."windows-x64".sha256`。

## 方式一：跑技能自带脚本（推荐，一条命令）

```powershell
# 升到最新（官方直连优先，失败自动回退镜像）
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\install_bsk.ps1"

# 指定版本
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\install_bsk.ps1" -Version 0.4.1

# 只走官方直连（不信任任何镜像）
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill目录>\scripts\install_bsk.ps1" -DirectOnly
```

脚本会自动：解析最新版本 → 多渠道核对校验值 → 下载并校验 SHA256 → 停旧 daemon → 替换 `%USERPROFILE%\.local\bin\bsk.exe` → 写 PATH/`.bashrc` → 只执行 `bsk --version`。

## 方式二：纯手动替换（最可控，不跑任何安装脚本）

适合脚本被完整性策略挡住，或你想自己盯每一步。

```powershell
# 1) 准备变量（把 0.4.1 换成你要的版本）
$ver = "0.4.1"
$zipUrl  = "https://github.com/Tencent/BrowserSkill/releases/download/cli-v$ver/bsk-v$ver-x86_64-pc-windows-msvc.zip"
$expect  = "<从第 0 步拿到的 sha256>"
$work    = Join-Path $env:TEMP "bsk-manual-$ver"
New-Item -ItemType Directory -Path $work -Force | Out-Null

# 2) 下载（直连不通就把 URL 换成 https://gh-proxy.org/<原 URL>）
$p = $env:https_proxy
$a = @{ Uri = $zipUrl; OutFile = "$work\bsk.zip"; UseBasicParsing = $true }
if ($p) { $a.Proxy = $p }
Invoke-WebRequest @a

# 3) 校验（必须与期望值一致，不一致就停手）
(Get-FileHash "$work\bsk.zip" -Algorithm SHA256).Hash -ieq $expect
```

```powershell
# 4) 停 daemon（不存在时报错可忽略）
& "$env:USERPROFILE\.local\bin\bsk.exe" daemon stop

# 5) 解压并覆盖
Add-Type -AssemblyName System.IO.Compression.FileSystem
Expand-Archive -LiteralPath "$work\bsk.zip" -DestinationPath "$work\x" -Force
New-Item -ItemType Directory -Path "$env:USERPROFILE\.local\bin" -Force | Out-Null
Copy-Item "$work\x\bsk.exe" "$env:USERPROFILE\.local\bin\bsk.exe" -Force

# 6) 验证
& "$env:USERPROFILE\.local\bin\bsk.exe" --version
```

如果第 5 步报「文件被占用」，说明 daemon 还在跑：`taskkill /IM bsk.exe /F`（会中断正在进行的浏览器会话），再重试覆盖。

## 方式三：官方安装脚本（不推荐，但可用）

```powershell
# 1) 下载（不执行）
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Tencent/BrowserSkill/main/install.ps1" -OutFile "$env:TEMP\bsk_install.ps1"

# 2) 打开看一遍，确认只做：下载 → 校验 → 解压 → 写 PATH

# 3) 执行
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\bsk_install.ps1"
```

**禁止** `irm ... | iex` 一行式执行：不可预审，WorkBuddy 安全策略也会拦截。

## 更新后必做的三步确认

```sh
# 1) 起 daemon（WorkBuddy 下必须用托管后台任务）
BSK_AUTO_START=0 /c/Users/<用户名>/.local/bin/bsk.exe daemon start --foreground   # run_in_background: true

# 2) 独立调用验证
BSK_AUTO_START=0 /c/Users/<用户名>/.local/bin/bsk.exe status --json
```

核对 `status --json`：`protocol_version` 与扩展 `extension_protocol_version` 相同、`version_skew: false`、`unresponsive: false`。

```powershell
# 3) 体检
& "$env:USERPROFILE\.local\bin\bsk.exe" doctor
```

## 装回旧版本（回滚）

同一套流程，把 `$ver` 换成旧版本号即可（0.4.0 仍可从 releases 下载）。回滚后若扩展提示协议不兼容（`version_skew: true`），说明扩展比 CLI 新——优先升级 CLI，而不是降级扩展。

## 常见情况速查

| 情况 | 处理 |
|---|---|
| 脚本报 `channels disagree on the SHA256` | 有渠道数据不一致，属安全拦截：换 `-DirectOnly` 直连重试，或等镜像缓存刷新 |
| 脚本报 `only one proxy channel ... reported a value` | 只连上了一个镜像，脚本不敢单一来源采信：再试一次（换到能连通两个镜像的网络），或 `-DirectOnly`，或用手动方式二自行核对哈希 |
| 下载报「基础连接已经关闭: 发送时发生错误」 | PS 5.1 的 IWR 不读 `http_proxy`：脚本已自动带代理，手动命令请加 `-Proxy $env:https_proxy` |
| 替换时报文件被占用 | 先 `daemon stop`；仍占用则 `taskkill /IM bsk.exe /F` 后重试 |
| 更新后扩展显示未连接 | 打开绿装 Edge，在扩展弹窗点「启用连接」，端口对齐 `status` 的 `ws_port` |
