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
    private enum ScreenTimeConfig {
        static let unlockActivityName = DeviceActivityName("com.phonelockai.unlock.session")
        static let activeShieldStoreName = ManagedSettingsStore.Name("com.phonelockai.shield.active")
        static let sharedDefaultsSuite = "group.com.phonelockai.shared"
        static let blockedAppsSelectionKey = "pol_blocked_apps_selection"
        static let unlockEndedAtKey = "pol_unlock_ended_at"
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        applyLockIfNeeded(for: activity)
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
        applyLockIfNeeded(for: activity)
    }

    private func applyLockIfNeeded(for activity: DeviceActivityName) {
        guard activity == ScreenTimeConfig.unlockActivityName else { return }

        guard let sharedDefaults = UserDefaults(suiteName: ScreenTimeConfig.sharedDefaultsSuite) else { return }

        let activeStore = ManagedSettingsStore(named: ScreenTimeConfig.activeShieldStoreName)
        guard let data = sharedDefaults.data(forKey: ScreenTimeConfig.blockedAppsSelectionKey),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return
        }
        let tokens = selection.applicationTokens
        activeStore.shield.applications = tokens.isEmpty ? nil : tokens
        sharedDefaults.set(Date().timeIntervalSince1970, forKey: ScreenTimeConfig.unlockEndedAtKey)
    }
}
