# BACKLOG

## 待真机补测

合并时没跑真机的改动记在这里。负责人以后统一跑。跑过就删掉那一条，把结果写到对应 PR 的评论里。

### 约跑页：定位没回来时不再用演示坐标下单（2026-11-27）

负责人 2026-11-27 定：本次直接合并，不跑真机。合并前只做过 `build-for-testing` 编译，单测一条都没执行过，复现用例也没看过它先失败。

- [ ] 单测，6 个 suite 共 63 条，确认 `testRefreshWithoutAFixDoesNotCacheTheDemoCoordinate` 和 `testRefreshWithoutAFixKeepsTheDemoStartPointInMock` 实际执行并通过：

  ```bash
  scripts/device-test.sh -only-testing:blindRunTests/BlindBookingGateTests -only-testing:blindRunTests/NearbyVolunteersTests -only-testing:blindRunTests/PreciseLocationGateTests -only-testing:blindRunTests/BlindBookingReviewAndMapTests -only-testing:blindRunTests/BlindPreRunGapsTests -only-testing:blindRunTests/VoiceOrderWizardStartPointTests
  ```

- [ ] 手动（演示云端，不是 Mock）：让定位暂时拿不到（刚授权，或室内开飞行模式后开 App），进约跑页。出发点应显示「还没拿到当前位置」，点「开始找陪跑员」应提示「请选择出发地点。」。定位回来后应换成当前位置。

### 约跑页「目前附近无志愿者」提示卡（Jayden23018/guiderun-ios#1047，2026-11-27 合并）

- [ ] 打开 VoiceOver 用耳朵听一遍焦点顺序和结果通告，然后归档 OpenSpec `add-nearby-volunteers-notice`（任务 2.3）。
- [ ] 连真实后端联调一次（需要后端新端点已部署）。
