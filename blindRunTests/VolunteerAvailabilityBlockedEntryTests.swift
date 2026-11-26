import XCTest
@testable import blindRun

/// 首页滑块滑不开时的提醒：换成「暂不能接单」胶囊，在胶囊上右滑也有回应。
final class VolunteerAvailabilityBlockedEntryTests: XCTestCase {
    /// 关着又滑不开时，滑块必须换成说明原因的胶囊，不能是一条静默失效的滑块。
    ///
    /// 🚩 关键输入是 `isAvailable: false, isEnabled: false, blocksOpening: false`（注册状态没同步完）：
    /// 只认 `blocksOpening` 的旧实现在这里给 false，陪跑员滑了没反应、也没有一个字。
    func testASliderThatCannotOpenIsAlwaysReplacedByAnExplanation() {
        XCTAssertTrue(
            VolunteerAvailabilitySlide.showsBlockedEntry(isAvailable: false, isEnabled: false, blocksOpening: false),
            "滑不开却仍画滑块 —— 陪跑员滑了没反应，也不知道为什么"
        )
        XCTAssertTrue(VolunteerAvailabilitySlide.showsBlockedEntry(isAvailable: false, isEnabled: false, blocksOpening: true))
        XCTAssertTrue(VolunteerAvailabilitySlide.showsBlockedEntry(isAvailable: true, isEnabled: false, blocksOpening: true))
        // 能滑开的人照常看到滑块；开着的人走「接单中」胶囊，不被说成「暂不能接单」。
        XCTAssertFalse(VolunteerAvailabilitySlide.showsBlockedEntry(isAvailable: false, isEnabled: true, blocksOpening: false))
        XCTAssertFalse(VolunteerAvailabilitySlide.showsBlockedEntry(isAvailable: true, isEnabled: false, blocksOpening: false))
    }

    /// 在「暂不能接单」胶囊上向右滑要有回应；轻微抖动和向左滑不算。
    func testOnlyARealRightwardSwipeOnTheBlockedPillCountsAsAnAttempt() {
        let minimum = VolunteerAvailabilitySlide.blockedSwipeMinimum
        XCTAssertTrue(VolunteerAvailabilitySlide.isBlockedOpenAttempt(dragX: minimum, dragY: 0))
        XCTAssertTrue(VolunteerAvailabilitySlide.isBlockedOpenAttempt(dragX: 200, dragY: 40))
        XCTAssertFalse(VolunteerAvailabilitySlide.isBlockedOpenAttempt(dragX: minimum - 1, dragY: 0))
        XCTAssertFalse(VolunteerAvailabilitySlide.isBlockedOpenAttempt(dragX: -200, dragY: 0))
        XCTAssertFalse(VolunteerAvailabilitySlide.isBlockedOpenAttempt(dragX: .nan, dragY: 0))
        // 从胶囊上起手的上下滚动，带一点右偏也不算想开启。
        XCTAssertFalse(
            VolunteerAvailabilitySlide.isBlockedOpenAttempt(dragX: 30, dragY: -150),
            "滚动首页时误打开接单前进度"
        )
    }
}
