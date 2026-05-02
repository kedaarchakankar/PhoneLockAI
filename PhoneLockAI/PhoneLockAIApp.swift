//
//  PhoneLockAIApp.swift
//  PhoneLockAI
//
//  Created by Kedaar Chakankar on 3/19/26.
//

import SwiftUI

@main
struct PhoneLockAIApp: App {
    @StateObject private var subscriptionManager = SubscriptionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(subscriptionManager)
                .task {
                    await subscriptionManager.updateSubscriptionStatus()
                }
        }
    }
}
