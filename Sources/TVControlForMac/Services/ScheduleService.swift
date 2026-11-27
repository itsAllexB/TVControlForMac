// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Polls once per ~20s and fires any enabled schedule whose time matches the current
/// minute, exactly once per occurrence. Which TVs a schedule changes is the owner's
/// business (see `AppState.applySchedule`).
///
/// The minute-match means a schedule whose time passes while the timer isn't ticking
/// (Mac asleep) would silently never fire. So each tick also watches for a gap since the
/// previous tick, and reports it so each TV can be set to the schedule that should be in
/// effect for it afterwards. (If a TV is still off at that moment, its controller holds
/// the value and delivers it when the TV comes back.)
final class ScheduleService {
    // Ticks are 20s apart. A schedule's minute can only pass without a tick in it if two
    // ticks are more than 60 s apart (one before the minute starts, the next after it
    // ends), so every gap over a minute is checked. A gap that's only a slow main thread
    // costs nothing: the catch-up acts only if a schedule's time fell inside it. At 90 s, a
    // short sleep of 61–90 s could skip a schedule.
    static let gapThreshold: TimeInterval = 60

    /// The current schedule list (called on the main thread).
    var getSchedules: () -> [BrightnessSchedule] = { [] }
    /// One schedule's time has come (called on the main thread).
    var onFire: (BrightnessSchedule) -> Void = { _ in }
    /// The app slept through (from, to] and at least one schedule's time fell inside it
    /// (called on the main thread).
    var onCatchUp: (_ from: Date, _ to: Date) -> Void = { _, _ in }

    private var timer: Timer?
    private var minuteKey = ""
    private var firedThisMinute = Set<UUID>()
    private var lastTick: Date?

    func start() {
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let now = Date()
        let schedules = getSchedules()

        let previousTick = lastTick
        lastTick = now
        if let previous = previousTick, now.timeIntervalSince(previous) > Self.gapThreshold,
           RuleTargets.anyFires(schedules, between: previous, and: now) {
            Log.write("schedule: catching up after a \(Int(now.timeIntervalSince(previous) / 60)) min gap (Mac was asleep)")
            onCatchUp(previous, now)
        }

        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let key = "\(calendar.component(.year, from: now))-\(calendar.component(.month, from: now))-\(calendar.component(.day, from: now)) \(hour):\(minute)"
        if key != minuteKey {
            minuteKey = key
            firedThisMinute.removeAll()
        }

        for schedule in schedules {
            if schedule.enabled && schedule.hour == hour && schedule.minute == minute
                && firedThisMinute.insert(schedule.id).inserted {
                let targets = schedule.tvIds.isEmpty ? "all TVs" : "\(schedule.tvIds.count) chosen TV(s)"
                Log.write(String(format: "schedule %02d:%02d fired -> %d%% (%@)",
                                 schedule.hour, schedule.minute, schedule.brightness, targets))
                onFire(schedule)
            }
        }
    }

    func dispose() {
        timer?.invalidate()
        timer = nil
    }
}
