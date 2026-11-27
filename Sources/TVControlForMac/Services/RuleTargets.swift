// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Outcome of a brightness hotkey: a TV was adjusted, no linked TV was under the cursor
/// (prompt to link), or there was nothing to adjust.
enum HotkeyTargetOutcome { case adjusted, unpaired, none }

/// Something the Mac did that the power rules (Power page) can react to.
enum MacPowerEvent: String { case appStart, resume, suspend, sessionEnding, displayOff, displayOn }

/// What the power rules ask of one TV for one `MacPowerEvent`.
enum TvPowerAction: String { case none, powerOn, turnOff, screenOff }

/// How the brightness hotkeys pick their TV (see `AppSettings.hotkeyTarget`).
enum HotkeyMode { case cursor, all, tv }

/// The facts about one TV that rule targeting needs, free of any UI types.
struct TvInfo: Equatable {
    let id: String
    let name: String
    let supportsBrightness: Bool
    let pairedScreenId: String
}

/// What one hotkey press should do: which TVs to nudge, and whose new value the overlay shows.
struct HotkeyPlan: Equatable {
    let outcome: HotkeyTargetOutcome
    let tvIds: [String]
    let shownTvId: String?

    static let nothing = HotkeyPlan(outcome: .none, tvIds: [], shownTvId: nil)
    static let unpaired = HotkeyPlan(outcome: .unpaired, tvIds: [], shownTvId: nil)

    static func adjust(_ tvIds: [String], shown: String) -> HotkeyPlan {
        HotkeyPlan(outcome: .adjusted, tvIds: tvIds, shownTvId: shown)
    }
}

/// Which TVs each rule applies to: schedules, power rules and the brightness hotkeys can
/// each work for all TVs or for chosen ones. Pure logic on models and plain values, so it
/// can be exercised without the UI. Whether a TV can be dimmed can change while the app
/// runs, so callers pass it in fresh every time rather than this remembering it.
enum RuleTargets {
    /// `AppSettings.hotkeyTarget` value meaning "every TV that can be dimmed".
    static let allTvs = "all"

    // MARK: - Schedules

    /// True when `schedule` applies to the TV with `tvId`. An empty list means all TVs.
    /// Ids of TVs that no longer exist simply never match, so a schedule naming only
    /// removed TVs targets nothing rather than widening to all of them.
    static func targets(_ schedule: BrightnessSchedule, tvId: String) -> Bool {
        schedule.tvIds.isEmpty || schedule.tvIds.contains(tvId)
    }

    /// The enabled schedules that apply to one TV, in list order.
    static func enabledFor(_ schedules: [BrightnessSchedule], tvId: String) -> [BrightnessSchedule] {
        schedules.filter { $0.enabled && targets($0, tvId: tvId) }
    }

    /// The schedule in effect at `nowMinutes` (minutes since midnight) among `schedules`:
    /// the latest one at or before now, wrapping to the latest of the day (last night's)
    /// when none has passed yet today. Two at the same time: the later one in the list
    /// wins, as it would when they fire together. Nil for an empty list.
    static func inEffect(_ schedules: [BrightnessSchedule], nowMinutes: Int) -> BrightnessSchedule? {
        var passed: BrightnessSchedule?
        var latest: BrightnessSchedule?
        for schedule in schedules {
            let at = schedule.minutesOfDay
            if latest == nil || at >= latest!.minutesOfDay { latest = schedule }
            if at <= nowMinutes, passed == nil || at >= passed!.minutesOfDay { passed = schedule }
        }
        return passed ?? latest
    }

    /// The brightness the schedules want for one TV right now, or nil if none target it.
    static func scheduledBrightness(_ schedules: [BrightnessSchedule], tvId: String,
                                    now: Date = Date(), calendar: Calendar = .current) -> Int? {
        inEffect(enabledFor(schedules, tvId: tvId), nowMinutes: minutesOfDay(now, calendar))?.brightness
    }

    /// True when at least one enabled schedule's daily time falls inside (from, to]: it
    /// would have fired in that window had the Mac been awake.
    static func anyFires(_ schedules: [BrightnessSchedule], between from: Date, and to: Date,
                         calendar: Calendar = .current) -> Bool {
        let enabled = schedules.filter(\.enabled)
        if enabled.isEmpty { return false }
        if to.timeIntervalSince(from) >= 86_400 { return true } // a day or more passed: every schedule did

        for schedule in enabled {
            // First occurrence of this schedule's time strictly after `from`.
            var occurrence = calendar.date(bySettingHour: schedule.hour, minute: schedule.minute,
                                           second: 0, of: from) ?? from
            if occurrence <= from {
                occurrence = calendar.date(byAdding: .day, value: 1, to: occurrence) ?? occurrence
            }
            if occurrence <= to { return true }
        }
        return false
    }

    /// After the app slept through (from, to]: the brightness one TV should catch up to,
    /// or nil when no schedule targeting that TV fired in the gap (so a TV is never touched
    /// because of another TV's schedule).
    static func catchUpBrightness(_ schedules: [BrightnessSchedule], tvId: String,
                                  from: Date, to: Date, calendar: Calendar = .current) -> Int? {
        let mine = enabledFor(schedules, tvId: tvId)
        guard anyFires(mine, between: from, and: to, calendar: calendar) else { return nil }
        return inEffect(mine, nowMinutes: minutesOfDay(to, calendar))?.brightness
    }

    /// A schedule's TV list after one click in its TV picker. `tvId` nil is the "All TVs"
    /// entry. A TV is added or removed; un-ticking the last one goes back to all TVs.
    static func toggleTarget(_ current: [String], tvId: String?) -> [String] {
        guard let tvId else { return [] }
        var next = current
        if next.contains(tvId) {
            next.removeAll { $0 == tvId }
        } else {
            next.append(tvId)
        }
        return next
    }

    /// The picker's label: "All TVs", the TV's name for one, "2 TVs" for several.
    static func targetLabel(_ tvIds: [String], tvs: [TvInfo]) -> String {
        if tvIds.isEmpty { return "All TVs" }
        let chosen = tvs.filter { tvIds.contains($0.id) }
        switch chosen.count {
        case 0: return "No TVs"
        case 1: return chosen[0].name
        default: return "\(chosen.count) TVs"
        }
    }

    /// Takes a removed TV out of a schedule's list (dropping ids of TVs already gone with
    /// it). A schedule that named specific TVs and is left naming none is switched off
    /// rather than left to widen to all TVs. Returns true when the schedule changed.
    @discardableResult
    static func forgetTv(_ schedule: inout BrightnessSchedule, removedId: String, remainingIds: [String]) -> Bool {
        guard schedule.tvIds.contains(removedId) else { return false }
        let kept = schedule.tvIds.filter { $0 != removedId && remainingIds.contains($0) }
        schedule.tvIds = kept
        if kept.isEmpty { schedule.enabled = false }
        return true
    }

    private static func minutesOfDay(_ date: Date, _ calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    // MARK: - Power rules

    /// A TV's own power rules when it has them, otherwise the shared ones.
    static func effectivePower(own: PowerSettings?, shared: PowerSettings) -> PowerSettings {
        own ?? shared
    }

    /// What one set of power rules does for one Mac power event.
    static func action(for event: MacPowerEvent, rules: PowerSettings) -> TvPowerAction {
        switch event {
        case .appStart: return rules.onAppStart ? .powerOn : .none
        case .resume: return rules.onResume ? .powerOn : .none
        case .suspend: return rules.offOnSleep ? .turnOff : .none
        case .sessionEnding: return rules.offOnShutdown ? .turnOff : .none
        case .displayOff:
            guard rules.followDisplayOff else { return .none }
            return rules.displayOffAction == 1 ? .turnOff : .screenOff
        case .displayOn: return rules.followDisplayOn ? .powerOn : .none
        }
    }

    /// For one Mac power event, the TVs that have something to do and what, each judged by
    /// its own rules or, when it has none (`ownRules` returns nil), the shared ones.
    static func planPowerEvent<T>(_ event: MacPowerEvent, tvs: [T], ownRules: (T) -> PowerSettings?,
                                  shared: PowerSettings) -> [(tv: T, action: TvPowerAction)] {
        tvs.compactMap { tv in
            let action = action(for: event, rules: effectivePower(own: ownRules(tv), shared: shared))
            return action == .none ? nil : (tv, action)
        }
    }

    // MARK: - Brightness hotkeys

    /// Reads `AppSettings.hotkeyTarget`: "" is the TV under the cursor, "all" every
    /// dimmable TV, anything else a TV's id; an id that no longer exists falls back to
    /// the cursor.
    static func resolveHotkeyTarget(_ setting: String?, tvIds: [String]) -> (mode: HotkeyMode, tvId: String?) {
        guard let setting, !setting.isEmpty else { return (.cursor, nil) }
        if setting == allTvs { return (.all, nil) }
        return tvIds.contains(setting) ? (.tv, setting) : (.cursor, nil)
    }

    /// Works out what a brightness hotkey press changes. `cursorScreen` returns the id of
    /// the display under the mouse cursor; it's only asked when there's more than one TV.
    ///
    /// - Cursor mode: only TVs whose brightness can be set count. With a single such TV it
    ///   always targets that one, unless the cursor is on a screen linked to a TV without
    ///   brightness control, where the hotkey does nothing. With several and the cursor on
    ///   a screen no TV is linked to, nothing changes and the outcome is `.unpaired`.
    /// - All: every dimmable TV moves; the overlay shows the one under the cursor if it's
    ///   dimmable, else the first dimmable TV.
    /// - One TV: that TV, and nothing when it can't be dimmed right now.
    static func planHotkey(target: String?, tvs: [TvInfo], cursorScreen: () -> String?) -> HotkeyPlan {
        let dimmable = tvs.filter(\.supportsBrightness)
        if dimmable.isEmpty { return .nothing }

        let (mode, tvId) = resolveHotkeyTarget(target, tvIds: tvs.map(\.id))
        switch mode {
        case .tv:
            guard let chosen = tvs.first(where: { $0.id == tvId }), chosen.supportsBrightness else {
                return .nothing
            }
            return .adjust([chosen.id], shown: chosen.id)

        case .all:
            let under = tvUnderCursor(tvs, cursorScreen)
            let shown = (under?.supportsBrightness ?? false) ? under! : dimmable[0]
            return .adjust(dimmable.map(\.id), shown: shown.id)

        case .cursor:
            let under = tvUnderCursor(tvs, cursorScreen)
            if let under, !under.supportsBrightness { return .nothing }
            guard let tv = dimmable.count == 1 ? dimmable[0] : under else { return .unpaired }
            return .adjust([tv.id], shown: tv.id)
        }
    }

    // With one TV in total there's nothing to tell apart, so the cursor isn't consulted.
    private static func tvUnderCursor(_ tvs: [TvInfo], _ cursorScreen: () -> String?) -> TvInfo? {
        guard tvs.count > 1, let screen = cursorScreen(), !screen.isEmpty else { return nil }
        return tvs.first { $0.pairedScreenId == screen }
    }
}
