## Why

后端 2026-11-22 上线了「陪跑员请求结束，跑者确认自己在安全的地方才完成」（blind-run-backend#902），由配置
`app.order.finish-blind-confirm-timeout-minutes` 开关，线上默认关。iOS 两端都没接（Jayden23018/blind-run-ios#1016）：
闸一打开，陪跑员点结束后页面卡在「状态还没确认」、到了可以单方面结束的时刻也按不动；跑者没有确认按钮，只能等超时。
所以闸现在不能开，跑步结束时「跑者是否已在安全的地方」这一步在线上是缺的。

## What Changes

- 订单详情接三个后端时刻：`finishRequestedAt`、`unilateralFinishOpensAt`、`sosWindowEndsAt`（只读后端值，客户端不自己加分钟数）。
- `POST /api/orders/{id}/finish` 读响应体的 `completed`：`false` = 只是请求，陪跑员页显示并朗读「已请对方确认是否在安全的地方」与最早可以单方面结束的时刻；到点前再按得到的 409 `BLIND_SAFETY_CONFIRMATION_PENDING` 朗读后端 message。
- 新端点 `POST /api/orders/{id}/confirm-safe`：跑者跑步页在 `finishRequestedAt` 非空时显示「我已在安全的地方，结束陪跑」，放在标题下第一张卡，出现时读屏焦点移过去。
- 实时事件 `FINISH_SAFETY_CONFIRM_REQUESTED`：按安全提醒呈现（全局横幅 + 朗读，不被生命周期抑制），并刷新订单。
- 请求作废（`finishRequestedAt` 回到 null）时两端回到普通跑步中。
- **求助红线的一处放宽**：完成后 `sosWindowEndsAt` 之前，跑者的求助仍走云端并挂在这一单上（契约原话「iOS 在 `IN_PROGRESS` 和这一刻之前都显示求助按钮」）。陪跑员不变，仍只在 `IN_PROGRESS`。
- Mock 后端镜像这道闸（默认关，与生产一致），可用环境变量或跑者端 Mock 面板打开。

不做：跑者回「还没到，继续陪我」、跑者主动请求结束（后端还没有接口）；布局给前者留了位置。

## Capabilities

### New Capabilities

- `finish-safety-confirmation`：结束前确认跑者安全的两端行为。

### Modified Capabilities

无（求助窗口的放宽写在新能力里，`AGENTS.md` §6 同步加一行）。

## Impact

- `blindRun/Core/Models/`、`Core/Services/OrderService.swift`、`Core/Endpoints/OrderEndpoint.swift`、Mock、实时事件分类。
- 陪跑员跑步页、跑者跑步页、`BlindHomeSOSMode.resolve`、`EmergencyCoordinator.trigger`。
- 闸关着时两端行为与改动前一致。
