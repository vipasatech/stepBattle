# StepBattle — iOS Handoff README

Everything under this `ios/` folder is scoped to iOS. The Android build never
compiles a single byte of Swift, plist, or entitlements — full isolation.

This document is the **step-by-step handoff** for whoever is on the Mac
first-building the iOS app. Follow it top-to-bottom.

For the broader Mac-machine setup (Tailscale, SSH, Homebrew, Xcode, etc.),
see [`../MACBOOK_SETUP.md`](../MACBOOK_SETUP.md).

---

## 📁 What's already in this folder (Phase 1 — pre-built from Windows)

| File | What it does |
|---|---|
| `Runner/Info.plist` | Bundle info + all permission usage strings + URL schemes for Google Sign-In / Stripe / Supabase Auth + background modes |
| `Runner/AppDelegate.swift` | Firebase init, push notification registration, APNs → FCM token bridge, URL-scheme deep-link routing |
| `Runner/Runner.entitlements` | RELEASE-build entitlements: HealthKit, APNs `production`, Sign in with Apple, keychain access |
| `Runner/RunnerDebug.entitlements` | DEBUG-build entitlements: same as above but APNs `development` (sandbox) |
| `Runner/Runner-Bridging-Header.h` | Swift ↔ ObjC bridging (minimal — only bridges Flutter's plugin registrar) |
| `Podfile` | CocoaPods dependencies + iOS 14 minimum + post-install fixes for Firebase / permission_handler |

---

## 🚨 What's missing (must add on Mac before first build)

### 1. `GoogleService-Info.plist` from Firebase console

1. Firebase Console → StepBattle project → gear icon → **Project Settings**
2. Scroll to "Your apps" → **Add app** → **iOS icon**
3. iOS bundle ID: **`com.vipasa.stepbattle`** (must match Xcode)
4. App nickname: `StepBattle iOS`
5. App Store ID: leave blank for now
6. **Register** → download `GoogleService-Info.plist`
7. Place it at: `ios/Runner/GoogleService-Info.plist`
8. In Xcode (open `Runner.xcworkspace`) → right-click the `Runner` folder in
   the left sidebar → **Add Files to Runner** → select the plist →
   ✅ Copy items if needed → ✅ Add to targets: **Runner**

### 2. Replace the Google Sign-In URL scheme placeholder in `Info.plist`

Open `Info.plist`. Find this block near the top of `CFBundleURLTypes`:
```xml
<string>com.googleusercontent.apps.PLACEHOLDER_REVERSED_CLIENT_ID</string>
```

Open the newly-added `GoogleService-Info.plist`, find `REVERSED_CLIENT_ID`
(a value like `com.googleusercontent.apps.123456789-abcdef...`), and replace
the placeholder.

### 3. Assign Team + Bundle ID in Xcode

Xcode → select **Runner** project → **Runner** target → **Signing & Capabilities** tab:
- ✅ Automatically manage signing
- **Team**: pick your Apple Developer team (visible after Apple Developer
  enrollment approval — see MACBOOK_SETUP.md → B1)
- **Bundle Identifier**: `com.vipasa.stepbattle` (must match what you
  reserved in App Store Connect)

### 4. Point Debug vs Release entitlements at the right files

Xcode → Runner target → **Build Settings** → search for
"Code Signing Entitlements":
- **Debug** → `Runner/RunnerDebug.entitlements`
- **Release** → `Runner/Runner.entitlements`
- **Profile** → `Runner/Runner.entitlements`

### 5. Enable capabilities that map to the entitlements

Runner target → **Signing & Capabilities** → **+ Capability**:
- ✅ Push Notifications (matches `aps-environment`)
- ✅ HealthKit (matches `com.apple.developer.healthkit`)
- ✅ Sign in with Apple (matches `com.apple.developer.applesignin`)
- ✅ Background Modes → check: Background fetch, Remote notifications, Background processing

If any of these show ⚠️ warnings, the App ID at
https://developer.apple.com/account/resources/identifiers may need those
capabilities enabled there too.

### 6. APNs `.p8` key uploaded to Firebase

1. https://developer.apple.com/account/resources/authkeys/list → **+**
2. Name: `StepBattle APNs` → enable Apple Push Notifications service → Register
3. Download `.p8` file (**you can only download ONCE — save to password manager**)
4. Note the Key ID + your Team ID (from Membership tab)
5. Firebase Console → Project Settings → **Cloud Messaging** tab → under Apple
   app config → upload the `.p8` with Key ID + Team ID

### 7. Razorpay iOS registration

Razorpay Dashboard → **Account & Settings → Website & App Settings → Apps**
→ Add App → Type: iOS → Bundle ID: `com.vipasa.stepbattle` → Save.

Razorpay whitelists this bundle for payment processing.

### 8. Supabase Auth iOS redirect URIs

Supabase Dashboard → **Authentication → URL Configuration** → Redirect URLs
→ Add:
```
io.supabase.stepbattle://login-callback
com.vipasa.stepbattle.stripe://return
```

---

## 🏗 First iOS build

Once steps 1-8 above are done:

```bash
cd ~/dev/stepBattle
flutter pub get
cd ios
pod install    # first run takes 5-10 minutes
cd ..
flutter build ios --release --no-codesign  # smoke test — verifies pods link
```

If that succeeds, real signed build:
```bash
flutter build ipa --release
# IPA lands at: build/ios/ipa/*.ipa
```

Upload via Xcode: **Product → Archive → Distribute App → App Store Connect →
Upload**. Or via `fastlane deliver` once fastlane is set up.

---

## ⚠️ Known iOS gotchas for StepBattle-specific packages

### `flutter_foreground_task` — iOS behavior is completely different from Android

Android uses this for the always-on step-sync FGS. **iOS has no
foreground services.** The Dart code that calls this package will need
`Platform.isAndroid` guards, OR we accept a degraded iOS experience:
- Step sync happens only when app is in foreground OR via APNs silent pushes
  from the server
- HealthKit background delivery (an iOS-only mechanism) pushes step updates
  to the app in background — but only ~4-6 times per day

**Do NOT add Platform.isAndroid guards until first iOS build reveals what
actually happens.** Test on real device, then decide.

### `home_widget` — iOS WidgetKit is a separate Xcode extension target

Android's app widget is trivial to define; iOS WidgetKit widgets require a
separate target with its own bundle ID. **Skip for iOS MVP.** Users don't get
a home-screen widget on iOS in the first version — add later.

### `flutter_3d_controller_fork` — vendored, iOS untested

You have a vendored fork at `packages/flutter_3d_controller_fork/`. It uses
`flutter_inappwebview` under the hood (which supports iOS), but the fork's
iOS behavior has never been tested. **Test the Arena scene ASAP after first
successful build.** If 3D character rendering breaks on iOS, may need
upstream patches or a per-platform code branch.

### `razorpay_flutter` — iOS backgrounding rules are stricter

Razorpay Checkout requires the app to stay foreground during payment. iOS
background suspension is more aggressive than Android. Test the full
payment flow (open Buy XP → complete UPI → return to app → verify credit)
end-to-end after first build.

### `pedometer` — iOS uses CMPedometer

Different lifecycle than Android's TYPE_STEP_COUNTER. iOS CMPedometer
requires user motion permission (Info.plist `NSMotionUsageDescription` —
already present). Some devices need the app to be foregrounded to fetch
step counts on first request.

### Notification icons / sounds

Android channel-specific settings don't carry over. iOS uses standard
notification categories. Default sound + badge behavior should work but
custom notification sounds require the sound file bundled in the app.

---

## 🚫 What was NOT modified during Phase 1 (all safe on Android)

Zero changes to:
- Any file under `lib/` (Dart code)
- `pubspec.yaml` (no version bumps)
- `android/` folder (untouched)
- `assets/` folder (untouched)

**Android +33/+35 builds are 100% unaffected by this iOS Phase 1 work.**

---

## 🔄 Ongoing dev loop (Windows → Mac)

1. Edit Dart code on Windows
2. `git commit && git push origin main` from Windows
3. On Mac (via SSH from Windows): `cd ~/dev/stepBattle && git pull`
4. `flutter build ipa --release` on Mac
5. Upload via `fastlane` or Xcode → TestFlight
6. Install on physical iPhone via TestFlight → test

For rapid iteration: `flutter run -d "iPhone 15 Pro"` (simulator) on Mac
with VNC/Screen Sharing lets you see the app run live.

---

## 📅 What to expect from first iOS TestFlight submission

- Build upload → App Store Connect processes for ~10-30 min
- Once processed, appears in **TestFlight** tab
- First-time Beta App Review by Apple: usually 24-48 hours for a fresh app
- Common first-submission rejections:
  - Missing privacy manifest (`ios/Runner/PrivacyInfo.xcprivacy`) — new
    Apple requirement, some packages ship them but not all
  - Missing Sign in with Apple (we added the entitlement above — will
    still fail if the Dart button isn't there)
  - Undocumented permission use (fix by tightening Info.plist strings)
- Budget **2-3 review cycles** before first approval

After approval, TestFlight builds go live to testers within minutes.

---

## 🆘 If something breaks

1. **Read the specific error verbatim** — iOS errors are usually specific
2. Check the "Known gotchas" section above
3. Check `../MACBOOK_SETUP.md` → Troubleshooting quick reference
4. Ask Claude in a new session with the error message + the last-attempted
   step number from this README
