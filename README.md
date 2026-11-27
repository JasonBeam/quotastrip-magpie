# QuotaStrip · 触控栏用量条

把带 Touch Bar 的 MacBook Pro 变成 Codex 和 AI 用量的实时仪表盘。触控栏常驻额度条，菜单栏面板下钻到 DeepSeek 余额、Token Plan Credits、各供应商与模型消耗，以及完整的 Magpie 用量热力图。

面向 Codex 桌面端和本地 [Magpie](https://github.com/yetone/magpie) 网关的个人分支，基于 [hohocf/QuotaStrip](https://github.com/hohocf/QuotaStrip) 继续开发。

📦 [下载安装](#安装下载) · 📖 [功能介绍](#功能介绍) · 🖥️ [界面预览](#界面预览) · 🔗 [数据来源](#数据来源) · ✨ [让 AI 帮你上手](#让-ai-帮你上手)

> 需要一台**带物理触控栏**的 MacBook Pro。应用通过私有 `DFRFoundation` API 控制触控栏，未上架 Mac App Store、未经过 Apple 公证，首次启动需手动确认。

## 选一种使用方式

| 你想做什么 | 从这里开始 |
| --- | --- |
| 只想在触控栏看 Codex 额度 | [下载安装](#安装下载)，装好打开即用 |
| 想看更完整的用量面板 | 点菜单栏 QuotaStrip 图标 |
| 想把 Magpie 的实时用量接进来 | 先本地运行 Magpie，再装本应用（可选） |
| 想用 DeepSeek 余额 | 在面板填入官方 API Key（存钥匙串） |
| 不熟悉配置，想让 AI 带着操作 | [AI 上手](#让-ai-帮你上手) |

## 功能介绍

- **触控栏额度条**：常驻显示 Codex 5 小时和 7 天**剩余额度**。
- **Magpie 实时模块**：Token Plan 剩余百分比、今日 Token、当前模型、缓存命中率、输出速度。
- **Kimi Code 额度**：Magpie 提供有效额度桶时显示对应剩余窗口。
- **菜单栏面板**：DeepSeek 余额、Token Plan Credits、各供应商和模型消耗、Kimi 额度、完整用量热力图。
- **热力图交互**：鼠标扫过日期方块时，在方块附近显示当天日期、星期和 Token 数量，边缘自动防裁切。
- **系统联动**：Codex/ChatGPT 启动显示触控栏，完全退出隐藏；唤醒后自动重查。
- **颜色分级**：剩余额度 >50% 绿色、21–50% 黄色、≤20% 红色。

## 界面预览

![QuotaStrip 显示在 Touch Bar 上](docs/touchbar-magpie.png)

<details>
<summary>查看完整触控栏与菜单栏面板截图</summary>

![完整触控栏布局](docs/touchbar-full.png)

![菜单栏用量面板](docs/screenshot.png)

</details>

## 安装下载

### 安装前准备

- 一台带物理触控栏的 MacBook Pro。
- macOS 11 或更高版本；开机自启需要 macOS 13 或更高版本。
- 实时 Codex 额度需要位于 `/Applications/ChatGPT.app` 的 ChatGPT/Codex 桌面端；读取失败会回退到 Codex app-server 和 `~/.codex/sessions`。
- Magpie 为可选依赖。未运行 Magpie 时，Codex 仍有回退数据源，Magpie 专属卡片显示暂无数据。

### 安装步骤

1. 从 [Releases](https://github.com/JasonBeam/quotastrip-magpie/releases) 下载 `QuotaStrip.zip` 和 `SHA256SUMS.txt`。
2. 校验压缩包：

   ```bash
   shasum -a 256 QuotaStrip.zip
   ```

3. 解压后把 `QuotaStrip.app` 拖入 `/Applications`。
4. 退出旧版 QuotaStrip，首次启动时按住 Control 点击应用并选择「打开」，以接受未公证签名。
5. 如果触控栏被其他应用占用，点击菜单栏 QuotaStrip 图标，选择「重新显示 Touch Bar」。

不需要辅助功能权限，不安装 Claude hooks，不修改 Codex 配置，也不会安装 LaunchAgent。你可以在 QuotaStrip 菜单里按需把它设为登录项。

## 让 AI 帮你上手

可以先复制这一段：

```text
我想使用 QuotaStrip（Mac 触控栏 AI 用量条）：
https://github.com/JasonBeam/quotastrip-magpie
请先阅读当前 README 和 docs/releases。
我的机器是【填写 MacBook Pro 型号和 macOS 版本】，是否带物理触控栏【是/否】。
我想接【只要 Codex 额度 / 同时接 Magpie / 再加 DeepSeek 余额】。
请先确认我的机型和系统是否满足条件，再给我逐步安装和排错步骤。
不要索取或读取我的 API Key、Keychain、Codex 会话文件或 Magpie 配置。
每一步说明操作位置、预期结果；没有真实验证的步骤请明确标注。
```

AI 是可选的操作助手，不能替代物理触控栏验证，也不能保证第三方接口（Codex / Magpie / 各供应商）长期稳定。

## 注意事项

- **仅适用于带触控栏的 MacBook Pro**：无触控栏的 Mac 无法显示额度条。
- **未上架、未公证**：首次启动需要 Control 点击 → 打开。
- **触控栏使用私有 API**：未来 macOS 更新可能改变行为。
- **Magpie 卡片依赖本机服务**：未运行 Magpie 时对应数据不可用。
- **数值取决于上游接口**：供应商修改接口后，对应行可能暂时显示暂无数据；未知值不会伪造为 100%。
- **隐私**：只读本机 Codex 会话和 Magpie 本机接口，不修改 `~/.codex/config.toml`，不注入记忆，不上传对话内容；可选的供应商 Key 仅存 macOS 钥匙串。

## 验证到哪一步

- 通用二进制构建、签名，以及面板 / Magpie / 组合逻辑测试已验证。
- 已在维护者的触控栏 Mac 上实机查看额度条和菜单栏面板交互。
- 物理触控栏布局、开机自启和不同 macOS 版本下的表现，仍需下载者按自己的设备复核。
- 第三方数据（Codex、Magpie、DeepSeek、Kimi）依赖各自接口，接口变化会影响显示。

## 数据来源

- **Codex 额度**：优先 Magpie 本机只读接口；失败回退 Codex app-server 的 `account/rateLimits/read` 和 `~/.codex/sessions`。只使用 `codex` 额度桶。
- **Magpie 用量**：Magpie 本机接口及只读缓存 / 历史文件。
- **DeepSeek 余额**：仅在用户主动把 API Key 存进 macOS 钥匙串后，查询官方余额接口。

界面每 20 秒刷新一次，请求串行执行并使用缓存，避免重叠刷新。缺少可靠数据时显示「暂无数据」，不会把未知值伪造成 100%。

## 从源码构建

```bash
git clone https://github.com/JasonBeam/quotastrip-magpie.git
cd quotastrip-magpie
./build.sh
```

构建需要 Xcode 和命令行工具。完成后会在 `/tmp/QuotaStrip.app` 生成 Intel + Apple Silicon 通用应用。

## 许可与致谢

本项目基于 [hohocf/QuotaStrip](https://github.com/hohocf/QuotaStrip)，沿用 MIT License。产品名称和图标归各自权利人所有，仅用于标识数据来源。
