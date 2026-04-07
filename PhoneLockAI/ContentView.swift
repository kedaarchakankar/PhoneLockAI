//
//  ContentView.swift
//  PhoneLockAI
//
//  Created by Kedaar Chakankar on 3/19/26.
//

import SwiftUI
import Foundation
import UserNotifications
import FamilyControls
import ManagedSettings
import DeviceActivity

// MARK: - Models

enum GoalRepeatFrequency: String, Codable, CaseIterable, Hashable {
    case none
    case daily
    case weekly
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case Self.none.rawValue: self = .none
        case Self.daily.rawValue: self = .daily
        case Self.weekly.rawValue: self = .weekly
        case "monthly": self = .weekly
        default: self = .none
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct Goal: Identifiable, Codable, Hashable {
    var id: UUID
    var text: String
    var repeatFrequency: GoalRepeatFrequency
    var isTimed: Bool
    var targetTime: Date?
    /// Calendar weekday (1 = Sunday … 7 = Saturday) for weekly repeating timed reminders; set when the goal is saved.
    var weeklyAnchorWeekday: Int?
    /// Local start-of-day for which a non-repeating (`.none`) goal is valid; older goals without this field are backfilled on load.
    var nonRepeatingDayStart: Date?
    /// For `.none` only: persistent completion for that single day.
    var isCompleted: Bool
    /// For `.daily` / `.weekly`: completion applies only when this matches the calendar day being viewed (start-of-day).
    var completedForDayStart: Date?

    init(
        id: UUID = UUID(),
        text: String,
        repeatFrequency: GoalRepeatFrequency = .none,
        isTimed: Bool = false,
        targetTime: Date? = nil,
        weeklyAnchorWeekday: Int? = nil,
        nonRepeatingDayStart: Date? = nil,
        isCompleted: Bool = false,
        completedForDayStart: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.repeatFrequency = repeatFrequency
        self.isTimed = isTimed
        self.targetTime = targetTime
        self.weeklyAnchorWeekday = weeklyAnchorWeekday
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        if repeatFrequency == .none {
            self.nonRepeatingDayStart = nonRepeatingDayStart.map { cal.startOfDay(for: $0) } ?? todayStart
        } else {
            self.nonRepeatingDayStart = nil
        }
        self.isCompleted = isCompleted
        self.completedForDayStart = completedForDayStart.map { cal.startOfDay(for: $0) }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case repeatFrequency
        case isTimed
        case targetTime
        case weeklyAnchorWeekday
        case nonRepeatingDayStart
        case isCompleted
        case completedForDayStart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.repeatFrequency = try container.decodeIfPresent(GoalRepeatFrequency.self, forKey: .repeatFrequency) ?? .none
        self.isTimed = try container.decodeIfPresent(Bool.self, forKey: .isTimed) ?? false
        self.targetTime = try container.decodeIfPresent(Date.self, forKey: .targetTime)
        self.weeklyAnchorWeekday = try container.decodeIfPresent(Int.self, forKey: .weeklyAnchorWeekday)
        self.nonRepeatingDayStart = try container.decodeIfPresent(Date.self, forKey: .nonRepeatingDayStart)
        let legacyIsCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        var decodedDayStart = try container.decodeIfPresent(Date.self, forKey: .completedForDayStart).map { Calendar.current.startOfDay(for: $0) }

        if self.repeatFrequency != .none {
            self.nonRepeatingDayStart = nil
            if decodedDayStart == nil, legacyIsCompleted {
                decodedDayStart = Calendar.current.startOfDay(for: Date())
            }
            self.completedForDayStart = decodedDayStart
            self.isCompleted = false
        } else {
            if let d = self.nonRepeatingDayStart {
                self.nonRepeatingDayStart = Calendar.current.startOfDay(for: d)
            }
            self.completedForDayStart = nil
            self.isCompleted = legacyIsCompleted
        }
    }
}

extension Goal {
    /// Whether this goal applies to the given local calendar day (`dayStart` should be start-of-day).
    func matchesCalendarDay(_ dayStart: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: dayStart)
        switch repeatFrequency {
        case .none:
            let gDay = nonRepeatingDayStart.map { calendar.startOfDay(for: $0) } ?? start
            return gDay == start
        case .daily:
            return true
        case .weekly:
            let weekday = calendar.component(.weekday, from: start)
            let anchor = weeklyAnchorWeekday ?? weekday
            return weekday == anchor
        }
    }

    /// Daily or weekly goals (shown on the All Goals screen).
    var isRepeating: Bool {
        repeatFrequency == .daily || repeatFrequency == .weekly
    }

    /// Completion for the calendar day containing `day` (repeating goals only count for that day).
    func isCompleted(on day: Date, calendar: Calendar = .current) -> Bool {
        let dayStart = calendar.startOfDay(for: day)
        switch repeatFrequency {
        case .none:
            return isCompleted
        case .daily, .weekly:
            guard let marked = completedForDayStart else { return false }
            return calendar.startOfDay(for: marked) == dayStart
        }
    }

    mutating func toggleCompletion(on day: Date, calendar: Calendar = .current) {
        let dayStart = calendar.startOfDay(for: day)
        switch repeatFrequency {
        case .none:
            isCompleted.toggle()
        case .daily, .weekly:
            if isCompleted(on: day, calendar: calendar) {
                completedForDayStart = nil
            } else {
                completedForDayStart = dayStart
            }
        }
    }
}

struct UnlockSessionRecord: Identifiable, Codable {
    var id: UUID
    var startDate: Date
    var endDate: Date
    var isEmergency: Bool

    init(id: UUID = UUID(), startDate: Date, endDate: Date, isEmergency: Bool) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.isEmergency = isEmergency
    }
}

// MARK: - Store (backend mock via local persistence)

@MainActor
final class PhoneLockStore: ObservableObject {
    private enum ScreenTimeConfig {
        static let unlockPrimaryActivityPrefix = "com.phonelockai.unlock.primary."
        static let unlockFallbackActivityPrefix = "com.phonelockai.unlock.fallback."
        static let activeShieldStoreName = ManagedSettingsStore.Name("com.phonelockai.shield.active")
        static let legacyBaselineShieldStoreName = ManagedSettingsStore.Name("com.phonelockai.shield.baseline")
        static let sharedDefaultsSuite = "group.com.phonelockai.shared"
        static let unlockEndedAtKey = "pol_unlock_ended_at"
        static let activeUnlockStateKey = "pol_active_unlock_state"
        /// Persisted so app + extension can stop monitors after process restart (in-memory names are lost).
        static let daMonitorPrimaryKey = "pol_da_unlock_primary"
        static let daMonitorFallbackKey = "pol_da_unlock_fallback"
        static let daLastStartErrorKey = "pol_da_last_start_error"
        static let daLastStartErrorTimeKey = "pol_da_last_start_error_ts"
        /// JSON mirror of blocked apps; extensions sometimes see stale/missing `UserDefaults` data — file is more reliable.
        static let blockedSelectionFilename = "blocked_apps_selection.json"
        static let extLastEventKey = "pol_ext_last_event"
        static let extLastEventTimeKey = "pol_ext_last_event_ts"
        static let extLastActivityKey = "pol_ext_last_activity"
        static let activeUnlockSessionIDKey = "pol_unlock_session_id"
        /// `DeviceActivityCenter.startMonitoring` fails with `intervalTooShort` if the span is below this (empirically ~15m on iOS).
        static let deviceActivityMinimumScheduleDuration: TimeInterval = 15 * 60
    }

    private struct ActiveUnlockState: Codable {
        var sessionID: String
        var startDate: Date
        var durationSeconds: TimeInterval
        var isEmergency: Bool

        enum CodingKeys: String, CodingKey {
            case sessionID
            case startDate
            case durationSeconds
            case isEmergency
        }

        init(sessionID: String, startDate: Date, durationSeconds: TimeInterval, isEmergency: Bool) {
            self.sessionID = sessionID
            self.startDate = startDate
            self.durationSeconds = durationSeconds
            self.isEmergency = isEmergency
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID) ?? UUID().uuidString
            self.startDate = try c.decode(Date.self, forKey: .startDate)
            self.durationSeconds = try c.decode(TimeInterval.self, forKey: .durationSeconds)
            self.isEmergency = try c.decode(Bool.self, forKey: .isEmergency)
        }
    }

    // User profile
    @Published var hasOnboarded: Bool {
        didSet { persistHasOnboarded() }
    }
    @Published var goals: [Goal] {
        didSet {
            persistGoals()
            Task {
                await GoalReminderScheduler.shared.syncReminders(for: goals)
            }
        }
    }

    // Daily limit (resets daily by recomputing using "today" totals)
    @Published var dailyLimitHours: Int {
        didSet { persistLimit() }
    }
    @Published var dailyLimitMinutes: Int {
        didSet { persistLimit() }
    }

    // Emergency controls (Settings-only button starts a 5-min unlock)
    @Published var emergencyUnlockEnabled: Bool {
        didSet { persistEmergencyEnabled() }
    }
    @Published var blockedAppsSelection: FamilyActivitySelection {
        didSet {
            persistBlockedAppsSelection()
            persistBlockedAppsSelectionToSharedDefaults()
            reconcileActiveUnlockIfNeeded()
        }
    }

    // Unlock sessions
    @Published private(set) var sessionRecords: [UnlockSessionRecord] {
        didSet { persistSessions() }
    }
    @Published private(set) var streakDays: Int {
        didSet { persistStreakState() }
    }
    @Published private(set) var activeSessionStartDate: Date?
    @Published private(set) var activeSessionIsEmergency: Bool = false
    @Published private(set) var activeSessionDurationSeconds: TimeInterval = 5 * 60

    // For debug/UI
    @Published var lastUnlockedSessionID: UUID?

    private let defaults = UserDefaults.standard
    private let activeShieldStore = ManagedSettingsStore(named: ScreenTimeConfig.activeShieldStoreName)
    private let deviceActivityCenter = DeviceActivityCenter()
    private var monitoredUnlockEndDate: Date?
    private var activeUnlockSessionID: String?
    private var lastStreakProcessedDayStart: Date? {
        didSet { persistStreakState() }
    }

    private enum Keys {
        static let onboarded = "pol_onboarded"
        static let goals = "pol_goals"
        static let limitHours = "pol_limit_hours"
        static let limitMinutes = "pol_limit_minutes"
        static let emergencyEnabled = "pol_emergency_enabled"
        static let sessions = "pol_sessions"
        static let streakDays = "pol_streak_days"
        static let streakLastProcessedDayStart = "pol_streak_last_processed_day_start"
        static let blockedAppsSelection = "pol_blocked_apps_selection"
        /// Legacy: active unlock was also written here; extension cannot clear this — caused stale "unlock active" after extension re-locked.
        static let activeUnlockStateLegacy = "pol_active_unlock_state"
    }

    init() {
        let storedGoals: [Goal] = Self.loadCodable(forKey: Keys.goals, as: [Goal].self) ?? []
        let storedSessions: [UnlockSessionRecord] = Self.loadCodable(forKey: Keys.sessions, as: [UnlockSessionRecord].self) ?? []

        self.hasOnboarded = defaults.bool(forKey: Keys.onboarded)
        self.dailyLimitHours = defaults.integer(forKey: Keys.limitHours)
        self.dailyLimitMinutes = defaults.integer(forKey: Keys.limitMinutes)
        self.emergencyUnlockEnabled = defaults.object(forKey: Keys.emergencyEnabled) == nil ? true : defaults.bool(forKey: Keys.emergencyEnabled)
        self.sessionRecords = storedSessions
        self.streakDays = defaults.integer(forKey: Keys.streakDays)
        self.blockedAppsSelection = Self.loadCodable(forKey: Keys.blockedAppsSelection, as: FamilyActivitySelection.self) ?? FamilyActivitySelection()
        if defaults.object(forKey: Keys.streakLastProcessedDayStart) != nil {
            let ts = defaults.double(forKey: Keys.streakLastProcessedDayStart)
            self.lastStreakProcessedDayStart = Date(timeIntervalSince1970: ts)
        } else {
            self.lastStreakProcessedDayStart = nil
        }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        let backfilledGoals = storedGoals.map { goal -> Goal in
            guard goal.repeatFrequency == .none, goal.nonRepeatingDayStart == nil else { return goal }
            var g = goal
            g.nonRepeatingDayStart = todayStart
            return g
        }
        self.goals = backfilledGoals

        migrateLegacyActiveUnlockFromStandardIfNeeded()
        restoreActiveUnlockStateIfNeeded()
        updateStreakIfNeeded()
        pruneExpiredNoneRepeatGoalsIfNeeded()
        Task {
            await GoalReminderScheduler.shared.syncReminders(for: goals)
        }
        clearLegacyBaselineShieldStoreIfNeeded()
        persistBlockedAppsSelectionToSharedDefaults()
        reconcileActiveUnlockIfNeeded()
    }

    var dailyLimitSeconds: Int {
        max(0, dailyLimitHours * 3600 + dailyLimitMinutes * 60)
    }

    var emergencyUnlockMonthlyLimit: Int {
        4
    }

    var emergencyUnlocksUsedThisMonth: Int {
        let calendar = Calendar.current
        let now = Date()
        guard let monthInterval = calendar.dateInterval(of: .month, for: now) else { return 0 }
        return sessionRecords.reduce(0) { count, record in
            guard record.isEmergency else { return count }
            return monthInterval.contains(record.startDate) ? count + 1 : count
        }
    }

    var emergencyUnlocksRemainingThisMonth: Int {
        max(0, emergencyUnlockMonthlyLimit - emergencyUnlocksUsedThisMonth)
    }

    var canStartEmergencyUnlock: Bool {
        emergencyUnlockEnabled && !isUnlockActive && dailyLimitSeconds > 0 && emergencyUnlocksRemainingThisMonth > 0
    }

    var activeSessionElapsedSeconds: TimeInterval {
        guard let start = activeSessionStartDate else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var activeSessionPlannedEndDate: Date? {
        guard let start = activeSessionStartDate else { return nil }
        return start.addingTimeInterval(activeSessionDurationSeconds)
    }

    var isUnlockActive: Bool {
        guard let end = activeSessionPlannedEndDate else { return false }
        return Date() < end
    }

    // MARK: - Persistence

    private func persistHasOnboarded() {
        defaults.set(hasOnboarded, forKey: Keys.onboarded)
    }

    private func persistGoals() {
        Self.persistCodable(goals, forKey: Keys.goals, using: defaults)
    }

    private func persistLimit() {
        defaults.set(dailyLimitHours, forKey: Keys.limitHours)
        defaults.set(dailyLimitMinutes, forKey: Keys.limitMinutes)
    }

    private func persistEmergencyEnabled() {
        defaults.set(emergencyUnlockEnabled, forKey: Keys.emergencyEnabled)
    }

    private func persistSessions() {
        Self.persistCodable(sessionRecords, forKey: Keys.sessions, using: defaults)
    }

    private func persistStreakState() {
        defaults.set(streakDays, forKey: Keys.streakDays)
        if let day = lastStreakProcessedDayStart {
            defaults.set(day.timeIntervalSince1970, forKey: Keys.streakLastProcessedDayStart)
        } else {
            defaults.removeObject(forKey: Keys.streakLastProcessedDayStart)
        }
    }

    private func persistBlockedAppsSelection() {
        Self.persistCodable(blockedAppsSelection, forKey: Keys.blockedAppsSelection, using: defaults)
    }

    private func persistBlockedAppsSelectionToSharedDefaults() {
        guard let sharedDefaults = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) else { return }
        do {
            let data = try JSONEncoder().encode(blockedAppsSelection)
            sharedDefaults.set(data, forKey: Keys.blockedAppsSelection)
            if let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ScreenTimeConfig.sharedDefaultsSuite) {
                let url = base.appendingPathComponent(ScreenTimeConfig.blockedSelectionFilename, isDirectory: false)
                if blockedAppsSelection.applicationTokens.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                } else {
                    try data.write(to: url, options: .atomic)
                }
            }
            sharedDefaults.synchronize()
        } catch {
            Self.persistCodable(blockedAppsSelection, forKey: Keys.blockedAppsSelection, using: sharedDefaults)
        }
    }

    /// After backgrounding, `DeviceActivity` callbacks are opaque; rescheduling when active avoids “stuck” monitors.
    func refreshUnlockMonitorAfterReturningToForeground() {
        guard isUnlockActive else { return }
        monitoredUnlockEndDate = nil
        ensureUnlockExpiryMonitorIsScheduled()
    }

    func unlockDiagnosticsReport() -> String {
        var lines: [String] = []
        guard let shared = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) else {
            return "App Group UserDefaults unavailable (check entitlements / reinstall)."
        }
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ScreenTimeConfig.sharedDefaultsSuite)
        let fileURL = container?.appendingPathComponent(ScreenTimeConfig.blockedSelectionFilename, isDirectory: false)
        let fileOK = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        lines.append("App group container: \(container != nil ? "ok" : "missing")")
        lines.append("blocked_apps_selection.json present: \(fileOK ? "yes" : "no")")
        let udBytes = shared.data(forKey: Keys.blockedAppsSelection)?.count ?? 0
        lines.append("Blocked apps data in UserDefaults: \(udBytes) bytes")
        lines.append("Extension last event: \(shared.string(forKey: ScreenTimeConfig.extLastEventKey) ?? "—")")
        if let ts = shared.object(forKey: ScreenTimeConfig.extLastEventTimeKey) as? Double {
            lines.append("Extension event at: \(Date(timeIntervalSince1970: ts))")
        }
        if let act = shared.string(forKey: ScreenTimeConfig.extLastActivityKey), !act.isEmpty {
            lines.append("Extension activity id: \(act)")
        }
        if let err = shared.string(forKey: ScreenTimeConfig.daLastStartErrorKey) {
            lines.append("Last schedule error: \(err)")
        }
        lines.append("App thinks unlock active: \(isUnlockActive)")
        lines.append("Monitor end cached: \(monitoredUnlockEndDate != nil)")
        lines.append("DA min schedule padding: \(Int(ScreenTimeConfig.deviceActivityMinimumScheduleDuration / 60))m (short unlocks re-lock via intervalWillEndWarning)")
        return lines.joined(separator: "\n")
    }

    /// Drops non-repeating (`.none`) goals after the local calendar day they belong to ends.
    func pruneExpiredNoneRepeatGoalsIfNeeded(now: Date = Date()) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        goals.removeAll { goal in
            guard goal.repeatFrequency == .none else { return false }
            let day = goal.nonRepeatingDayStart.map { calendar.startOfDay(for: $0) } ?? today
            return day < today
        }
    }

    private static func loadCodable<T: Decodable>(forKey key: String, as type: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    private static func persistCodable<T: Encodable>(_ value: T, forKey key: String, using defaults: UserDefaults) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
        } catch {
            // In a mock app, we silently ignore persistence errors.
        }
    }

    // MARK: - Unlock control (mock)

    private static let unlockThirtySecondWarningNotificationID = "pol_unlock_30s_warning"

    func startUnlock(durationMinutes: Int, isEmergency: Bool) {
        reconcileActiveUnlockIfNeeded()
        guard activeSessionStartDate == nil else { return }
        activeSessionIsEmergency = isEmergency
        activeSessionDurationSeconds = TimeInterval(max(1, durationMinutes) * 60)
        activeSessionStartDate = Date()
        activeUnlockSessionID = UUID().uuidString
        persistActiveUnlockState()
        clearSharedUnlockEndedMarker()
        ensureUnlockExpiryMonitorIsScheduled()
        scheduleUnlockThirtySecondWarningNotification()
        reconcileActiveUnlockIfNeeded()
    }

    func startEmergencyUnlockIfAllowed(durationMinutes: Int) {
        guard canStartEmergencyUnlock else { return }
        guard durationMinutes > 0 else { return }
        startUnlock(durationMinutes: durationMinutes, isEmergency: true)
    }

    func endActiveUnlock() {
        guard let start = activeSessionStartDate else { return }
        let now = Date()
        let plannedEnd = activeSessionPlannedEndDate ?? now
        endActiveUnlock(start: start, end: min(now, plannedEnd))
    }

    private func endActiveUnlock(start: Date, end: Date) {
        let effectiveEnd = max(start, end)

        let record = UnlockSessionRecord(
            startDate: start,
            endDate: effectiveEnd,
            isEmergency: activeSessionIsEmergency
        )
        sessionRecords.append(record)
        lastUnlockedSessionID = record.id

        activeSessionStartDate = nil
        activeSessionIsEmergency = false
        activeSessionDurationSeconds = 5 * 60
        activeUnlockSessionID = nil
        clearPersistedActiveUnlockState()
        stopUnlockExpiryMonitor()
        cancelUnlockThirtySecondWarningNotification()
        clearSharedUnlockEndedMarker()
        applyShieldForCurrentUnlockState()
    }

    func reconcileActiveUnlockIfNeeded(now: Date = Date()) {
        reconcileFromSharedUnlockEndedMarker(now: now)

        guard let start = activeSessionStartDate,
              let plannedEnd = activeSessionPlannedEndDate else {
            applyShieldForCurrentUnlockState()
            return
        }

        if now >= plannedEnd {
            endActiveUnlock(start: start, end: plannedEnd)
        } else {
            ensureUnlockExpiryMonitorIsScheduled()
            applyShieldForCurrentUnlockState()
        }
    }

    var blockedAppCount: Int {
        blockedAppsSelection.applicationTokens.count
    }

    var blockedAppTokens: [ApplicationToken] {
        Array(blockedAppsSelection.applicationTokens).sorted { "\($0)" < "\($1)" }
    }

    func requestFamilyControlsAuthorizationIfNeeded() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            // Keep onboarding/settings usable even if authorization is declined for now.
        }
    }

    @discardableResult
    func requestNotificationAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// Applies `ManagedSettings` shield from current in-memory unlock + selection only. Does not read the extension marker.
    private func applyShieldForCurrentUnlockState() {
        let selectedApps = blockedAppsSelection.applicationTokens

        if isUnlockActive || blockedAppsSelection.applicationTokens.isEmpty {
            activeShieldStore.shield.applications = nil
            return
        }
        activeShieldStore.shield.applications = selectedApps
    }

    private func clearLegacyBaselineShieldStoreIfNeeded() {
        let legacyStore = ManagedSettingsStore(named: ScreenTimeConfig.legacyBaselineShieldStoreName)
        legacyStore.shield.applications = nil
    }

    private func reconcileFromSharedUnlockEndedMarker(now: Date) {
        guard let sharedDefaults = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite),
              let marker = sharedDefaults.object(forKey: ScreenTimeConfig.unlockEndedAtKey) as? Double else {
            return
        }

        defer {
            sharedDefaults.removeObject(forKey: ScreenTimeConfig.unlockEndedAtKey)
        }

        if let start = activeSessionStartDate {
            let markerDate = Date(timeIntervalSince1970: marker)
            let plannedEnd = activeSessionPlannedEndDate ?? markerDate
            let boundedEnd = min(max(start, markerDate), plannedEnd, now)
            endActiveUnlock(start: start, end: boundedEnd)
            return
        }

        // Extension re-locked while the app had no in-memory session (e.g. after relaunch). Do not drop the marker
        // without syncing: otherwise stale standard/group state could think an unlock is still active.
        clearPersistedActiveUnlockState()
        applyShieldForCurrentUnlockState()
    }

    private func clearSharedUnlockEndedMarker() {
        guard let sharedDefaults = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) else { return }
        sharedDefaults.removeObject(forKey: ScreenTimeConfig.unlockEndedAtKey)
    }

    private func persistActiveUnlockState() {
        guard let startDate = activeSessionStartDate else {
            clearPersistedActiveUnlockState()
            return
        }
        let state = ActiveUnlockState(
            sessionID: activeUnlockSessionID ?? UUID().uuidString,
            startDate: startDate,
            durationSeconds: activeSessionDurationSeconds,
            isEmergency: activeSessionIsEmergency
        )
        // App group only — the extension clears this when the timer fires; standard defaults would stay stale forever.
        if let sharedDefaults = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) {
            Self.persistCodable(state, forKey: ScreenTimeConfig.activeUnlockStateKey, using: sharedDefaults)
            sharedDefaults.set(state.sessionID, forKey: ScreenTimeConfig.activeUnlockSessionIDKey)
        }
        defaults.removeObject(forKey: Keys.activeUnlockStateLegacy)
    }

    private func clearPersistedActiveUnlockState() {
        activeUnlockSessionID = nil
        defaults.removeObject(forKey: Keys.activeUnlockStateLegacy)
        if let sharedDefaults = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) {
            sharedDefaults.removeObject(forKey: ScreenTimeConfig.activeUnlockStateKey)
            sharedDefaults.removeObject(forKey: ScreenTimeConfig.activeUnlockSessionIDKey)
        }
    }

    private func loadPersistedActiveUnlockState() -> ActiveUnlockState? {
        guard let sharedDefaults = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite),
              let sharedData = sharedDefaults.data(forKey: ScreenTimeConfig.activeUnlockStateKey),
              let state = try? JSONDecoder().decode(ActiveUnlockState.self, from: sharedData) else {
            return nil
        }
        return state
    }

    /// One-time migration from pre-fix builds that wrote active unlock to `UserDefaults.standard` (extension could not clear it).
    private func migrateLegacyActiveUnlockFromStandardIfNeeded(now: Date = Date()) {
        guard let data = defaults.data(forKey: Keys.activeUnlockStateLegacy),
              let state = try? JSONDecoder().decode(ActiveUnlockState.self, from: data) else { return }

        defaults.removeObject(forKey: Keys.activeUnlockStateLegacy)
        let plannedEnd = state.startDate.addingTimeInterval(max(1, state.durationSeconds))

        guard let shared = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) else { return }

        if now < plannedEnd {
            let migrated = ActiveUnlockState(
                sessionID: UUID().uuidString,
                startDate: state.startDate,
                durationSeconds: state.durationSeconds,
                isEmergency: state.isEmergency
            )
            activeUnlockSessionID = migrated.sessionID
            Self.persistCodable(migrated, forKey: ScreenTimeConfig.activeUnlockStateKey, using: shared)
        } else {
            let record = UnlockSessionRecord(
                startDate: state.startDate,
                endDate: plannedEnd,
                isEmergency: state.isEmergency
            )
            sessionRecords.append(record)
            lastUnlockedSessionID = record.id
        }
    }

    private func restoreActiveUnlockStateIfNeeded(now: Date = Date()) {
        guard let state = loadPersistedActiveUnlockState() else { return }
        let plannedEnd = state.startDate.addingTimeInterval(max(1, state.durationSeconds))
        if now < plannedEnd {
            activeUnlockSessionID = state.sessionID
            activeSessionStartDate = state.startDate
            activeSessionDurationSeconds = state.durationSeconds
            activeSessionIsEmergency = state.isEmergency
            ensureUnlockExpiryMonitorIsScheduled()
            return
        }

        let record = UnlockSessionRecord(
            startDate: state.startDate,
            endDate: plannedEnd,
            isEmergency: state.isEmergency
        )
        sessionRecords.append(record)
        lastUnlockedSessionID = record.id
        clearPersistedActiveUnlockState()
    }

    private func ensureUnlockExpiryMonitorIsScheduled() {
        guard let endDate = activeSessionPlannedEndDate else { return }
        if let monitoredUnlockEndDate,
           abs(monitoredUnlockEndDate.timeIntervalSince(endDate)) < 0.5 {
            return
        }
        scheduleUnlockExpiryMonitor(until: endDate)
    }

    /// Builds a schedule that satisfies Apple's minimum interval length. Short unlocks use `warningTime` so `intervalWillEndWarning` fires at `desiredEnd`.
    private func deviceActivitySchedule(scheduleStart: Date, desiredEnd: Date, calendar: Calendar) -> DeviceActivitySchedule {
        let rawSpan = desiredEnd.timeIntervalSince(scheduleStart)
        let paddedSpan = max(rawSpan, ScreenTimeConfig.deviceActivityMinimumScheduleDuration)
        let intervalEnd = scheduleStart.addingTimeInterval(paddedSpan)
        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: scheduleStart)
        let endComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: intervalEnd)
        let warningTime: DateComponents?
        if paddedSpan - rawSpan > 1 {
            let secondsBeforeEnd = Int(round(paddedSpan - rawSpan))
            warningTime = Self.warningDateComponents(secondsBeforeIntervalEnd: secondsBeforeEnd)
        } else {
            warningTime = nil
        }
        return DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false,
            warningTime: warningTime
        )
    }

    private static func warningDateComponents(secondsBeforeIntervalEnd: Int) -> DateComponents {
        let s = max(1, secondsBeforeIntervalEnd)
        var c = DateComponents()
        c.hour = s / 3600
        c.minute = (s % 3600) / 60
        c.second = s % 60
        return c
    }

    private func scheduleUnlockExpiryMonitor(until endDate: Date) {
        let now = Date()
        guard endDate > now else { return }
        guard let sessionID = activeUnlockSessionID, !sessionID.isEmpty else { return }

        let cal = Calendar.current
        stopUnlockExpiryMonitor()

        let primaryName = DeviceActivityName(ScreenTimeConfig.unlockPrimaryActivityPrefix + sessionID)
        let fallbackName = DeviceActivityName(ScreenTimeConfig.unlockFallbackActivityPrefix + sessionID)
        let startOffsets: [TimeInterval] = [2, 5, 10]
        for offset in startOffsets {
            let scheduleStart = now.addingTimeInterval(offset)
            guard endDate.timeIntervalSince(scheduleStart) > 1 else { continue }

            let primarySchedule = deviceActivitySchedule(scheduleStart: scheduleStart, desiredEnd: endDate, calendar: cal)
            guard startMonitor(named: primaryName, schedule: primarySchedule) else { continue }

            let fallbackDesiredEnd = endDate.addingTimeInterval(90)
            let fallbackSchedule = deviceActivitySchedule(scheduleStart: scheduleStart, desiredEnd: fallbackDesiredEnd, calendar: cal)
            guard startMonitor(named: fallbackName, schedule: fallbackSchedule) else {
                deviceActivityCenter.stopMonitoring([primaryName])
                continue
            }
            monitoredUnlockEndDate = endDate
            persistFixedUnlockMonitorNamesToShared(primary: primaryName, fallback: fallbackName)
            return
        }
        monitoredUnlockEndDate = nil
    }

    private func persistFixedUnlockMonitorNamesToShared(primary: DeviceActivityName, fallback: DeviceActivityName) {
        guard let shared = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) else { return }
        shared.set(primary.rawValue, forKey: ScreenTimeConfig.daMonitorPrimaryKey)
        shared.set(fallback.rawValue, forKey: ScreenTimeConfig.daMonitorFallbackKey)
    }

    private func clearPersistedUnlockMonitorNamesFromShared() {
        guard let shared = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) else { return }
        shared.removeObject(forKey: ScreenTimeConfig.daMonitorPrimaryKey)
        shared.removeObject(forKey: ScreenTimeConfig.daMonitorFallbackKey)
    }

    private func stopUnlockExpiryMonitor() {
        var rawNames = Set<String>()
        if let shared = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) {
            if let p = shared.string(forKey: ScreenTimeConfig.daMonitorPrimaryKey) { rawNames.insert(p) }
            if let f = shared.string(forKey: ScreenTimeConfig.daMonitorFallbackKey) { rawNames.insert(f) }
        }
        let names = rawNames.map { DeviceActivityName($0) }
        if !names.isEmpty {
            deviceActivityCenter.stopMonitoring(names)
        }
        monitoredUnlockEndDate = nil
        clearPersistedUnlockMonitorNamesFromShared()
    }

    private func startMonitor(named name: DeviceActivityName, schedule: DeviceActivitySchedule) -> Bool {
        do {
            try deviceActivityCenter.startMonitoring(name, during: schedule)
            if let shared = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) {
                shared.removeObject(forKey: ScreenTimeConfig.daLastStartErrorKey)
                shared.removeObject(forKey: ScreenTimeConfig.daLastStartErrorTimeKey)
            }
            return true
        } catch {
            if let shared = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) {
                shared.set(String(describing: error), forKey: ScreenTimeConfig.daLastStartErrorKey)
                shared.set(Date().timeIntervalSince1970, forKey: ScreenTimeConfig.daLastStartErrorTimeKey)
            }
            return false
        }
    }

    /// Fires ~30s before planned unlock end so the user can return if background re-lock is delayed.
    private func scheduleUnlockThirtySecondWarningNotification() {
        cancelUnlockThirtySecondWarningNotification()
        guard let plannedEnd = activeSessionPlannedEndDate else { return }
        let fireDate = plannedEnd.addingTimeInterval(-30)
        let delay = fireDate.timeIntervalSinceNow
        guard delay > 0.5 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Unlock ending soon"
        content.body = "You have 30 seconds left. Get back to work now."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.unlockThirtySecondWarningNotificationID,
            content: content,
            trigger: trigger
        )
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let ok: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                ok = true
            case .notDetermined:
                ok = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            default:
                ok = false
            }
            guard ok else { return }
            try? await center.add(request)
        }
    }

    private func cancelUnlockThirtySecondWarningNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.unlockThirtySecondWarningNotificationID]
        )
    }

    // MARK: - Time calculations (today + streak)

    func usedSecondsToday(now: Date = Date()) -> TimeInterval {
        usedSeconds(on: now, now: now)
    }

    func usedSeconds(on day: Date, now: Date = Date()) -> TimeInterval {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 3600)

        // Completed sessions
        var total: TimeInterval = 0
        for s in sessionRecords {
            let overlapStart = max(s.startDate, dayStart)
            let overlapEnd = min(s.endDate, dayEnd)
            if overlapEnd > overlapStart {
                total += overlapEnd.timeIntervalSince(overlapStart)
            }
        }

        // Active session contributes to whichever day it overlaps (important for cross-midnight sessions).
        if let start = activeSessionStartDate {
            let activeEnd = activeSessionPlannedEndDate ?? now
            let overlapStart = max(start, dayStart)
            let overlapEnd = min(min(now, activeEnd), dayEnd)
            if overlapEnd > overlapStart {
                total += overlapEnd.timeIntervalSince(overlapStart)
            }
        }

        return total
    }

    // Real persisted streak:
    // Starts at 0 and updates once per completed calendar day (local midnight).
    // Streak increases if that day's unlock usage is at or under the daily limit; otherwise resets to 0.
    func updateStreakIfNeeded(now: Date = Date()) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let limit = TimeInterval(dailyLimitSeconds)

        guard let lastProcessed = lastStreakProcessedDayStart else {
            // First app launch / account creation baseline.
            streakDays = 0
            lastStreakProcessedDayStart = today
            return
        }

        guard lastProcessed < today else { return }

        var dayToEvaluate = lastProcessed
        while dayToEvaluate < today {
            let used = usedSeconds(on: dayToEvaluate, now: now)
            if used <= limit {
                streakDays += 1
            } else {
                streakDays = 0
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayToEvaluate) else {
                break
            }
            dayToEvaluate = nextDay
        }
        lastStreakProcessedDayStart = today
    }

    func streakCount(now: Date = Date()) -> Int {
        updateStreakIfNeeded(now: now)
        return streakDays
    }

    func minutesLeftToday(now: Date = Date()) -> TimeInterval {
        let limit = TimeInterval(dailyLimitSeconds)
        let used = usedSecondsToday(now: now)
        return max(0, (limit - used) / 60.0)
    }

    func usedMinutesToday(now: Date = Date()) -> TimeInterval {
        usedSecondsToday(now: now) / 60.0
    }

    // MARK: - Derived UI strings

    var formattedLimit: String {
        let h = dailyLimitHours
        let m = dailyLimitMinutes
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// Goals that apply to the local calendar day containing `now` (non-repeating, daily, or weekly on the anchor day).
    func goalsForToday(now: Date = Date()) -> [Goal] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        return goals.filter { $0.matchesCalendarDay(dayStart, calendar: calendar) }
    }

    /// All Goals screen: every **repeating** goal (daily + weekly), plus **non-repeating** goals whose local day is `now` (removed from storage after that day ends via pruning).
    func goalsForAllGoalsPage(now: Date = Date()) -> [Goal] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        return goals.filter { goal in
            goal.isRepeating || goal.matchesCalendarDay(dayStart, calendar: calendar)
        }
    }

    var primaryGoalText: String {
        goalsForToday().first?.text ?? "Your goal"
    }

    // MARK: - Unlock duration defaults
    static let defaultUnlockDurationSeconds: TimeInterval = 5 * 60
}

// MARK: - Local notifications for timed goal reminders

actor GoalReminderScheduler {
    static let shared = GoalReminderScheduler()
    private let center = UNUserNotificationCenter.current()
    private let idPrefix = "goal-reminder-"

    func syncReminders(for goals: [Goal]) async {
        do {
            let granted = try await requestAuthorizationIfNeeded()
            guard granted else { return }
            // Clear all previous reminders managed by this app section.
            await clearAllManagedReminders()
            // Rebuild from current goals.
            for goal in goals {
                guard goal.isTimed, let targetTime = goal.targetTime else { continue }

                let id = idPrefix + goal.id.uuidString
                let content = UNMutableNotificationContent()
                content.title = "Goal Reminder"
                content.body = goal.text
                content.sound = .default

                let calendar = Calendar.current
                let trigger: UNNotificationTrigger?

                switch goal.repeatFrequency {
                case .daily:
                    var components = calendar.dateComponents([.hour, .minute], from: targetTime)
                    trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                case .weekly:
                    var components = calendar.dateComponents([.hour, .minute], from: targetTime)
                    let weekday = goal.weeklyAnchorWeekday ?? calendar.component(.weekday, from: Date())
                    components.weekday = weekday
                    trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                case .none:
                    trigger = Self.oneTimeTriggerOnValidDay(
                        targetTime: targetTime,
                        validDayStart: goal.nonRepeatingDayStart
                    )
                }

                guard let trigger else { continue }
                let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
                try await center.add(request)
            }
        } catch {
            // Silent fail for now; we avoid blocking core UX if notification scheduling fails.
        }
    }

    private func requestAuthorizationIfNeeded() async throws -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            // Do not auto-prompt during onboarding/app startup.
            return false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func clearAllManagedReminders() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Single fire on the goal’s valid local calendar day at `targetTime`’s clock time, only if still in the future.
    private static func oneTimeTriggerOnValidDay(targetTime: Date, validDayStart: Date?, now: Date = Date()) -> UNNotificationTrigger? {
        let cal = Calendar.current
        let dayStart = validDayStart.map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: now)
        let hm = cal.dateComponents([.hour, .minute], from: targetTime)
        var base = cal.dateComponents([.year, .month, .day], from: dayStart)
        base.hour = hm.hour
        base.minute = hm.minute
        base.second = 0
        guard let fireDate = cal.date(from: base), fireDate > now else { return nil }
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        return UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
    }
}

// MARK: - Root container / routing

private enum Route: Hashable {
    case chat
    case settings
    case addGoal
    case editGoal(Goal)
    case allGoals
}

struct ContentView: View {
    @StateObject private var store = PhoneLockStore()
    @State private var navPath: [Route] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.hasOnboarded {
                NavigationStack(path: $navPath) {
                    ZStack(alignment: .top) {
                        HomeDashboardView(
                            store: store,
                            onStartChat: { navPath.append(.chat) },
                            onOpenSettings: { navPath.append(.settings) },
                            onAddGoal: { navPath.append(.addGoal) },
                            onEditGoal: { goal in navPath.append(.editGoal(goal)) },
                            onSeeAllGoals: { navPath.append(.allGoals) }
                        )
                        .allowsHitTesting(!store.isUnlockActive)

                        if store.isUnlockActive {
                            ActiveUnlockStickyView(store: store, onEnd: {
                                store.endActiveUnlock()
                            })
                        }
                    }
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .chat:
                            ChatUnlockView(
                                store: store,
                                onUnlock: { minutes in
                                    store.startUnlock(durationMinutes: minutes, isEmergency: false)
                                    navPath.removeAll()
                                }
                            )
                        case .settings:
                            SettingsView(
                                store: store,
                                onEmergencyUnlock: { durationMinutes in
                                    guard store.canStartEmergencyUnlock else { return }
                                    store.startEmergencyUnlockIfAllowed(durationMinutes: durationMinutes)
                                    navPath.removeAll()
                                },
                                onDailyLimitSaved: {
                                    navPath.removeAll()
                                }
                            )
                        case .addGoal:
                            AddGoalView(
                                mode: .add,
                                onSave: { goal in
                                    store.goals.append(goal)
                                    navPath.removeAll()
                                },
                                onCancel: { navPath.removeLast() }
                            )
                        case .editGoal(let existing):
                            AddGoalView(
                                mode: .edit(existing),
                                onSave: { updated in
                                    if let idx = store.goals.firstIndex(where: { $0.id == updated.id }) {
                                        store.goals[idx] = updated
                                    }
                                    navPath.removeAll()
                                },
                                onCancel: { navPath.removeLast() }
                            )
                        case .allGoals:
                            AllGoalsView(
                                store: store,
                                onAddGoal: { navPath.append(.addGoal) },
                                onEditGoal: { goal in navPath.append(.editGoal(goal)) }
                            )
                        }
                    }
                }
                .environmentObject(store)
            } else {
                OnboardingView(store: store, onDone: {
                    store.hasOnboarded = true
                })
                .environmentObject(store)
            }
        }
        .onAppear {
            store.reconcileActiveUnlockIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                store.reconcileActiveUnlockIfNeeded()
                store.pruneExpiredNoneRepeatGoalsIfNeeded()
                store.updateStreakIfNeeded()
            } else {
                // Re-apply immediately when transitioning away from active as a best-effort sync.
                store.reconcileActiveUnlockIfNeeded()
            }
        }
        .task {
            // Keep unlock state authoritative even if the sticky view is not visible.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    store.reconcileActiveUnlockIfNeeded()
                }
            }
        }
    }
}

// MARK: - Screen 1) Onboarding

private enum OnboardingDailyHabit: String, CaseIterable, Identifiable {
    case gym
    case readBook
    case meditate
    case journal
    case drinkWater
    case sleepEnough
    case bedOnTime
    case wakeOnTime
    case outside
    case sunlight
    case homework
    case study
    case makeBed
    case instrument
    case puzzle
    case hug
    case dailySchedule
    case run
    case walk
    case steps
    case cleanRoom
    case eatHealthy
    case trackCalories
    case shower
    case brushTeeth
    case floss
    case walkDog
    case noPhoneBeforeBed
    case noPhoneWhileEating
    case gratitude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gym: return "🏋️ Go to the gym"
        case .readBook: return "📖 Read a book"
        case .meditate: return "🧘 Meditate"
        case .journal: return "📝 Journal"
        case .drinkWater: return "💧 Drink enough water"
        case .sleepEnough: return "😴 Get enough sleep"
        case .bedOnTime: return "🛌 Go to bed on time"
        case .wakeOnTime: return "⏰ Wake up on time"
        case .outside: return "🌲 Go outside"
        case .sunlight: return "☀️ Get enough sunlight"
        case .homework: return "📚 Do your homework"
        case .study: return "🙇‍♂️ Study"
        case .makeBed: return "🛏️ Make your bed"
        case .instrument: return "🎸 Play an instrument"
        case .puzzle: return "🧩 Work on a puzzle"
        case .hug: return "🫂 Hug a friend or loved one"
        case .dailySchedule: return "🗓️ Write a daily schedule"
        case .run: return "🏃 Go for a run"
        case .walk: return "🚶‍♂️ Go for a walk"
        case .steps: return "👣 Hit your step count goal"
        case .cleanRoom: return "🧹 Clean your room"
        case .eatHealthy: return "🥗 Eat Healthy"
        case .trackCalories: return "🥪 Track your calories"
        case .shower: return "🚿 Take a shower"
        case .brushTeeth: return "🪥 Brush your teeth"
        case .floss: return "🦷 Floss your teeth"
        case .walkDog: return "🦮 Walk the dog"
        case .noPhoneBeforeBed: return "📵 No phone before bed"
        case .noPhoneWhileEating: return "🍽️ No phone while eating"
        case .gratitude: return "🙏 Practice Gratitude"
        }
    }
}

private enum OnboardingWhyLessPhone: String, CaseIterable, Identifiable {
    case cantFocus
    case wastingTime
    case hurtingSleep
    case distracted
    case notProductive
    case feelWorse
    case bePresent
    case controlHabits
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cantFocus: return "🧠 I can’t focus on what matters"
        case .wastingTime: return "⏰ I feel like I’m wasting time"
        case .hurtingSleep: return "😴 It’s hurting my sleep"
        case .distracted: return "😵 I feel distracted all the time"
        case .notProductive: return "📉 I’m not being productive"
        case .feelWorse: return "😔 I feel worse after using it"
        case .bePresent: return "🧑‍🤝‍🧑 I want to be more present with people"
        case .controlHabits: return "📵 I want more control over my habits"
        case .other: return "Other"
        }
    }
}

private enum OnboardingPhoneStruggle: String, CaseIterable, Identifiable {
    case pickupWithoutThinking
    case scrollTooLong
    case loseTrackOfTime
    case checkDuringFocus
    case lateAtNight
    case firstThingMorning
    case struggleToStop
    case distractedByNotifications
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pickupWithoutThinking: return "📱 I pick up my phone without thinking"
        case .scrollTooLong: return "🔁 I keep scrolling longer than I planned"
        case .loseTrackOfTime: return "🕒 I lose track of time when I’m on my phone"
        case .checkDuringFocus: return "🧠 I check my phone while trying to focus"
        case .lateAtNight: return "🌙 I use my phone late at night"
        case .firstThingMorning: return "⏰ I check my phone first thing in the morning"
        case .struggleToStop: return "📵 I struggle to stop once I start using it"
        case .distractedByNotifications: return "🔔 I get distracted by notifications"
        case .other: return "Other"
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var store: PhoneLockStore
    var onDone: () -> Void

    @State private var onboardingStep: Int = 0
    @State private var selectedAge: Int = 22
    @State private var selectedWhyIDs: Set<String> = []
    @State private var hoursPerDay: Double = 5
    @State private var hoursUnknown: Bool = false
    @State private var selectedStruggleIDs: Set<String> = []
    @State private var showProjectedYears: Bool = false
    @State private var selectedHabitIDs: Set<String> = []
    @State private var showingAppPicker = false

    private var canProceedFromAgeStep: Bool {
        (13...121).contains(selectedAge)
    }

    private var canProceedFromWhyStep: Bool {
        !selectedWhyIDs.isEmpty
    }

    private var canProceedFromHoursStep: Bool {
        hoursUnknown || (1...23).contains(Int(hoursPerDay.rounded()))
    }

    private var canProceedFromStrugglesStep: Bool {
        !selectedStruggleIDs.isEmpty
    }

    private var effectiveHoursPerDay: Int {
        hoursUnknown ? 5 : Int(hoursPerDay.rounded())
    }

    private var projectedYearsOnPhone: Int {
        let remainingYears = max(0, 100 - selectedAge)
        let projected = (Double(remainingYears) * Double(effectiveHoursPerDay)) / 24.0
        return Int(ceil(projected))
    }

    private var canProceedFromStep1: Bool {
        store.dailyLimitSeconds > 0 && store.blockedAppCount > 0
    }

    private var canFinishOnboarding: Bool {
        !selectedHabitIDs.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                switch onboardingStep {
                case 0:
                    onboardingAgeStep
                case 1:
                    onboardingWhyStep
                case 2:
                    onboardingHoursStep
                case 3:
                    onboardingStrugglesStep
                case 4:
                    onboardingYearsProjectionStep
                case 5:
                    onboardingGoodNewsStep
                case 6:
                    onboardingPaymentStep
                case 7:
                    onboardingNotificationsPermissionStep
                case 8:
                    onboardingScreenTimePermissionStep
                case 9:
                    onboardingStep1
                default:
                    onboardingStep2
                }
            }
            .familyActivityPicker(
                isPresented: $showingAppPicker,
                selection: $store.blockedAppsSelection
            )
            .toolbar {
                if onboardingStep > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") {
                            onboardingStep = max(0, onboardingStep - 1)
                        }
                    }
                }
            }
        }
    }

    private var onboardingAgeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How old are you?")
                .font(.title2.bold())

            Picker("Age", selection: $selectedAge) {
                ForEach(13...121, id: \.self) { age in
                    Text("\(age)").tag(age)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipped()

            Button {
                onboardingStep = 1
            } label: {
                Text("Next")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canProceedFromAgeStep)

            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Onboarding")
        .navigationBarBackButtonHidden(true)
    }

    private var onboardingWhyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Why do you want to spend less time on your phone?")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                LazyVStack(spacing: 10) {
                    ForEach(OnboardingWhyLessPhone.allCases) { reason in
                        onboardingMultiSelectRow(
                            title: reason.title,
                            isOn: selectedWhyIDs.contains(reason.id)
                        ) {
                            toggle(&selectedWhyIDs, id: reason.id)
                        }
                    }
                }

                Button {
                    onboardingStep = 2
                } label: {
                    Text("Next")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProceedFromWhyStep)
                .padding(.top, 8)
            }
            .padding()
        }
        .navigationTitle("Motivation")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private var onboardingHoursStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How many hours a day do you spend on your phone?")
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("\(Int(hoursPerDay.rounded())) hour\(Int(hoursPerDay.rounded()) == 1 ? "" : "s")")
                    .font(.headline)
                Slider(value: $hoursPerDay, in: 1...23, step: 1)
                    .disabled(hoursUnknown)
                    .opacity(hoursUnknown ? 0.45 : 1)
            }
            .padding(14)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                hoursUnknown.toggle()
            } label: {
                HStack {
                    Text("I don’t know")
                        .font(.body.weight(.semibold))
                    Spacer()
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(hoursUnknown ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(hoursUnknown ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                onboardingStep = 3
            } label: {
                Text("Next")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canProceedFromHoursStep)
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Screen time")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private var onboardingStrugglesStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("In what ways do you struggle with spending time on your phone?")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                LazyVStack(spacing: 10) {
                    ForEach(OnboardingPhoneStruggle.allCases) { struggle in
                        onboardingMultiSelectRow(
                            title: struggle.title,
                            isOn: selectedStruggleIDs.contains(struggle.id)
                        ) {
                            toggle(&selectedStruggleIDs, id: struggle.id)
                        }
                    }
                }

                Button {
                    onboardingStep = 4
                } label: {
                    Text("Next")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProceedFromStrugglesStep)
                .padding(.top, 8)
            }
            .padding()
        }
        .navigationTitle("Challenges")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private var onboardingYearsProjectionStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Here’s how many years you’ll be spending on your phone:")
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Group {
                if showProjectedYears {
                    Text("\(projectedYearsOnPhone) years")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Calculating...")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)

            Spacer(minLength: 0)

            if showProjectedYears {
                Text("But it doesn’t have to be like this...")
                    .font(.system(.title3, design: .default).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Button {
                onboardingStep = 5
            } label: {
                Text("Next")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 8)
            .opacity(showProjectedYears ? 1 : 0)
            .disabled(!showProjectedYears)
        }
        .padding()
        .navigationTitle("Your projection")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            showProjectedYears = false
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await MainActor.run {
                    showProjectedYears = true
                }
            }
        }
    }

    private var onboardingGoodNewsStep: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: geometry.size.height * 0.18)

                Text("Here is the good news. With PhoneLockAI, you can get back all these years and live your life more mindfully!")
                    .font(.system(size: 31, weight: .bold, design: .default))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()
                    .frame(height: geometry.size.height * 0.28)

                Button {
                    onboardingStep = 6
                } label: {
                    Text("Get started now")
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                Spacer(minLength: geometry.size.height * 0.14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding()
        }
        .navigationTitle("PhoneLockAI")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private var onboardingPaymentStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your plan")
                .font(.title2.bold())

            Text("Start with a 7 day free trial. Cancel anytime.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                onboardingStep = 7
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Monthly")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        Text("$4.99")
                            .font(.title3.weight(.bold))
                    }
                    Text("7 day free trial, then $4.99 per month")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                onboardingStep = 7
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Yearly")
                            .font(.headline.weight(.semibold))
                        Spacer()
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("$3.33")
                                .font(.title3.weight(.bold))
                            Text("/mo")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("7 day free trial, then $39.99 per year")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Free Trial")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private var onboardingNotificationsPermissionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)

            Text("Stay on track with reminders")
                .font(.title2.bold())

            Text("Enable notifications so PhoneLockAI can remind you when your unlock session is ending and when goals are due.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task {
                    _ = await store.requestNotificationAuthorization()
                    await MainActor.run {
                        onboardingStep = 8
                    }
                }
            } label: {
                Text("Allow notifications")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                onboardingStep = 8
            } label: {
                Text("Not now")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private var onboardingScreenTimePermissionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)

            Text("Enable Screen Time access")
                .font(.title2.bold())

            Text("This lets PhoneLockAI block selected apps until your unlock timer is active.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("When the iOS popup appears, tap Continue (left button).")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("“PhoneLockAI” Would Like to Access Screen Time")
                            .font(.headline)
                        Text("Providing access to Screen Time may allow it to see your activity data, restrict content, and limit app usage.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)

                    Divider()

                    HStack(spacing: 10) {
                        Text("Continue")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.secondary.opacity(0.16))
                            .clipShape(Capsule())
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(Color.red, lineWidth: 2)
                            )

                        Text("Don’t Allow")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    .padding(12)
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
            }

            Button {
                Task {
                    await store.requestFamilyControlsAuthorizationIfNeeded()
                    await MainActor.run {
                        onboardingStep = 9
                    }
                }
            } label: {
                Text("Open Screen Time prompt")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                onboardingStep = 9
            } label: {
                Text("Not now")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Screen Time")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private var onboardingStep1: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PhoneLockAI")
                        .font(.title.bold())
                    Text("Set your daily unlock limit and choose which apps to block. Next, you'll pick daily habits to work toward.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                GroupBox(label: Text("Daily Limit (hrs/mins)").font(.subheadline).foregroundStyle(.secondary)) {
                    VStack(spacing: 12) {
                        HStack {
                            Stepper("\(store.dailyLimitHours) hrs", value: $store.dailyLimitHours, in: 0...23)
                        }
                        HStack {
                            Stepper("\(store.dailyLimitMinutes) mins", value: $store.dailyLimitMinutes, in: 0...59, step: 5)
                        }
                    }
                    .padding(.vertical, 6)
                }

                GroupBox(label: Text("Blocked Apps").font(.subheadline).foregroundStyle(.secondary)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Choose the apps you want PhoneLockAI to block when you're locked.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button {
                            showingAppPicker = true
                        } label: {
                            Text(store.blockedAppCount == 0 ? "Select Blocked Apps" : "Edit Blocked Apps (\(store.blockedAppCount))")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        if store.blockedAppCount == 0 {
                            Text("Select at least one app to continue.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(store.blockedAppTokens, id: \.self) { token in
                                        Label(token)
                                            .lineLimit(1)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(.thinMaterial)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }

                Button {
                    onboardingStep = 10
                } label: {
                    Text("Next")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProceedFromStep1)
                .padding(.top, 8)
            }
            .padding()
        }
        .navigationTitle("Onboarding")
        .navigationBarBackButtonHidden(true)
    }

    private var onboardingStep2: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What are some daily habits you’d like to implement?")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                Text("Tap the habits you want as daily goals. You can change them later from the home screen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVStack(spacing: 10) {
                    ForEach(OnboardingDailyHabit.allCases) { habit in
                        let isOn = selectedHabitIDs.contains(habit.id)
                        Button {
                            if isOn {
                                selectedHabitIDs.remove(habit.id)
                            } else {
                                selectedHabitIDs.insert(habit.id)
                            }
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                Text(habit.title)
                                    .font(.body)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                            .background(isOn ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if selectedHabitIDs.isEmpty {
                    Text("Select at least one habit to continue, or skip for now.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    applySelectedHabitsAsDailyGoals()
                    onDone()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canFinishOnboarding)
                .padding(.top, 8)

                Button {
                    onDone()
                } label: {
                    Text("Skip")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("Daily habits")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func onboardingMultiSelectRow(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(isOn ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ set: inout Set<String>, id: String) {
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
    }

    private func applySelectedHabitsAsDailyGoals() {
        let ordered = OnboardingDailyHabit.allCases.filter { selectedHabitIDs.contains($0.id) }
        store.goals = ordered.map { Goal(text: $0.title, repeatFrequency: .daily) }
    }
}

// MARK: - Screen 2) Home Dashboard

struct HomeDashboardView: View {
    @ObservedObject var store: PhoneLockStore
    var onStartChat: () -> Void
    var onOpenSettings: () -> Void
    var onAddGoal: () -> Void
    var onEditGoal: (Goal) -> Void
    var onSeeAllGoals: () -> Void
    // For the mock: keep Home's ring updated on state changes.
    // (The sticky countdown during an active unlock session provides the real-time UX.)
    @State private var now: Date = Date()
    @State private var midnightRefreshTask: Task<Void, Never>? = nil
    private static let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long   // "March 25, 2026" (locale-aware)
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center) {
                        Text("PhoneLockAI")
                            .font(.largeTitle.bold())
                        Spacer()
                        Button {
                            onOpenSettings()
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.title2)
                        }
                        .accessibilityLabel("Settings")
                    }

                    Text("Today, \(Self.todayFormatter.string(from: now))")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 23)

                    HomeStatusView(store: store, now: now)
                        .padding(.top, 60)
                    GoalsListView(
                        store: store,
                        now: now,
                        onAddGoal: onAddGoal,
                        onEditGoal: onEditGoal,
                        onSeeAllGoals: onSeeAllGoals
                    )
                    HomeActionsView(store: store, onStartChat: onStartChat)
                }
                .padding()
            }
            .onAppear { now = Date() }
            .onAppear {
                // Keep the "Today, ..." label accurate while the app stays open.
                // We refresh once per day, right after the next local midnight.
                midnightRefreshTask?.cancel()
                midnightRefreshTask = Task { @MainActor in
                    while !Task.isCancelled {
                        let nextMidnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date().addingTimeInterval(24*3600)
                        let delaySeconds = max(0, nextMidnight.timeIntervalSince(Date()))
                        let delayNanos = UInt64(delaySeconds * 1_000_000_000)
                        do {
                            try await Task.sleep(nanoseconds: delayNanos)
                        } catch {
                            break
                        }
                        now = Date()
                    }
                }
            }
            .onDisappear {
                midnightRefreshTask?.cancel()
                midnightRefreshTask = nil
            }
            .onChange(of: store.isUnlockActive) { _, _ in
                // Refresh once when sessions start/end; Home visual is derived from accumulated active time.
                now = Date()
            }
        )
    }
}

fileprivate func formatMinutes(_ minutes: TimeInterval) -> String {
    let totalMinutes = Int(minutes.rounded(.down))
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    if h > 0 && m > 0 { return "\(h)h \(m)m" }
    if h > 0 { return "\(h)h" }
    return "\(m)m"
}

fileprivate func formatHoursMinutes(_ seconds: TimeInterval) -> String {
    let totalMinutes = max(0, Int((seconds / 60.0).rounded(.down)))
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    return "\(h) hr " + String(format: "%02d", m) + " min"
}

struct HomeStatusView: View {
    @ObservedObject var store: PhoneLockStore
    let now: Date

    var body: some View {
        let limitSeconds = Double(store.dailyLimitSeconds)
        let usedSeconds = store.usedSecondsToday(now: now)
        let fractionUsed: Double = limitSeconds > 0 ? min(1.0, usedSeconds / limitSeconds) : 0
        let isOver = usedSeconds > limitSeconds
        let streak = store.streakCount(now: now)
        let streakSuffix = streak == 1 ? "" : "s"

        return VStack(alignment: .center, spacing: 10) {
            ZStack {
                ProgressRingView(
                    fraction: fractionUsed,
                    tint: isOver ? .red : .blue
                )
                .frame(width: 210, height: 210)

                Text(formatHoursMinutes(usedSeconds))
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
            }

            Text("Of \(formatHoursMinutes(limitSeconds))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("🔥 Streak: \(streak) day" + streakSuffix)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct GoalsListView: View {
    @ObservedObject var store: PhoneLockStore
    let now: Date
    let onAddGoal: () -> Void
    let onEditGoal: (Goal) -> Void
    let onSeeAllGoals: () -> Void
    @State private var selectedGoalID: UUID?
    @State private var showGoalActions = false
    @State private var celebratingGoalIDs: Set<UUID> = []

    private var todaysGoals: [Goal] {
        store.goalsForToday(now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Today's Goals")
                    .font(.headline)
                Spacer()
                Button {
                    onAddGoal()
                } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.bold())
                        .padding(8)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Circle())
                }
                .accessibilityLabel("Add Goal")
            }

            if todaysGoals.isEmpty {
                Text("No goals for today.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(todaysGoals) { goal in
                        GoalRowView(
                            text: goal.text,
                            isCompleted: goal.isCompleted(on: now),
                            isCelebrating: celebratingGoalIDs.contains(goal.id),
                            onToggleCompletion: {
                                if toggleComplete(for: goal.id) {
                                    triggerCelebration(for: goal.id)
                                }
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedGoalID = goal.id
                            showGoalActions = true
                        }
                    }
                }
            }

            Button {
                onSeeAllGoals()
            } label: {
                Text("See all goals")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .confirmationDialog(
            "Goal Options",
            isPresented: $showGoalActions,
            titleVisibility: .visible
        ) {
            if let goal = selectedGoal {
                Button("Edit Goal") {
                    onEditGoal(goal)
                    selectedGoalID = nil
                }
                Button(goal.isCompleted(on: now) ? "Mark as Incomplete" : "Mark as Complete") {
                    if toggleComplete(for: goal.id) {
                        triggerCelebration(for: goal.id)
                    }
                }
                Button("Delete Goal", role: .destructive) {
                    store.goals.removeAll { $0.id == goal.id }
                    selectedGoalID = nil
                }
            }
            Button("Cancel", role: .cancel) {
                selectedGoalID = nil
            }
        }
    }

    private var selectedGoal: Goal? {
        guard let selectedGoalID else { return nil }
        return todaysGoals.first(where: { $0.id == selectedGoalID })
    }

    @discardableResult
    private func toggleComplete(for id: UUID) -> Bool {
        guard let idx = store.goals.firstIndex(where: { $0.id == id }) else { return false }
        var g = store.goals[idx]
        g.toggleCompletion(on: now)
        store.goals[idx] = g
        return g.isCompleted(on: now)
    }

    private func triggerCelebration(for id: UUID) {
        celebratingGoalIDs.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            celebratingGoalIDs.remove(id)
        }
    }
}

struct AllGoalsView: View {
    @ObservedObject var store: PhoneLockStore
    let onAddGoal: () -> Void
    let onEditGoal: (Goal) -> Void
    @State private var selectedGoalID: UUID?
    @State private var showGoalActions = false
    @State private var now: Date = Date()

    private var listedGoals: [Goal] {
        store.goalsForAllGoalsPage(now: now)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if listedGoals.isEmpty {
                    Text("No goals yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 10) {
                        ForEach(listedGoals) { goal in
                            GoalRowView(
                                text: goal.text,
                                showsCompletionControl: false,
                                isCompleted: false,
                                isCelebrating: false,
                                onToggleCompletion: {}
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedGoalID = goal.id
                                showGoalActions = true
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("All Goals")
        .onAppear { now = Date() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onAddGoal()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Goal")
            }
        }
        .confirmationDialog(
            "Goal Options",
            isPresented: $showGoalActions,
            titleVisibility: .visible
        ) {
            if let goal = selectedGoal {
                Button("Edit Goal") {
                    onEditGoal(goal)
                    selectedGoalID = nil
                }
                Button("Delete Goal", role: .destructive) {
                    store.goals.removeAll { $0.id == goal.id }
                    selectedGoalID = nil
                }
            }
            Button("Cancel", role: .cancel) {
                selectedGoalID = nil
            }
        }
    }

    private var selectedGoal: Goal? {
        guard let selectedGoalID else { return nil }
        return listedGoals.first(where: { $0.id == selectedGoalID })
    }
}

struct GoalRowView: View {
    let text: String
    var showsCompletionControl: Bool = true
    let isCompleted: Bool
    let isCelebrating: Bool
    let onToggleCompletion: () -> Void
    @State private var confettiProgress: CGFloat = 1
    private let confettiColors: [Color] = [.yellow, .orange, .pink, .green, .blue, .purple]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if showsCompletionControl {
                Button {
                    onToggleCompletion()
                } label: {
                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isCompleted ? Color.green : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCompleted ? "Mark goal as incomplete" : "Mark goal as complete")
            }
            Text(text)
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if showsCompletionControl {
                GeometryReader { geo in
                    ZStack {
                        ForEach(0..<14, id: \.self) { i in
                            let angle = Angle(degrees: Double(-145 + (i * 18)))
                            let distance = CGFloat(16 + (i % 5) * 8)
                            let dx = cos(angle.radians) * distance * confettiProgress
                            let dy = sin(angle.radians) * distance * confettiProgress + (confettiProgress * confettiProgress * 8)
                            let size = CGFloat(3 + (i % 3))
                            let rotation = Angle(degrees: Double(i * 24)) + .degrees(Double(confettiProgress * 300))

                            Group {
                                if i.isMultiple(of: 2) {
                                    RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                                        .fill(confettiColors[i % confettiColors.count])
                                        .frame(width: size + 1, height: size)
                                } else {
                                    Circle()
                                        .fill(confettiColors[i % confettiColors.count])
                                        .frame(width: size, height: size)
                                }
                            }
                            .rotationEffect(rotation)
                            .offset(x: dx, y: dy)
                            .opacity(Double(1 - confettiProgress))
                        }
                    }
                    .position(x: 18, y: geo.size.height / 2)
                }
                .allowsHitTesting(false)
            }
        }
        .onChange(of: isCelebrating) { _, newValue in
            guard showsCompletionControl else { return }
            guard newValue else {
                confettiProgress = 1
                return
            }
            confettiProgress = 0
            withAnimation(.easeOut(duration: 0.55)) {
                confettiProgress = 1
            }
        }
    }
}

struct HomeActionsView: View {
    @ObservedObject var store: PhoneLockStore
    let onStartChat: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button {
                onStartChat()
            } label: {
                Text("Start Chat")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isUnlockActive)
        }
    }
}

struct ProgressRingView: View {
    var fraction: Double // 0...1
    var tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 10)
            Circle()
                .trim(from: 0, to: CGFloat(fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Screen 3/4) Real Chat Unlock Flow

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    let role: OpenAIChatRole
    let content: String
}

enum OpenAIChatRole: String, Codable, Hashable {
    case system
    case user
    case assistant
}

enum OpenAIError: LocalizedError {
    case missingBackendURL
    case badResponse
    case emptyResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .missingBackendURL:
            return "Missing backend URL. Set BACKEND_CHAT_URL in Info.plist."
        case .badResponse:
            return "Backend request failed."
        case .emptyResponse:
            return "Backend returned an empty response."
        case .timeout:
            return "Request timed out."
        }
    }
}

struct OpenAIService {
    private struct BackendRequest: Codable {
        struct Message: Codable {
            let role: String
            let content: String
        }

        let messages: [Message]
        let goals: [String]
    }

    private struct BackendResponse: Codable {
        let assistant: String
    }

    func send(conversation: [ChatMessage], goals: [String]) async throws -> String {
        let backendURL = resolveBackendURL()
        guard !backendURL.isEmpty, let url = URL(string: backendURL) else {
            throw OpenAIError.missingBackendURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let msgs: [BackendRequest.Message] = conversation.map {
            .init(role: $0.role.rawValue, content: $0.content)
        }

        let payload = BackendRequest(
            messages: msgs,
            goals: goals
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OpenAIError.badResponse
        }
        let decoded = try JSONDecoder().decode(BackendResponse.self, from: data)
        let text = decoded.assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenAIError.emptyResponse
        }
        return text
    }

    private func resolveBackendURL() -> String {
        if let plist = Bundle.main.object(forInfoDictionaryKey: "BACKEND_CHAT_URL") as? String, !plist.isEmpty {
            return plist
        }
        return ""
    }
}

struct ChatUnlockView: View {
    @ObservedObject var store: PhoneLockStore
    var onUnlock: (Int) -> Void

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isLoading: Bool = false
    @State private var errorText: String?
    @State private var unlockMinutes: Int?
    @State private var fallbackUnlockCountdownSeconds: Int = 0

    private let openAI = OpenAIService()
    private let chatFailureFallbackText = "An error has occoured. Use this quick 15 minute unlock"

    var body: some View {
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { message in
                            HStack {
                                if message.role == .assistant {
                                    ChatBubble(text: message.content, isUser: false)
                                    Spacer()
                                } else {
                                    Spacer()
                                    ChatBubble(text: message.content, isUser: true)
                                }
                            }
                        }

                        if let errorText {
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last?.id {
                        withAnimation {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }

            if let minutes = unlockMinutes {
                let isFallbackUnlock = (errorText == chatFailureFallbackText && minutes == 15)
                Button {
                    onUnlock(minutes)
                } label: {
                    if isFallbackUnlock && fallbackUnlockCountdownSeconds > 0 {
                        Text("Unlock for \(minutes) minutes (\(fallbackUnlockCountdownSeconds)s)")
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Unlock for \(minutes) minutes")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFallbackUnlock && fallbackUnlockCountdownSeconds > 0)
                .padding(.horizontal)
            }

            HStack(spacing: 8) {
                TextField("Type your message...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)

                Button {
                    Task { await sendMessage() }
                } label: {
                    if isLoading {
                        ProgressView()
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                }
                .disabled(isLoading || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .navigationTitle("Start Chat")
        .onAppear {
            if messages.isEmpty {
                messages.append(
                    ChatMessage(
                        role: .assistant,
                        content: "Why do you want to unlock right now? Please be specific, and include how many minutes you need."
                    )
                )
            }
        }
    }

    private func sendMessage() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorText = nil
        unlockMinutes = nil
        fallbackUnlockCountdownSeconds = 0
        inputText = ""
        messages.append(ChatMessage(role: .user, content: trimmed))
        isLoading = true
        defer { isLoading = false }

        do {
            let assistantText = try await sendMessageWithTimeout(
                conversation: messages,
                goals: store.goalsForToday().map(\.text),
                timeoutSeconds: 10
            )
            messages.append(ChatMessage(role: .assistant, content: assistantText))
            // Unlock button only when assistant uses the exact phrase from PhoneLockAI prompt.txt:
            // "Unlocking for {number of minutes} now!"  e.g. "Unlocking for 5 now!" or "Unlocking for 5 minutes now!"
            if let minutes = extractUnlockPhraseMinutes(from: assistantText) {
                unlockMinutes = minutes
            } else {
                unlockMinutes = nil
            }
        } catch {
            errorText = chatFailureFallbackText
            unlockMinutes = 15
            startFallbackUnlockCountdown()
        }
    }

    private func startFallbackUnlockCountdown() {
        fallbackUnlockCountdownSeconds = 15
        Task {
            while fallbackUnlockCountdownSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard errorText == chatFailureFallbackText, unlockMinutes == 15 else { return }
                fallbackUnlockCountdownSeconds -= 1
            }
        }
    }

    private func sendMessageWithTimeout(
        conversation: [ChatMessage],
        goals: [String],
        timeoutSeconds: UInt64
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await openAI.send(conversation: conversation, goals: goals)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw OpenAIError.timeout
            }

            guard let first = try await group.next() else {
                throw OpenAIError.badResponse
            }
            group.cancelAll()
            return first
        }
    }

    /// Matches only the permitted-unlock line from the system prompt (case-insensitive).
    private func extractUnlockPhraseMinutes(from text: String) -> Int? {
        // Unlocking for 5 now!  OR  Unlocking for 5 minutes now!
        let pattern = #"(?i)Unlocking\s+for\s+(\d{1,4})(?:\s+minutes?)?\s+now!"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let numRange = Range(match.range(at: 1), in: text),
              let value = Int(text[numRange]) else { return nil }
        return max(1, value)
    }
}

struct ChatBubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        Text(text)
            .padding(12)
            .background(isUser ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 280, alignment: isUser ? .trailing : .leading)
    }
}

// MARK: - Legacy mock screens (kept for reference)

struct UnlockRequestView: View {
    @ObservedObject var store: PhoneLockStore
    var onContinue: (String) -> Void

    @State private var whyText: String = ""
    @State private var didSend: Bool = false

    var canSend: Bool {
        !whyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unlock Request")
                .font(.title2.bold())

            if let firstGoal = store.goals.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Goal reminder")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(firstGoal.text)
                        .font(.headline)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Why do you want to unlock?")
                    .foregroundStyle(.secondary)

                TextField("Type a short reason...", text: $whyText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
            }

            Button {
                didSend = true
                onContinue(whyText)
            } label: {
                Text("Send")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)

            Spacer()
        }
        .padding()
        .navigationTitle("Start Chat")
    }
}

// MARK: - Screen 4) AI Reflection / Decision (mock)

struct AIReflectionDecisionView: View {
    @ObservedObject var store: PhoneLockStore
    var why: String

    var onUnlock: () -> Void
    var onStayLocked: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Reflection")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                MessageBubble(text: "Got it. Take a quick moment before you unlock.", alignment: .leading)
                MessageBubble(text: "Remember your goal: \"\(store.primaryGoalText)\".\nDoes unlocking now support it?", alignment: .leading)
            }

            // Intentionally fixed duration; mock unlock button generated one-at-a-time.
            Button {
                onUnlock()
            } label: {
                Text("Unlock for 5 minutes")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                onStayLocked()
            } label: {
                Text("Stay Locked")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .navigationTitle("Reflect")
    }
}

struct MessageBubble: View {
    var text: String
    var alignment: HorizontalAlignment

    var body: some View {
        Text(text)
            .padding(12)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

// MARK: - Screen 5) Active Unlock Session (sticky countdown overlay)

struct ActiveUnlockStickyView: View {
    @ObservedObject var store: PhoneLockStore
    var onEnd: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = timeline.date
            let start = store.activeSessionStartDate ?? now
            let elapsed = now.timeIntervalSince(start)
            let remaining = max(0, store.activeSessionDurationSeconds - elapsed)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.activeSessionIsEmergency ? "Emergency Unlocked" : "Unlocked")
                            .font(.headline)
                        Text("Time left: \(formatCountdown(remaining))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        onEnd()
                    } label: {
                        Text("Lock Now")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                // Auto end when remaining hits 0.
                .onChange(of: remaining <= 0.5) { _, isZeroish in
                    if isZeroish {
                        onEnd()
                    }
                }
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
    }

    private func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Screen 7) Settings

struct SettingsView: View {
    @ObservedObject var store: PhoneLockStore
    var onEmergencyUnlock: (_ durationMinutes: Int) -> Void
    var onDailyLimitSaved: () -> Void

    var body: some View {
        List {
            NavigationLink("My Account") {
                MyAccountView()
            }
            NavigationLink("Edit Daily Limit") {
                EditDailyLimitView(store: store, onSaved: onDailyLimitSaved)
            }
            NavigationLink("Edit Blocked Apps") {
                EditBlockedAppsView(store: store)
            }
            NavigationLink("Contact Us") {
                ContactUsView()
            }
            NavigationLink("Emergency Unlock") {
                EmergencyUnlockSettingsView(
                    store: store,
                    onEmergencyUnlock: onEmergencyUnlock
                )
            }
            NavigationLink("Unlock diagnostics") {
                UnlockDiagnosticsView(store: store)
            }
        }
        .navigationTitle("Settings")
    }
}

struct UnlockDiagnosticsView: View {
    @ObservedObject var store: PhoneLockStore
    @State private var report: String = ""

    var body: some View {
        ScrollView {
            Text(report)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Unlock diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh") { refresh() }
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        report = store.unlockDiagnosticsReport()
    }
}

struct EditDailyLimitView: View {
    @ObservedObject var store: PhoneLockStore
    var onSaved: () -> Void
    @State private var draftHours: Int = 0
    @State private var draftMinutes: Int = 0
    @State private var countdownSeconds: Int = 15

    var body: some View {
        VStack(spacing: 16) {
            Text("Daily Limit")
                .font(.headline)

            HStack(spacing: 0) {
                Picker("Hours", selection: $draftHours) {
                    ForEach(0...23, id: \.self) { value in
                        Text("\(value) hr").tag(value)
                    }
                }
                .pickerStyle(.wheel)

                Picker("Minutes", selection: $draftMinutes) {
                    ForEach(0...60, id: \.self) { value in
                        Text("\(value) min").tag(value)
                    }
                }
                .pickerStyle(.wheel)
            }
            .frame(height: 180)

            Text("Selected: \(draftHours) hr \(draftMinutes) min")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                guard countdownSeconds == 0 else { return }
                store.dailyLimitHours = draftHours
                store.dailyLimitMinutes = draftMinutes
                onSaved()
            } label: {
                if countdownSeconds > 0 {
                    Text("Think Before You Change Your Limit (\(countdownSeconds)s)")
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Save Limit")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(countdownSeconds > 0 ? Color.blue.opacity(0.6) : Color.blue)

            Spacer()
        }
        .padding()
        .navigationTitle("Edit Daily Limit")
        .onAppear {
            draftHours = store.dailyLimitHours
            draftMinutes = store.dailyLimitMinutes
            countdownSeconds = 15
        }
        .task {
            while countdownSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                countdownSeconds -= 1
            }
        }
    }
}

struct EmergencyUnlockSettingsView: View {
    @ObservedObject var store: PhoneLockStore
    var onEmergencyUnlock: (_ durationMinutes: Int) -> Void
    @State private var selectedHours: Int = 0
    @State private var selectedMinutes: Int = 5

    private var selectedTotalMinutes: Int {
        selectedHours * 60 + selectedMinutes
    }

    var body: some View {
        Form {
            Section {
                Text("Emergency unlock starts a temporary unlock session and counts toward your limit.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("You only have a limited unspecified amount of these per month.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Unlock duration") {
                HStack(spacing: 0) {
                    Picker("Hours", selection: $selectedHours) {
                        ForEach(0...23, id: \.self) { value in
                            Text("\(value) hr").tag(value)
                        }
                    }
                    .pickerStyle(.wheel)

                    Picker("Minutes", selection: $selectedMinutes) {
                        ForEach(0...59, id: \.self) { value in
                            Text("\(value) min").tag(value)
                        }
                    }
                    .pickerStyle(.wheel)
                }
                .frame(height: 180)
            }

            Section {
                Toggle("Enable Emergency Unlock", isOn: $store.emergencyUnlockEnabled)
                Button {
                    onEmergencyUnlock(selectedTotalMinutes)
                } label: {
                    Text("Emergency Unlock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canStartEmergencyUnlock || selectedTotalMinutes <= 0)
            }
        }
        .navigationTitle("Emergency Unlock")
    }
}

struct EditBlockedAppsView: View {
    @ObservedObject var store: PhoneLockStore
    @State private var showingAppPicker = false
    @State private var countdownSeconds: Int = 15

    var body: some View {
        List {
            Section {
                Text("Apps in this list are blocked whenever your unlock timer is not active.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Blocked Apps") {
                if store.blockedAppTokens.isEmpty {
                    Text("No blocked apps selected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.blockedAppTokens, id: \.self) { token in
                        Label(token)
                    }
                }
            }

            Section {
                Button {
                    showingAppPicker = true
                } label: {
                    if countdownSeconds > 0 {
                        Text("Edit Blocked Apps (\(countdownSeconds)s)")
                    } else {
                        Text(store.blockedAppTokens.isEmpty ? "Select Blocked Apps" : "Edit Blocked Apps")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(countdownSeconds > 0)
            }
        }
        .navigationTitle("Edit Blocked Apps")
        .onAppear {
            countdownSeconds = 15
        }
        .task {
            while countdownSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                countdownSeconds -= 1
            }
        }
        .task {
            await store.requestFamilyControlsAuthorizationIfNeeded()
        }
        .familyActivityPicker(
            isPresented: $showingAppPicker,
            selection: $store.blockedAppsSelection
        )
    }
}

struct MyAccountView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("My Account")
                .font(.headline)
            Spacer()
        }
        .padding()
        .navigationTitle("My Account")
    }
}

struct ContactUsView: View {
    @Environment(\.openURL) private var openURL
    private let contactEmail = "antibrainrotdaily@gmail.com"

    var body: some View {
        VStack(spacing: 12) {
            Text("Opening your mail app...")
                .font(.headline)
            Button("Open Email") {
                openContactEmail()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle("Contact Us")
        .onAppear {
            openContactEmail()
        }
    }

    private func openContactEmail() {
        guard let url = URL(string: "mailto:\(contactEmail)") else { return }
        openURL(url)
    }
}

struct AddGoalView: View {
    enum Mode: Hashable {
        case add
        case edit(Goal)
    }

    let mode: Mode
    var onSave: (Goal) -> Void
    var onCancel: () -> Void

    @State private var goalName: String = ""
    @State private var repeatFrequency: GoalRepeatFrequency = .none
    @State private var weeklyRepeatWeekday: Int = Calendar.current.component(.weekday, from: Date())
    @State private var isTimed: Bool = false
    @State private var targetTime: Date = Date()

    private var canSave: Bool {
        !goalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var navigationTitle: String {
        switch mode {
        case .add: return "New Goal"
        case .edit: return "Edit Goal"
        }
    }

    private var primaryButtonTitle: String {
        switch mode {
        case .add: return "Save Goal"
        case .edit: return "Save Changes"
        }
    }

    private var weekdayChoices: [(value: Int, label: String)] {
        let symbols = Calendar.current.weekdaySymbols
        return Array(symbols.enumerated()).map { index, name in
            (value: index + 1, label: name)
        }
    }

    /// Weekday (1…7) for weekly goals; preserves existing value on edit unless repeat mode changes.
    private func resolvedWeeklyAnchorWeekday(original: Goal?) -> Int? {
        guard repeatFrequency == .weekly else { return nil }
        if (1...7).contains(weeklyRepeatWeekday) {
            return weeklyRepeatWeekday
        }
        if let original, original.repeatFrequency == .weekly, let existing = original.weeklyAnchorWeekday {
            return existing
        }
        return Calendar.current.component(.weekday, from: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Text("Goal Name").font(.subheadline).foregroundStyle(.secondary)) {
                    TextField("Enter goal name", text: $goalName)
                        .textFieldStyle(.roundedBorder)
                        .padding(.vertical, 6)
                }

                GroupBox(label: Text("Repeating").font(.subheadline).foregroundStyle(.secondary)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How often should this goal repeat?")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Repeat", selection: $repeatFrequency) {
                            Text("None").tag(GoalRepeatFrequency.none)
                            Text("Daily").tag(GoalRepeatFrequency.daily)
                            Text("Weekly").tag(GoalRepeatFrequency.weekly)
                        }
                        .pickerStyle(.segmented)
                        if repeatFrequency == .weekly {
                            VStack {
                                Spacer(minLength: 0)
                                HStack(spacing: 8) {
                                    Text("Repeat Every:")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Picker("Repeat Every", selection: $weeklyRepeatWeekday) {
                                        ForEach(weekdayChoices, id: \.value) { weekday in
                                            Text(weekday.label).tag(weekday.value)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(maxHeight: 32)
                        }
                    }
                    .padding(.vertical, 6)
                }

                GroupBox(label: Text("Timed Reminder?").font(.subheadline).foregroundStyle(.secondary)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Send reminder at a specific time", isOn: $isTimed)
                        if isTimed {
                            DatePicker(
                                "Time",
                                selection: $targetTime,
                                displayedComponents: [.hourAndMinute]
                            )
                            .datePickerStyle(.compact)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Button {
                    let trimmed = goalName.trimmingCharacters(in: .whitespacesAndNewlines)
                    switch mode {
                    case .add:
                        onSave(
                            Goal(
                                text: trimmed,
                                repeatFrequency: repeatFrequency,
                                isTimed: isTimed,
                                targetTime: isTimed ? targetTime : nil,
                                weeklyAnchorWeekday: resolvedWeeklyAnchorWeekday(original: nil)
                            )
                        )
                    case .edit(let original):
                        let (savedIsCompleted, savedCompletedDay): (Bool, Date?) = {
                            switch (original.repeatFrequency, repeatFrequency) {
                            case (.none, .none):
                                return (original.isCompleted, nil)
                            case (_, .none):
                                return (original.isCompleted(on: Date()), nil)
                            case (.none, .daily), (.none, .weekly):
                                return (false, nil)
                            default:
                                return (false, original.completedForDayStart)
                            }
                        }()
                        onSave(
                            Goal(
                                id: original.id,
                                text: trimmed,
                                repeatFrequency: repeatFrequency,
                                isTimed: isTimed,
                                targetTime: isTimed ? targetTime : nil,
                                weeklyAnchorWeekday: resolvedWeeklyAnchorWeekday(original: original),
                                nonRepeatingDayStart: repeatFrequency == .none ? original.nonRepeatingDayStart : nil,
                                isCompleted: savedIsCompleted,
                                completedForDayStart: savedCompletedDay
                            )
                        )
                    }
                } label: {
                    Text(primaryButtonTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)

                Button {
                    onCancel()
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle(navigationTitle)
        .onAppear {
            if case .edit(let goal) = mode {
                goalName = goal.text
                repeatFrequency = goal.repeatFrequency
                weeklyRepeatWeekday = goal.weeklyAnchorWeekday ?? Calendar.current.component(.weekday, from: Date())
                isTimed = goal.isTimed
                targetTime = goal.targetTime ?? Date()
            }
        }
    }
}

#Preview {
    ContentView()
}
