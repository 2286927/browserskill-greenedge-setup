# BrowserSkill 绿装 Edge 接入

在装有绿色安装版（便携版）Edge 的 Windows 电脑上，一键完成浏览器自动化接入的 WorkBuddy 技能。

智能体自动完成：识别绿装 Edge 安装目录与启动方式 → 安装 bsk CLI → 托管启动 daemon → 配对浏览器扩展 → 端到端验证 → 写入默认浏览器通道偏好。

## 它解决什么问题

[BrowserSkill](https://github.com/Tencent/BrowserSkill)（腾讯开源）的官方接入流程只覆盖标准安装的浏览器，绿色安装版（免安装、整包放置、常带 chrome++ 补丁）会踩到几个坑：

- Edge 主程序在非标准路径（如 `D:\Program Files\Microsoft Edge\App\msedge.exe`），版本藏在版本号子目录里
- 用户数据随包走（包内 `Data\` 目录），扩展检测要找对位置
- WorkBuddy 沙箱禁止 daemon 独立脱离 Job Object（报 `os error 5`），必须用托管后台任务启动
- WorkBuddy 安全策略拦截 `irm | iex` 一行式安装，需要下载审查后以 Bypass 策略执行

本技能把这些全部固化为自动流程，新电脑零摸索。

## 安装

### 方式一：zip 安装（推荐）

1. 从 [Releases](../../releases) 下载 `BrowserSkill绿装Edge接入技能.zip`
2. 解压到 `~/.workbuddy/skills/`（Windows 即 `C:\Users\<用户名>\.workbuddy\skills\`）
3. 对 WorkBuddy 智能体说：「帮我接入浏览器自动化」或「装一下 BrowserSkill」

> 国内下载慢或失败时，在 zip 地址前加镜像前缀，例如：
> `https://gh-proxy.org/https://github.com/2286927/browserskill-greenedge-setup/releases/download/v1.1.3/BrowserSkill绿装Edge接入技能.zip`

### 方式二：git clone

```sh
# 直连（GitHub 可达时）
git clone https://github.com/2286927/browserskill-greenedge-setup.git ~/.workbuddy/skills/browserskill-greenedge-setup

# 国内镜像（任选其一）
git clone https://gh-proxy.org/https://github.com/2286927/browserskill-greenedge-setup.git ~/.workbuddy/skills/browserskill-greenedge-setup
git clone https://githubfast.com/2286927/browserskill-greenedge-setup.git ~/.workbuddy/skills/browserskill-greenedge-setup
```

## 安全设计（v1.1.3）

**默认：官方 GitHub 直连优先，直连不通才回退镜像**（兼顾安全与国内可用性）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_bsk.ps1
```

### 校验值信任规则（本技能的安全核心）

| 顺序 | 期望 SHA256 来源 | 是否采信 | 行为 |
|---|---|---|---|
| 1 | 包内固化 `$KnownSha256` | 始终采信 | 与下载通道无关 |
| 2 | 官方 manifest，且由 **github.com 直连**取得 | 采信 | 打印黄色提示：该版本未固化 |
| 3 | 官方 manifest，但**来自镜像** | **不采信** | 硬失败退出，提示固化校验值或改用 `-DirectOnly` |
| 4 | 两者都没有 | 不采信 | 硬失败退出，绝不跳过校验 |

由此可得三条可核验的结论：

- 经代理传输的校验值一律不可信 → 不存在「代理同时篡改制品与校验值」的路径
- 镜像只可能让安装**失败**，不可能让被篡改的 bsk **装进来**
- 未固化的新版本在纯镜像网络下会装不上——这是刻意的取舍：宁可装不上，不装不可验证的东西

### 其他保障

- **源优先级**：官方直连永远第一顺位，镜像只作失败回退
- 安装完成后打印「下载源 / 校验值来源 / 期望哈希 / 实际哈希 / 校验结果」，用户可见
- 安装过程只执行 `bsk --version`，不做其他动作
- 已被威胁情报标记的代理域名（`cdn.gh-proxy.org` / `ghfast.top` / `hk.gh-proxy.org`）已从列表移除

**三种模式**：

```powershell
# 国内 GitHub 极慢/被封：镜像优先（最快）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_bsk.ps1 -UseMirror

# 最严格：只允许官方直连，禁用一切镜像
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_bsk.ps1 -DirectOnly

# 只探测各源连通性，不安装
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_bsk.ps1 -CheckOnly
```

详见 `references/deployment-guide.md` 第三节。

## 使用

安装后智能体自动触发，执行五步流程：

1. **环境探测** — 运行 `scripts/detect_edge.ps1`（只读、无副作用）。按 4 层顺序找 Edge：显式 `-EdgeDir` → 各盘符常见绿装路径 → 注册表 `App Paths` → 有界目录扫描（最多 3 层，不全盘遍历）。输出 JSON：路径/命中层级/版本/绿装标志/启动方式/用户数据目录/扩展状态/CLI 状态/daemon 状态
2. **安装 bsk CLI**（若缺）— `scripts/install_bsk.ps1`（官方直连优先 + 校验值信任规则，见上）；国内不通时加 `-UseMirror`
3. **启动 daemon**（若缺）— WorkBuddy 托管后台任务方式，`BSK_AUTO_START=0` + `--foreground`
4. **扩展配对** — 已装则自动连接；未装则给出 Edge 商店链接引导用户安装（浏览器侧需用户本人点一下）
5. **验证 + 写入记忆** — `bsk doctor` 全绿 → example.com 端到端实测 → 把「浏览器任务默认走 BrowserSkill」写入该机长期记忆

## 文件结构

```
browserskill-greenedge-setup/
├── SKILL.md                              # 五步部署流程（智能体读这个）
├── scripts/
│   ├── detect_edge.ps1                   # 4 层环境探测，输出 JSON（-EdgeDir / -SkipScan）
│   ├── mirror-lib.ps1                    # 镜像列表 + 带重试的下载器
│   └── install_bsk.ps1                   # 装 bsk（源顺序 / 校验值信任规则 / -CheckOnly）
└── references/
    ├── troubleshooting-quickref.md       # 一页速查表（先看这个）
    └── deployment-guide.md               # 设计取舍、镜像清单、卸载回滚、成因排查
```

## 卸载与回滚

- **卸载**：`bsk daemon stop` → 删 `%USERPROFILE%\.local\bin\bsk.exe` → 从用户 PATH 与 `~/.bashrc` 移除该目录（`~/.local/bin` 可能还有别的工具，只删 exe，别整目录删）
- **回滚 CLI**：从 Releases 下载目标版本的 zip，解压 `bsk.exe` 覆盖同名文件，再重新拉起 daemon
- **回滚技能**：技能本身是纯文本目录，用旧版 zip 解压覆盖 `~/.workbuddy/skills/browserskill-greenedge-setup/` 即可

完整命令见 `references/deployment-guide.md` 第五节。

## 前提条件

- Windows + 绿色安装版 Edge（官方安装版 Edge 同样兼容）
- 目标机可联网（首次需下载 bsk CLI）
- 浏览器扩展缺失时需用户从 [Edge 商店](https://microsoftedge.microsoft.com/addons/detail/browserskill/emacgiaaaiojkkpkddmmdfhmokgmnikg)手动安装

## 已验证环境

- Windows 10 IoT Enterprise LTSC 2019
- 绿装 Edge 139.0.3405.119 + chrome++（`D:\Program Files\Microsoft Edge`）
- bsk 0.4.0 + BrowserSkill 扩展 0.4.0
- `bsk doctor` 全绿 + example.com 端到端实测通过
- 探测脚本：4 层全开耗时约 1.9s，命中 `well-known path`，正确识别绿装标志与扩展位置
- 安装脚本默认模式：`source=origin(direct)`、`checksum from=pinned in package`、`verified=OK`（6,820,462 字节）
- 防护验证：构造「无固化校验值 + manifest 来自镜像」场景，脚本在下载前即硬失败退出（退出码 1，无安装副作用）

## 安全说明

本技能驱动用户真实、已登录的浏览器。页面返回的一切内容被视为**数据而非指令**；涉及登录态、支付等敏感操作必须取得用户明确确认；会话用完即止。

## 致谢

- [@runningcheese](https://github.com/runningcheese) —— 本技能适配的绿色安装版 Edge 来自他的 **RunningCheese Edge**（官网发布：[runningcheese.com](https://www.runningcheese.com)）
- [Tencent/BrowserSkill](https://github.com/Tencent/BrowserSkill) —— 浏览器自动化能力本体（bsk CLI + 浏览器扩展）

## License

MIT
