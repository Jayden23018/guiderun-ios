## 1. 实现
- [x] 1.1 模型、端点、service、Mock（`AIDRUN_MOCK_NEARBY_VOLUNTEERS=none`）
- [x] 1.2 约跑页提示卡、换出发点按钮、排队通告
- [x] 1.3 单测 `NearbyVolunteersTests`

## 2. 验证（后端合入后）
- [x] 2.1 后端 #1079 合入后跑 `scripts/sync-api-client.sh`，提交生成代码
- [x] 2.2 真机跑 `NearbyVolunteersTests`（2026-11-27，iPhone 16 Pro，13 条通过）
- [ ] 2.3 真机 VoiceOver 听卡片焦点顺序与通告
