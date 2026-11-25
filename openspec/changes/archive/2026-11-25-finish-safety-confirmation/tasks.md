## 1. 契约与模型

- [x] 1.1 订单详情接 `finishRequestedAt`、`unilateralFinishOpensAt`、`sosWindowEndsAt`（宽容解码，`replacingStatus` 带过去）
- [x] 1.2 `finish` 读 `FinishOrderResponse.completed`；新增 `confirmSafe` 端点与服务方法
- [x] 1.3 错误码 `BLIND_SAFETY_CONFIRMATION_PENDING`，念后端 message

## 2. 陪跑员端

- [x] 2.1 `completed=false` 时回到空闲、显示并朗读等待提示与单方面结束时刻
- [x] 2.2 跑步页提示卡按 `unilateralFinishOpensAt` 切换「等待 / 现在可以结束」

## 3. 跑者端

- [x] 3.1 跑步页确认卡（第一张卡、焦点移入、调 `confirm-safe`）
- [x] 3.2 状态播报末尾补一句（冷启动可听到）
- [x] 3.3 `FINISH_SAFETY_CONFIRM_REQUESTED` 归入安全提醒并刷新订单
- [x] 3.4 完成后求助窗口：`BlindHomeSOSMode.resolve` 与发送前复核读 `canTriggerEmergency(as:now:)`

## 4. Mock 与测试

- [x] 4.1 Mock 镜像闸（默认关）、请求、单方面结束、确认、作废、完成后求助窗口
- [x] 4.2 单元测试覆盖开闸与关闸（已写、编译通过；真机未实跑，负责人 2026-11-25 同意先合后补）
- [x] 4.3 `AGENTS.md` §6 补一行求助窗口
