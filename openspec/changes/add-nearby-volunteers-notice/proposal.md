# 约跑页提示「目前附近无志愿者」（#1046）

## Why
2026-11-27 起取消「只开深圳」。外地盲人下单后附近可能没有陪跑员，现在要等派单失败才知道。

## What Changes
- 约跑页调 `GET /api/orders/nearby-volunteers`（BLIND，GCJ-02，后端 blind-run-backend#1079）。
- 附近没人时，在「从哪出发？」标题下放一张常驻提示卡（后端 `hint`），带「换个出发点」按钮。
- 只提示，不拦下单。

## Impact
- Affected specs: `blind-booking-nearby-volunteers`（新增）。
- Affected code: `blindRun/BlindRunner/`、`blindRun/Core/`。
- 后端依赖：blind-run-backend#1079 合入并部署前，线上请求失败，卡片不显示。
