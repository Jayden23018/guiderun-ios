## Why

负责人 2026-11-25 真机反馈：陪跑员确认求助后，「求助中 · 回到警报」红条一直挂在页面上，消失不了。原因有两个：
- 后端在求助结束时（跑者撤销、客服结案）不给陪跑员推任何事件。
- iOS 只在回到前台和 WebSocket 重连时才问一次 `GET /api/emergency/active`（`AppState.recoverActiveEmergency`）。App 一直开着，就永远不会再问。

Mock 里同样如此：陪跑员端的警报没有任何结束的路径。

## What Changes

- 警报（整屏或红条）显示期间，每 20 秒问一次 `GET /api/emergency/active`。查到没有未结束的事件，就收起警报。没有警报时不发请求。回前台时立刻问一次，这一点原本就有。
- 警报挂着的那一单收到状态推送时：
  - 进入「已取消」「暂无陪跑员」，或回到「匹配中 / 重新匹配」（陪跑员已不在这一单上），立刻收起警报。
  - 进入「已完成」时，立刻问一次后端，不在本地直接收起。理由：完成后 `sosWindowEndsAt` 之前，跑者仍能求助（#1016），本地不能据「已完成」判断求助已经结束。
- 警报收起时朗读一句「求助提醒已收起：这次求助已结束，或这一单已不由你陪跑。」，不悄悄消失。退出登录时不念。
- 不加手动关闭：陪跑员不能撤销跑者的求助（后端 403 `EMERGENCY_VOLUNTEER_CANNOT_DISMISS`）。
- 只改 iOS。后端给陪跑员推「求助已结束」事件的工作在后端另有卡，做好后这里的轮询可以退成兜底。

## Impact

- `blindRun/Safety/EmergencyCoordinator+VolunteerAlertLifecycle.swift`（新增）、`VolunteerGlobalEmergencyAlert.swift`。
- 契约用法：只多调用已有端点 `GET /api/emergency/active`，不新增端点。
- 测试：单测 `VolunteerAlertLifecycleTests`；真机走查加一条「求助结束后红条收起」。
