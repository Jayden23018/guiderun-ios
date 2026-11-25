import Foundation

// 从 `OrderModels.swift` 原样搬来（#1016）：那个文件超了 SwiftLint 长度上限，CI 棘轮不许再变长。

// MARK: - 跑步中（DECISIONS-v2 V10/V14–V16）

/// `OrderDetailResponse.run`。只解本页用得到的四项；距离/用时仍走 `track`（V10 不在本期）。
/// 每项都 `try?`：`run` 里任何一项形状不对，都不许连累整张订单详情（`AGENTS.md` 硬约束）。
struct RunView: Codable, Equatable, Sendable {
    var paused: Bool?
    var lastSignal: RunRhythmSignal?
    var lastSignalAt: String?
    var runnerBatteryLow: Bool?
    /// 用时（秒）= 现在 − 开始 − 暂停累计。契约原话「**暂停中不走**，这就是页面上的『计时停在 18:32』」——
    /// 所以暂停灰条读它，不读 `track` 的时长（后者按轨迹首末点算，暂停期间照样往上走）。
    var elapsedSeconds: Int64?

    private enum CodingKeys: String, CodingKey { case paused, lastSignal, lastSignalAt, runnerBatteryLow, elapsedSeconds }

    init(
        paused: Bool? = nil,
        lastSignal: RunRhythmSignal? = nil,
        lastSignalAt: String? = nil,
        runnerBatteryLow: Bool? = nil,
        elapsedSeconds: Int64? = nil
    ) {
        self.paused = paused
        self.lastSignal = lastSignal
        self.lastSignalAt = lastSignalAt
        self.runnerBatteryLow = runnerBatteryLow
        self.elapsedSeconds = elapsedSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paused = (try? container.decodeIfPresent(Bool.self, forKey: .paused)) ?? nil
        lastSignal = (try? container.decodeIfPresent(RunRhythmSignal.self, forKey: .lastSignal)) ?? nil
        lastSignalAt = (try? container.decodeIfPresent(String.self, forKey: .lastSignalAt)) ?? nil
        runnerBatteryLow = (try? container.decodeIfPresent(Bool.self, forKey: .runnerBatteryLow)) ?? nil
        elapsedSeconds = (try? container.decodeIfPresent(Int64.self, forKey: .elapsedSeconds)) ?? nil
    }

    /// 「18:32」/「1:02:05」，与三数字卡同一套体例（借 `TrackStats.durationClockText`，不另写一份格式化）。
    var elapsedClockText: String? {
        TrackStats(distanceMeters: nil, durationSeconds: elapsedSeconds, avgPaceSecPerKm: nil).durationClockText
    }
}

/// 节奏信号。文案固定三种（C33）。响应向开放：不认识的值解成 `unknown`，节奏卡按「还没有」处理。
enum RunRhythmSignal: String, Codable, Equatable, Sendable, CaseIterable {
    case slower = "SLOWER"
    case ok = "OK"
    case faster = "FASTER"
    case unknown = "UNKNOWN"

    static var sendable: [RunRhythmSignal] { [.slower, .ok, .faster] }

    init(from decoder: Decoder) throws {
        let rawValue = try? decoder.singleValueContainer().decode(String.self)
        self = rawValue.flatMap(RunRhythmSignal.init(rawValue:)) ?? .unknown
    }

    var title: String? {
        switch self {
        case .slower: return "稍慢一点"
        case .ok: return "刚刚好"
        case .faster: return "可以快一点"
        case .unknown: return nil
        }
    }
}

extension OrderDetailResponse {
    /// 陪跑员看跑者的称呼（V11）：有姓氏用姓氏，没有用「跑者」。**不念掩码全名。**
    var runnerShortName: String { blindSurname?.nilIfBlank ?? "跑者" }
    var isRunPaused: Bool { run?.paused == true }
}
