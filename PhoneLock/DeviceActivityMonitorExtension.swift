//
//  DeviceActivityMonitorExtension.swift
//  PhoneLock
//
//  Created by Kedaar Chakankar on 3/26/26.
//

import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    private struct ActiveUnlockState: Codable {
        let sessionID: String
        let startDate: Date
        let durationSeconds: TimeInterval
        let isEmergency: Bool
    }

    private enum ScreenTimeConfig {
        static let unlockPrimaryActivityPrefix = "com.phonelockai.unlock.primary."
        static let unlockFallbackActivityPrefix = "com.phonelockai.unlock.fallback."
        /// Legacy schedules from builds that used UUID-suffixed names.
        static let legacyPrimaryPrefix = "com.phonelockai.unlock.session."
        static let legacyFallbackPrefix = "com.phonelockai.unlock.session.fallback."
        static let activeShieldStoreName = ManagedSettingsStore.Name("com.phonelockai.shield.active")
        static let sharedDefaultsSuite = "group.com.phonelockai.shared"
        static let blockedAppsSelectionKey = "pol_blocked_apps_selection"
        static let unlockEndedAtKey = "pol_unlock_ended_at"
        static let activeUnlockStateKey = "pol_active_unlock_state"
        static let daMonitorPrimaryKey = "pol_da_unlock_primary"
        static let daMonitorFallbackKey = "pol_da_unlock_fallback"
        static let blockedSelectionFilename = "blocked_apps_selection.json"
        static let extLastEventKey = "pol_ext_last_event"
        static let extLastEventTimeKey = "pol_ext_last_event_ts"
        static let extLastActivityKey = "pol_ext_last_activity"
    }

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard isOurUnlockActivity(activity) else { return }
        guard let sharedDefaults = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) else { return }
        recordExtensionDiag(defaults: sharedDefaults, event: "intervalDidStart", activity: activity)
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
        applyLockIfNeeded(for: activity, trigger: "intervalWillEndWarning")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        applyLockIfNeeded(for: activity, trigger: "intervalDidEnd")
    }

    private func isOurUnlockActivity(_ activity: DeviceActivityName) -> Bool {
        let raw = activity.rawValue
        return raw.hasPrefix(ScreenTimeConfig.unlockPrimaryActivityPrefix)
            || raw.hasPrefix(ScreenTimeConfig.unlockFallbackActivityPrefix)
            || raw.hasPrefix(ScreenTimeConfig.legacyPrimaryPrefix)
            || raw.hasPrefix(ScreenTimeConfig.legacyFallbackPrefix)
    }

    private func extractSessionID(from activity: DeviceActivityName) -> String? {
        let raw = activity.rawValue
        if raw.hasPrefix(ScreenTimeConfig.unlockPrimaryActivityPrefix) {
            return String(raw.dropFirst(ScreenTimeConfig.unlockPrimaryActivityPrefix.count))
        }
        if raw.hasPrefix(ScreenTimeConfig.unlockFallbackActivityPrefix) {
            return String(raw.dropFirst(ScreenTimeConfig.unlockFallbackActivityPrefix.count))
        }
        if raw.hasPrefix(ScreenTimeConfig.legacyPrimaryPrefix) {
            return String(raw.dropFirst(ScreenTimeConfig.legacyPrimaryPrefix.count))
        }
        if raw.hasPrefix(ScreenTimeConfig.legacyFallbackPrefix) {
            return String(raw.dropFirst(ScreenTimeConfig.legacyFallbackPrefix.count))
        }
        return nil
    }

    private func recordExtensionDiag(defaults: UserDefaults, event: String, activity: DeviceActivityName) {
        defaults.set(event, forKey: ScreenTimeConfig.extLastEventKey)
        defaults.set(Date().timeIntervalSince1970, forKey: ScreenTimeConfig.extLastEventTimeKey)
        defaults.set(activity.rawValue, forKey: ScreenTimeConfig.extLastActivityKey)
        defaults.synchronize()
    }

    private func loadBlockedAppsSelection(sharedDefaults: UserDefaults) -> FamilyActivitySelection? {
        if let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ScreenTimeConfig.sharedDefaultsSuite) {
            let url = base.appendingPathComponent(ScreenTimeConfig.blockedSelectionFilename, isDirectory: false)
            if let data = try? Data(contentsOf: url), !data.isEmpty,
               let sel = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
                return sel
            }
        }
        if let data = sharedDefaults.data(forKey: ScreenTimeConfig.blockedAppsSelectionKey), !data.isEmpty,
           let sel = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) {
            return sel
        }
        return nil
    }

    private func applyLockIfNeeded(for activity: DeviceActivityName, trigger: String) {
        guard isOurUnlockActivity(activity) else { return }

        guard let sharedDefaults = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) else { return }
        recordExtensionDiag(defaults: sharedDefaults, event: trigger, activity: activity)

        // Ignore stale callbacks from prior sessions; only lock for the active unlock session.
        if let data = sharedDefaults.data(forKey: ScreenTimeConfig.activeUnlockStateKey),
           let active = try? JSONDecoder().decode(ActiveUnlockState.self, from: data),
           let callbackSessionID = extractSessionID(from: activity) {
            if callbackSessionID != active.sessionID {
                recordExtensionDiag(defaults: sharedDefaults, event: "ignored_stale_session_callback", activity: activity)
                return
            }
        }

        let activeStore = ManagedSettingsStore(named: ScreenTimeConfig.activeShieldStoreName)
        guard let selection = loadBlockedAppsSelection(sharedDefaults: sharedDefaults) else {
            recordExtensionDiag(defaults: sharedDefaults, event: "decode_fail", activity: activity)
            return
        }

        let appTokens = selection.applicationTokens
        activeStore.shield.applications = appTokens.isEmpty ? nil : appTokens
        if selection.categoryTokens.isEmpty {
            activeStore.shield.applicationCategories = nil
        } else {
            activeStore.shield.applicationCategories = .specific(selection.categoryTokens, except: [])
        }
        sharedDefaults.set(Date().timeIntervalSince1970, forKey: ScreenTimeConfig.unlockEndedAtKey)
        sharedDefaults.removeObject(forKey: ScreenTimeConfig.activeUnlockStateKey)
        recordExtensionDiag(defaults: sharedDefaults, event: "shield_applied", activity: activity)

        let center = DeviceActivityCenter()
        var toStop: [DeviceActivityName] = [activity]
        if let sessionID = extractSessionID(from: activity), !sessionID.isEmpty {
            toStop.append(DeviceActivityName(ScreenTimeConfig.unlockPrimaryActivityPrefix + sessionID))
            toStop.append(DeviceActivityName(ScreenTimeConfig.unlockFallbackActivityPrefix + sessionID))
        }
        center.stopMonitoring(toStop)
        sharedDefaults.removeObject(forKey: ScreenTimeConfig.daMonitorPrimaryKey)
        sharedDefaults.removeObject(forKey: ScreenTimeConfig.daMonitorFallbackKey)
        sharedDefaults.synchronize()
    }
}
