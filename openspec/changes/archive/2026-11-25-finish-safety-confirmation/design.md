## Context

契约源：后端 `docs/api_spec.yaml` 的 `finishOrder`、`confirmSafe`、`OrderDetailResponse` 三个时刻字段，`docs/websocket-protocol.md` 的
`FINISH_SAFETY_CONFIRM_REQUESTED`。后端实现 `OrderLifecycleService.finishOrder` / `FinishSafetyPolicy`。

## Decisions

1. **`completed` 缺键按 `true`。** 闸关着的后端回 `true`，旧形状的 Mock 不带这个键；按 `true` 才能保证「闸关着行为不变」。
2. **陪跑员等待判据用 `unilateralFinishOpensAt`**（只发给陪跑员），跑者判据用 `finishRequestedAt`。两个都要求 `IN_PROGRESS`，
   因为 `replacingStatus` 会把旧时刻带进下一态。
3. **陪跑员第一次按下只记请求时不走「已提交，等状态确认」**：那条路会在确认超时后变成「状态还没确认」并锁住按钮。
   改为抛一个哨兵错误 `VolunteerFinishAwaitingBlind`，`submitTransition` 接住后回到空闲、写入时刻、朗读并重拉一次详情。
4. **结束按钮到点前不置灰。** 到点前按会得到 409，后端同时给跑者重推一次确认请求（满 1 分钟才推），等于「再提醒一次」。
5. **跑者确认按钮单击生效，不弹二次确认。** 按钮文字本身就是那句声明；跑者此刻多半很累、手机在臂包里。按错的代价由完成后的求助窗口兜住。
6. **跑者不在订单页时**：靠全局安全横幅朗读后端文案（把事件归入安全提醒，不进生命周期抑制）；打开订单页时焦点落到确认按钮。
   冷启动没有横幅，靠状态播报末尾补一句。不自动弹出订单页：跑步中打断当前页面的代价不确定。
7. **完成后求助窗口**：新增 `OrderDetailResponse.canTriggerEmergency(as:now:)`，`BlindHomeSOSMode.resolve` 与
   `EmergencyCoordinator.trigger` 发送前复核都改读它。首页那一路读的是 `/api/orders/active`，完成后的单不在里面，所以首页回到本地拨号，
   求助窗口只在订单页（完成页）生效。
8. **布局留位**：确认卡是一个纵向容器，后续「还没到，继续陪我」作为第二个按钮加在确认按钮下面。

## Risks

- 单测与 UI 测试只能真机跑，负责人暂定不跑真机；本变更的用例已写、未实跑。开闸前需真机走一遍开闸与关闸。
- 完成页停留超过 `sosWindowEndsAt` 时，顶栏求助胶囊不会自己换成本地拨号（页面不按时间重绘）；此时按下，发送前复核会判失败并给本地拨号兜底。
