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
import HealthKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {

  // ---------------------------------------------------------------------------
  // Explicit Flutter engine, created and run here rather than implicitly by a
  // FlutterViewController loaded from Main.storyboard.
  //
  // Why: adopting the UIScene lifecycle (below) moves window creation out of
  // UIApplicationMain and into `SceneDelegate.scene(_:willConnectTo:)`, which
  // runs AFTER didFinishLaunching. Plugin registration happens in
  // didFinishLaunching, so if we left the engine implicit there would be no
  // engine to register against at that moment. Owning the engine makes the
  // ordering explicit: create it, run it, register plugins, and hand the same
  // instance to the view controller when the scene connects.
  // ---------------------------------------------------------------------------
  let flutterEngine = FlutterEngine(name: "stepbattle_main")

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
    // 3. Flutter engine + plugin registration — MUST call this before
    // returning. Registering against `flutterEngine` rather than `self` is
    // what the UIScene migration requires; see the property's header.
    // -------------------------------------------------------------------------
    flutterEngine.run()
    GeneratedPluginRegistrant.register(with: flutterEngine)

    // -------------------------------------------------------------------------
    // 4. HealthKit background delivery — the iOS answer to Android's
    // WorkManager + foreground service, neither of which exists here.
    //
    // Started AFTER plugin registration so the Dart side has a running
    // engine to receive the channel call on, and unconditionally on every
    // launch because iOS re-launches the app in the background purely to
    // deliver these updates — the observer must be re-registered each time
    // or that launch does nothing.
    // -------------------------------------------------------------------------
    HealthKitBackgroundDelivery.shared.start(
      binaryMessenger: flutterEngine.binaryMessenger
    )

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
// UIScene lifecycle
// =============================================================================
//
// Required as of the iOS 26 SDK. An app built against that SDK (or newer) which
// does NOT adopt UIScene is killed by UIKit at launch — the crash surfaces as
// EXC_BREAKPOINT inside
// `___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption_block_invoke`,
// roughly 150ms in, with no Dart ever executing. Note the trigger is the SDK
// the binary was BUILT with, not the iOS version it runs on: the same source
// built with Xcode 26 launches fine on iOS 27. This Mac updated to Xcode 27.2,
// which is what surfaced it (2026-11-19).
//
// Flutter ships a `FlutterSceneDelegate` in later releases; 3.27.1 predates it,
// so the adoption below is hand-rolled. Three pieces are required and Apple
// checks for all of them: the `UIApplicationSceneManifest` key in Info.plist,
// at least one scene configuration in it, and the
// `configurationForConnecting` method here.
// =============================================================================
extension AppDelegate {
  override func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    // Name must match UISceneConfigurationName in Info.plist exactly.
    return UISceneConfiguration(
      name: "Default Configuration",
      sessionRole: connectingSceneSession.role
    )
  }
}

/// Owns the single window. Declared in this file rather than its own so the
/// Xcode project's Sources build phase needs no edit — `project.pbxproj`
/// surgery is a poor trade for one class.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
          let appDelegate = UIApplication.shared.delegate as? AppDelegate
    else { return }

    // Build the window around the engine AppDelegate already started, rather
    // than instantiating Main.storyboard. The storyboard's FlutterViewController
    // would spin up a SECOND, pluginless engine.
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = FlutterViewController(
      engine: appDelegate.flutterEngine,
      nibName: nil,
      bundle: nil
    )
    self.window = window
    window.makeKeyAndVisible()

    // Compatibility shim. Plenty of plugins still reach for
    // `UIApplication.shared.delegate.window` to present view controllers from
    // — image pickers, OAuth sheets, payment flows. Under the scene lifecycle
    // that property is nil unless we set it, and the failure mode is a plugin
    // silently doing nothing rather than throwing.
    appDelegate.window = window

    // A URL that launched the app cold arrives here, not via
    // scene(_:openURLContexts:).
    if let url = connectionOptions.urlContexts.first?.url {
      forward(url)
    }
  }

  // Under the scene lifecycle UIKit stops calling
  // `application(_:open:options:)` on the app delegate and calls this instead.
  // Google Sign-In and Supabase auth both come back through a URL scheme, so
  // without this forward the user completes sign-in in Safari and returns to
  // an app that never hears about it.
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else { return }
    forward(url)
  }

  private func forward(_ url: URL) {
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
    _ = appDelegate.application(UIApplication.shared, open: url, options: [:])
  }
}

// =============================================================================
// HealthKit background delivery
// =============================================================================
//
// Keeps a user's step count moving while StepBattle is closed.
//
// Why this is necessary: `BackgroundSync` on the Dart side is
// Android-only. Battle scoring is
// `total_steps_all_time - start_steps_baseline`, and that counter only
// advances when the app syncs — so on iPhone a user who walked with the
// app shut scored almost nothing, and `end_steps_baseline` froze the
// result permanently when the battle closed. One observed battle
// recorded 318 steps against 2,529 sitting in HealthKit.
//
// `HKObserverQuery` combined with `enableBackgroundDelivery` is the only
// mechanism iOS offers that survives app termination: the system wakes
// the app when new samples are written. It is also strictly better than
// polling, since it fires on real data rather than on a timer.
//
// Lives in this file rather than its own because only AppDelegate.swift
// is listed in the Xcode target's Sources build phase — a new .swift
// file would sit there looking correct and never be compiled.
//
// REQUIRES the `com.apple.developer.healthkit.background-delivery`
// entitlement (see Runner.entitlements). Without it the
// enableBackgroundDelivery call fails at runtime with a "missing
// entitlement" error and the observer simply never fires in the
// background.
// =============================================================================
final class HealthKitBackgroundDelivery {
  static let shared = HealthKitBackgroundDelivery()
  private init() {}

  /// Must match `_healthBgChannel` in lib/services/background_sync.dart.
  private static let channelName = "com.vipasa.stepbattle/health_background"

  /// How long to wait for Dart before releasing HealthKit's completion
  /// handler anyway.
  ///
  /// iOS gives a background wake only a few seconds of runtime and
  /// penalises apps that do not call the handler promptly. Dart may also
  /// never answer at all — the engine is still booting on a cold
  /// background launch, and the handler is not registered until `main()`
  /// reaches `initIosHealthBackgroundSync()`. Either way we must settle.
  private static let dartTimeout: TimeInterval = 20

  private let store = HKHealthStore()
  private var channel: FlutterMethodChannel?
  private var observerQuery: HKObserverQuery?

  func start(binaryMessenger: FlutterBinaryMessenger) {
    guard HKHealthStore.isHealthDataAvailable() else {
      NSLog("StepBattle: HealthKit unavailable on this device")
      return
    }
    guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount)
    else { return }

    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: binaryMessenger
    )

    // Registering an observer does NOT require authorisation to have been
    // granted yet — if the user has not allowed step reads the query
    // simply never fires, and starts working the moment they do without
    // needing another launch.
    let query = HKObserverQuery(
      sampleType: stepType,
      predicate: nil
    ) { [weak self] _, completionHandler, error in
      if let error = error {
        NSLog("StepBattle: HK observer error: \(error.localizedDescription)")
        completionHandler()
        return
      }
      guard let self = self else {
        completionHandler()
        return
      }
      self.requestDartSync(completionHandler)
    }
    store.execute(query)
    observerQuery = query

    // `.hourly` is the floor HealthKit allows for step count; asking for
    // anything more frequent is silently clamped.
    store.enableBackgroundDelivery(for: stepType, frequency: .hourly) {
      success, error in
      if let error = error {
        NSLog(
          "StepBattle: HK background delivery failed: \(error.localizedDescription)"
        )
      } else {
        NSLog("StepBattle: HK background delivery enabled = \(success)")
      }
    }
  }

  /// Ask Dart to run a sync, then release HealthKit exactly once.
  ///
  /// Calling `completionHandler` more than once, or not at all, both
  /// misbehave: the first is an API violation, the second makes iOS back
  /// off and eventually stop delivering. The `settled` flag guarantees
  /// exactly one call whichever of the two paths — Dart replying or the
  /// watchdog firing — gets there first.
  private func requestDartSync(
    _ completionHandler: @escaping HKObserverQueryCompletionHandler
  ) {
    // Flutter channels are main-thread only; the observer callback is not.
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let channel = self.channel else {
        completionHandler()
        return
      }
      var settled = false
      let settle = {
        guard !settled else { return }
        settled = true
        completionHandler()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.dartTimeout) {
        settle()
      }
      channel.invokeMethod("syncSteps", arguments: nil) { result in
        NSLog("StepBattle: HK sync returned \(String(describing: result))")
        settle()
      }
    }
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
