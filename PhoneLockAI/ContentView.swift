//
//  ContentView.swift
//  PhoneLockAI
//
//  Created by Kedaar Chakankar on 3/19/26.
//

import SwiftUI
import Foundation
import UserNotifications

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
    var isCompleted: Bool

    init(
        id: UUID = UUID(),
        text: String,
        repeatFrequency: GoalRepeatFrequency = .none,
        isTimed: Bool = false,
        targetTime: Date? = nil,
        weeklyAnchorWeekday: Int? = nil,
        nonRepeatingDayStart: Date? = nil,
        isCompleted: Bool = false
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
        self.isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        if self.repeatFrequency != .none {
            self.nonRepeatingDayStart = nil
        } else if let d = self.nonRepeatingDayStart {
            self.nonRepeatingDayStart = Calendar.current.startOfDay(for: d)
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

        updateStreakIfNeeded()
        pruneExpiredNoneRepeatGoalsIfNeeded()
        Task {
            await GoalReminderScheduler.shared.syncReminders(for: goals)
        }
    }

    var dailyLimitSeconds: Int {
        max(0, dailyLimitHours * 3600 + dailyLimitMinutes * 60)
    }

    var activeSessionElapsedSeconds: TimeInterval {
        guard let start = activeSessionStartDate else { return 0 }
        return Date().timeIntervalSince(start)
    }

    var isUnlockActive: Bool { activeSessionStartDate != nil }

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

    func startUnlock(durationMinutes: Int, isEmergency: Bool) {
        guard activeSessionStartDate == nil else { return }
        activeSessionIsEmergency = isEmergency
        activeSessionDurationSeconds = TimeInterval(max(1, durationMinutes) * 60)
        activeSessionStartDate = Date()
    }

    func endActiveUnlock() {
        guard let start = activeSessionStartDate else { return }
        let end = Date()

        let record = UnlockSessionRecord(
            startDate: start,
            endDate: end,
            isEmergency: activeSessionIsEmergency
        )
        sessionRecords.append(record)
        lastUnlockedSessionID = record.id

        activeSessionStartDate = nil
        activeSessionIsEmergency = false
        activeSessionDurationSeconds = 5 * 60
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
            let overlapStart = max(start, dayStart)
            let overlapEnd = min(now, dayEnd)
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

    var primaryGoalText: String {
        goals.first?.text ?? "Your goal"
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
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
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
                            onEditGoal: { goal in navPath.append(.editGoal(goal)) }
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
                                onEmergencyUnlock: {
                                    store.startUnlock(durationMinutes: 5, isEmergency: true)
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
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            store.pruneExpiredNoneRepeatGoalsIfNeeded()
            store.updateStreakIfNeeded()
        }
    }
}

// MARK: - Screen 1) Onboarding

struct OnboardingView: View {
    @ObservedObject var store: PhoneLockStore
    var onDone: () -> Void

    @State private var newGoalText: String = ""

    var canContinue: Bool {
        store.dailyLimitSeconds > 0 && !store.goals.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PhoneLockAI")
                            .font(.title.bold())
                        Text("Set your daily limit and goals. When you unlock distractions, you'll reflect first.")
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

                    GroupBox(label: Text("Goals").font(.subheadline).foregroundStyle(.secondary)) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                TextField("Add a goal (e.g., 'Finish my study plan')", text: $newGoalText)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    let trimmed = newGoalText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmed.isEmpty else { return }
                                    store.goals.append(Goal(text: trimmed))
                                    newGoalText = ""
                                } label: {
                                    Text("Add")
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            if store.goals.isEmpty {
                                Text("Add at least one goal to continue.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(store.goals) { goal in
                                    HStack {
                                        Text(goal.text)
                                            .lineLimit(1)
                                        Spacer()
                                        Button(role: .destructive) {
                                            store.goals.removeAll { $0.id == goal.id }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    Button {
                        onDone()
                    } label: {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("Onboarding")
        }
    }
}

// MARK: - Screen 2) Home Dashboard

struct HomeDashboardView: View {
    @ObservedObject var store: PhoneLockStore
    var onStartChat: () -> Void
    var onOpenSettings: () -> Void
    var onAddGoal: () -> Void
    var onEditGoal: (Goal) -> Void
    // For the mock: keep Home's ring updated on state changes.
    // (The sticky countdown during an active unlock session provides the real-time UX.)
    @State private var now: Date = Date()

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

                    HomeStatusView(store: store, now: now)
                        .padding(.top, 100)
                    GoalsListView(store: store, onAddGoal: onAddGoal, onEditGoal: onEditGoal)
                    HomeActionsView(store: store, onStartChat: onStartChat)
                }
                .padding()
            }
            .onAppear { now = Date() }
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
    let onAddGoal: () -> Void
    let onEditGoal: (Goal) -> Void
    @State private var selectedGoalID: UUID?
    @State private var showGoalActions = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Goals")
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
            
            VStack(spacing: 10) {
                ForEach(store.goals) { goal in
                    Button {
                        selectedGoalID = goal.id
                        showGoalActions = true
                    } label: {
                        GoalRowView(text: goal.text, isCompleted: goal.isCompleted)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .confirmationDialog(
            "Goal Options",
            isPresented: $showGoalActions,
            titleVisibility: .visible
        ) {
            if let index = selectedGoalIndex {
                Button("Edit Goal") {
                    onEditGoal(store.goals[index])
                    selectedGoalID = nil
                }
                Button(store.goals[index].isCompleted ? "Mark as Incomplete" : "Mark as Complete") {
                    store.goals[index].isCompleted.toggle()
                }
                Button("Delete Goal", role: .destructive) {
                    let id = store.goals[index].id
                    store.goals.removeAll { $0.id == id }
                    selectedGoalID = nil
                }
            }
            Button("Cancel", role: .cancel) {
                selectedGoalID = nil
            }
        }
    }

    private var selectedGoalIndex: Int? {
        guard let selectedGoalID else { return nil }
        return store.goals.firstIndex(where: { $0.id == selectedGoalID })
    }
}

struct GoalRowView: View {
    let text: String
    let isCompleted: Bool

    var body: some View {
        HStack {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .lineLimit(1)
            Spacer()
            if isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    var errorDescription: String? {
        switch self {
        case .missingBackendURL:
            return "Missing backend URL. Set BACKEND_CHAT_URL in Info.plist."
        case .badResponse:
            return "Backend request failed."
        case .emptyResponse:
            return "Backend returned an empty response."
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

    private let openAI = OpenAIService()

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
                Button {
                    onUnlock(minutes)
                } label: {
                    Text("Unlock for \(minutes) minutes")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
        inputText = ""
        messages.append(ChatMessage(role: .user, content: trimmed))
        isLoading = true
        defer { isLoading = false }

        do {
            let assistantText = try await openAI.send(
                conversation: messages,
                goals: store.goals.map(\.text)
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
            errorText = error.localizedDescription
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
    var onEmergencyUnlock: () -> Void

    var body: some View {
        List {
            NavigationLink("My Account") {
                MyAccountView()
            }
            NavigationLink("Edit Daily Limit") {
                EditDailyLimitView(store: store)
            }
            NavigationLink("Edit Blocked Apps") {
                EditBlockedAppsView()
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
        }
        .navigationTitle("Settings")
    }
}

struct EditDailyLimitView: View {
    @ObservedObject var store: PhoneLockStore
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
    var onEmergencyUnlock: () -> Void

    var body: some View {
        Form {
            Section {
                Text("Emergency unlock starts a 5 minute unlock session and counts toward your limit.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable Emergency Unlock", isOn: $store.emergencyUnlockEnabled)
                Button {
                    onEmergencyUnlock()
                } label: {
                    Text("Emergency Unlock (5 minutes)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.emergencyUnlockEnabled || store.isUnlockActive || store.dailyLimitSeconds <= 0)
            }
        }
        .navigationTitle("Emergency Unlock")
    }
}

struct EditBlockedAppsView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Edit Blocked Apps")
                .font(.headline)
            Text("Coming soon")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .navigationTitle("Edit Blocked Apps")
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

    /// Weekday (1…7) for weekly timed reminders; fixed after first save, preserved on edit unless repeat mode changes.
    private func resolvedWeeklyAnchorWeekday(original: Goal?) -> Int? {
        guard repeatFrequency == .weekly && isTimed else { return nil }
        if let original, original.repeatFrequency == .weekly, original.isTimed, let existing = original.weeklyAnchorWeekday {
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
                        onSave(
                            Goal(
                                id: original.id,
                                text: trimmed,
                                repeatFrequency: repeatFrequency,
                                isTimed: isTimed,
                                targetTime: isTimed ? targetTime : nil,
                                weeklyAnchorWeekday: resolvedWeeklyAnchorWeekday(original: original),
                                nonRepeatingDayStart: repeatFrequency == .none ? original.nonRepeatingDayStart : nil,
                                isCompleted: original.isCompleted
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
                isTimed = goal.isTimed
                targetTime = goal.targetTime ?? Date()
            }
        }
    }
}

#Preview {
    ContentView()
}
