## Why

语音下单 2026-11-23 永久下线（负责人定），iOS 里 `VoiceOrderWizard` 已没有界面入口。App Store Connect 的 App 合规页「人工智能生成或合成内容」按此答了「否」。可是「关于」页仍公示「语音下单使用的大模型：通义千问」，首启告知、内置隐私说明和「隐私与授权」页也还在讲语音下单把文字发给通义千问。审核员一对就是申报和实际不一致（审核指南 2.3：元数据要准确反映 App 的核心体验）。

另一面，语音听写仍在用（留言、跑后反馈、客服工单、举报），它走苹果的语音识别服务，这件事首启告知没有写。

## What Changes

- 「关于」页删掉「大模型公示」一组。
- 「隐私与授权」第一层从三项变成两项：视力状况与导盲犬、陪跑位置。语音下单那一行去掉。
- 首启告知：语音下单那一条换成语音输入那一条（经苹果语音识别转文字，我们只收到文字）；`appLaunch` 的 `disclosureVersion` 4 → 5。首屏摘要同步。
- 内置隐私说明：麦克风一条改成语音输入；「第三方 SDK」一节删掉通义千问那句；「你的选择」里麦克风那句改成关掉后不能语音输入、仍可打字。
- 首页预约按钮的读屏提示不再说「进入语音下单」；设置页「隐私与授权」入口的读屏提示改成两项。
- `Info.plist` 麦克风和语音识别的用途说明改成留言、反馈、举报的语音输入。

不改：`VoiceOrderWizard`、语音下单单独同意的代码和它的规格（入口已没有，代码留着，等以后决定删不删）。

## Impact

- 代码：`AboutAppSections.swift`、`AboutAidRunView.swift`、`PrivacyAuthorizationView.swift`、`PrivacyConsent.swift`、`LegalLinksModels.swift`、`BlindHomeCards.swift`、`BlindAccountView.swift`、`Info.plist`。
- 测试：`PrivacyConsentTests`（#374 三处点名通义千问那条改成三处都不再点名；指纹与版本号）、两份隐私授权 UI 测试、关于页读屏审计。
- 老用户：首启告知 v5 会让已同意 v4 的用户冷启动时再同意一次。App 还没正式上架，只影响 TestFlight 测试员。
