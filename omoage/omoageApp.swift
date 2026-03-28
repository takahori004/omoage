//
//  omoageApp.swift
//  omoage
//
//  Created by takashi on 2026/03/11.
//

import SwiftUI
import UserNotifications

@main
struct omoageApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("通知権限エラー: \(error.localizedDescription)")
            }
            if !granted {
                print("通知が拒否されています。設定アプリから許可してください。")
            }
        }
        return true
    }

    // フォアグラウンド時も通知バナーと音を表示する
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
