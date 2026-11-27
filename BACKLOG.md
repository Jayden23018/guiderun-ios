# BACKLOG

## 待真机补测

合并时没跑真机的改动记在这里。负责人以后统一跑。跑过就删掉那一条，把结果写到对应 PR 的评论里。

### 约跑页：定位没回来时不再用演示坐标下单（2026-11-27）

负责人 2026-11-27 定：本次直接合并，不跑真机。合并前只做过 `build-for-testing` 编译，单测一条都没执行过，复现用例也没看过它先失败。

- [ ] 单测，7 个 suite。确认 `BlindBookingGateTests` 里新加的 4 条实际执行并通过：`testRefreshWithoutAFixDoesNotCacheTheDemoCoordinate`、`testRefreshWithoutAFixKeepsTheDemoStartPointInMock`、`testSubmitWaitsForTheFirstFixAndOrdersFromIt`、`testSubmitWithoutAnyFixSendsNothingAndSaysWhatToDo`：

  ```bash
  scripts/device-test.sh -only-testing:blindRunTests/BlindBookingGateTests -only-testing:blindRunTests/NearbyVolunteersTests -only-testing:blindRunTests/PreciseLocationGateTests -only-testing:blindRunTests/BlindBookingReviewAndMapTests -only-testing:blindRunTests/BlindPreRunGapsTests -only-testing:blindRunTests/VoiceOrderWizardStartPointTests -only-testing:blindRunTests/LaunchScopeTests
  ```

- [ ] 手动（演示云端，不是 Mock），定位没到：趁定位还没回来时进约跑页（例如刚授权那一下；系统可能直接给缓存位置，复现不出就跳过）。出发点应显示「还没拿到当前位置」。点「开始找陪跑员」应转圈最多 5 秒，仍没有定位时提示「还没拿到当前位置，请稍等再点，或选常用地点。」。定位回来后红字消失。
- [ ] 手动，临时精确位置：系统设置里关掉本 App 的「精确位置」，进约跑页，点「开始找陪跑员」，系统框选「允许一次」。应直接下单成功，出发点是当前位置，不用点第二次。

### 约跑页「目前附近无志愿者」提示卡（Jayden23018/guiderun-ios#1047，2026-11-27 合并）

- [ ] 打开 VoiceOver 用耳朵听一遍焦点顺序和结果通告，然后归档 OpenSpec `add-nearby-volunteers-notice`（任务 2.3）。
- [ ] 连真实后端联调一次（需要后端新端点已部署）。

### 约跑页附近没人时主动念出来（2026-11-27）

- [ ] 单测。确认 `NearbyVolunteersTests` 里 4 条播报用例（名字含 `Speaks`、`Keeps`、`DoesNotRepeat`）实际执行并通过：

  ```bash
  scripts/device-test.sh -only-testing:blindRunTests/NearbyVolunteersTests
  ```

- [ ] 手动（真机，附近没有陪跑员的账号）：分别在 VoiceOver 开、关两种情况下进约跑页。应先听到「目前附近无志愿者」和后端那句话，接着听到完整的开场白。VoiceOver 开着时留意是否念两遍、是否被页面切换的朗读盖掉。
