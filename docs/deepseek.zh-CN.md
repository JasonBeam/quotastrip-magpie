# Codex + DeepSeek 双额度面板

当前版本在 Touch Bar 并排显示两种不同类型的额度：

- **Codex**：保留现有的 5 小时、7 天剩余额度百分比及重置时间。优先读取 Magpie 本机额度视图，失败后回退 Codex app-server 和本地会话日志。
- **DeepSeek**：使用官方 `GET https://api.deepseek.com/user/balance` 查询 **API 账户余额**（CNY / USD）。不是网页聊天额度，也不是 5h / 7d 百分比。模型、Search 和 Fetch 的消费会反映在账户余额里，不会调用收费搜索来估算额度。

官方接口说明：https://api-docs.deepseek.com/zh-cn/api/get-user-balance

## 设置

1. 构建并运行：`./build.sh --run`。
2. 点菜单栏的 QuotaStrip 仪表图标 → **设置 DeepSeek API Key…**。
3. 在本机密码输入框粘贴 DeepSeek 平台 API Key，保存。
4. Touch Bar 会显示 `DeepSeek` 和实际币种余额。点击 DeepSeek 面板可打开平台用量页。
5. 菜单里的 **DeepSeek 余额详情** 可查看充值余额、赠送余额、可用状态和刷新错误。

API Key 仅保存到 macOS 钥匙串（服务 `app.quotastrip.deepseek`，账户 `api-key`），不写入源码、配置文件或日志；不读取其他应用的密钥。需要更换时重新设置；**移除 DeepSeek API Key…** 只删除本机保存项，不会撤销平台密钥。

## 刷新与错误

- UI 每 20 秒刷新；DeepSeek 成功结果缓存 60 秒，避免每次 UI 刷新都发请求。
- **立即刷新**可跳过正常缓存，但仍遵守限流和服务错误冷却时间。
- 网络或接口失败时，保留上一笔成功余额，并显示黄色标记与“旧值”；没有成功数据时显示错误，不伪造 0 元。
- 余额不可用于 API 调用时以红色显示；非常小的正余额显示 `<0.01`，不会四舍五入伪装成 0。
- 已设置 DeepSeek Key 时，不依赖 Codex 是否正在运行，面板都可展示；未设置时保留原有的 Codex 启停联动。
- 右侧系统 Control Strip 保持不变。Touch Bar 使用私有 API，实际布局仍需在带 Touch Bar 的 Mac 上确认。

## 构建与安装

`./build.sh` 输出 `/tmp/QuotaStrip.app`（Intel + Apple Silicon 通用构建，ad-hoc 签名）。
如果应用程序文件夹已有旧版，先退出旧版、备份，再用新构建替换。仅运行临时构建不会自动更新应用程序文件夹中的旧版。重建签名后，macOS 可能重新请求钥匙串访问许可。

完整安装、数据来源和已知限制以主 README 为准。
