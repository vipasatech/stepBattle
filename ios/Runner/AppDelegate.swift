// =============================================================================
// StepBattle iOS AppDelegate
// =============================================================================
//
// What this does (parity with Android's MainActivity + Application setup):
//   1. Configure Firebase at process start (so FCM push, Analytics, etc. work
//      before any Dart code runs).
//   2. Register for remote notifications via UNUserNotificationCenter (asks
//      the user for permission the FIRST time; subsequent launches just get
//      the token silently).
//   3. Forward the APNs device token to Firebase Messaging so FCM can address
//      pushes at this specific device.
//   4. Handle deep-link callbacks from Google Sign-In, Stripe 3DS, and
//      Supabase Auth via `application(_:open:url:options:)`.
//   5. Register all Flutter plugins via GeneratedPluginRegistrant (this
//      MUST fire before super.application... returns; Flutter's engine
//      depends on it).
//
// What this does NOT do:
//   • Business logic — that all lives in Dart. AppDelegate is the thinnest
//     possible boot-time shim.
//   • Foreground service equivalent — iOS has no FGS. Background step sync
//     uses HealthKit background delivery + BGTaskScheduler, both configured
//     from Dart via the `health`, `workmanager`, and `flutter_foreground_task`
//     packages (with `Platform.isAndroid` guards where FGS-specific).
//
// Related iOS files:
//   • Info.plist — permission strings, URL schemes, background modes
//   • Runner.entitlements — HealthKit + Push capabilities
//   • Podfile — CocoaPods setup + post-install fixes
//   • GoogleService-Info.plist — Firebase iOS config (DOWNLOAD after
//     registering iOS app in Firebase console; place at ios/Runner/)
// =============================================================================

import Flutter
import UIKit
import Firebase
import FirebaseMessaging
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {

    // -------------------------------------------------------------------------
    // 1. Firebase init — MUST happen before any Firebase-dependent Dart code
    // runs (which happens the moment Flutter engine spins up below).
    // -------------------------------------------------------------------------
    FirebaseApp.configure()

    // -------------------------------------------------------------------------
    // 2. Push notification setup — request permission, register with APNs,
    // wire the delegates so tokens flow through to FCM.
    //
    // On first launch, the user sees the iOS permission dialog (denied by
    // default). If they allow, `didRegisterForRemoteNotificationsWithDeviceToken`
    // fires with the APNs device token; we hand that to Firebase Messaging
    // which stores it and lets FCM push through APNs.
    // -------------------------------------------------------------------------
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
      let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
      UNUserNotificationCenter.current().requestAuthorization(
        options: authOptions,
        completionHandler: { granted, error in
          if let error = error {
            NSLog("StepBattle: push permission request error: \(error.localizedDescription)")
          }
          NSLog("StepBattle: push permission granted = \(granted)")
        }
      )
    }
    application.registerForRemoteNotifications()

    // Make FirebaseMessaging the delegate so FCM token refreshes are handled
    // and the Dart-side firebase_messaging plugin can observe them.
    Messaging.messaging().delegate = self

    // -------------------------------------------------------------------------
    // 3. Flutter plugin registration — MUST call this before returning.
    // -------------------------------------------------------------------------
    GeneratedPluginRegistrant.register(with: self)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // -------------------------------------------------------------------------
  // APNs token bridge — iOS gives us a raw APNs device token. Handing it to
  // Firebase Messaging is what lets FCM address this device (FCM uses APNs
  // as the actual delivery transport on iOS).
  // -------------------------------------------------------------------------
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("StepBattle: APNs registration failed: \(error.localizedDescription)")
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  // -------------------------------------------------------------------------
  // Deep-link callback handler — iOS delivers URL-scheme opens here. Current
  // callers:
  //   • Google Sign-In: after OAuth, Google redirects to
  //     `com.googleusercontent.apps.<REVERSED_CLIENT_ID>://oauth`
  //   • Supabase magic-link auth: `io.supabase.stepbattle://...`
  //
  // Stripe 3DS callbacks are NOT wired here yet — Stripe is dormant while
  // Razorpay is the sole live provider (see MEMORY.md → project_razorpay_live).
  // When Stripe activates, add the URL scheme in Info.plist; this super()
  // routing already handles any registered scheme without code changes.
  //
  // FlutterAppDelegate's super implementation routes the URL through the
  // plugin registrar chain — each plugin decides if the URL is for it. We
  // don't need to switch on scheme manually; plugins self-identify.
  // -------------------------------------------------------------------------
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options)
  }
}

// =============================================================================
// MessagingDelegate — receives fresh FCM tokens (initial + rotations).
// The Dart-side firebase_messaging plugin observes the same event via its
// own hook, so we don't need to store the token here — just log for debug.
// =============================================================================
extension AppDelegate: MessagingDelegate {
  func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    NSLog("StepBattle: FCM token = \(fcmToken ?? "nil")")
    // Dart's FirebaseMessaging.instance.onTokenRefresh stream picks this up
    // automatically. No manual forwarding needed.
  }
}
