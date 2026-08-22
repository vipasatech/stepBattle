# StepBattle — MacBook Setup for iOS Development

Complete step-by-step guide to prepare the MacBook (M-series / Apple silicon) for
building StepBattle's iOS app. The Mac will physically live in Germany with a
friend, while development continues from a Windows machine in India. Code changes
happen on Windows, sync via git, and iOS builds run remotely on the Mac via SSH.

**Author of these instructions:** Claude (this Claude Code session).
**Last updated:** 2026-08-21.

---

## Already installed (skip these)

- [x] Xcode
- [x] iOS Simulator (bundled with Xcode)
- [x] Flutter SDK
- [x] git
- [x] Homebrew

---

## Setup phases

The steps below are grouped by **when** they must happen. Order matters — some
require physical access to the Mac.

### 🔴 Phase A — BEFORE the Mac leaves for Germany
Everything that needs physical access to the machine or the same local network.

### 🟡 Phase B — Do in parallel, no physical access needed
Kicks off external clocks (Apple approval, etc.).

### 🟢 Phase C — After the Mac is in Germany, do remotely from Windows via SSH
The bulk of iOS-specific project config.

---

# 🔴 PHASE A — Before the Mac leaves

## A1. Install Tailscale (remote access VPN)

**Why:** Once the Mac is on someone else's Wi-Fi in Germany, we can't reach it
through the public internet without port-forwarding (which we don't control).
Tailscale creates a private network across devices via WireGuard — zero-config,
free (up to 100 devices), NAT-friendly.

**On the Mac:**
1. Download from https://tailscale.com/download/mac
2. Install, launch, sign in with your Google account (creates the Tailscale
   account on first sign-in)
3. Note the Mac's Tailscale hostname (e.g. `macbook-neo`) from the menu bar
   Tailscale icon → **Copy address**

**On the Windows machine (used for development):**
1. Download from https://tailscale.com/download/windows
2. Install, launch, sign in with the **same Google account**
3. Both devices should appear together in the Tailscale admin console
4. Verify: `ping <mac-tailscale-name>` from PowerShell should reply

## A2. Enable Remote Login (SSH) on the Mac

1. **System Settings → General → Sharing**
2. Toggle on **Remote Login**
3. Under "Allow access for" → **All users** (or add your specific Mac account)
4. Note the SSH command shown at the bottom: `ssh <username>@<mac-hostname>.local`
5. From Windows PowerShell, try:
   ```powershell
   ssh <username>@<mac-tailscale-name>
   ```
   Should prompt for the Mac password. Enter it and confirm you land in a shell.

## A3. SSH key auth (skip password every time)

On Windows PowerShell:
```powershell
ssh-keygen -t ed25519 -C "windows-dev-machine"
# accept defaults; leave passphrase blank for convenience
```

Copy the public key to the Mac:
```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh <username>@<mac-tailscale-name> "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Verify next SSH doesn't prompt for password:
```powershell
ssh <username>@<mac-tailscale-name> "hostname"
```

## A4. Add an SSH alias for convenience

On Windows, create/edit `%USERPROFILE%\.ssh\config`:
```
Host stepbattle-mac
  HostName <mac-tailscale-name>
  User <mac-username>
  IdentityFile ~/.ssh/id_ed25519
  ServerAliveInterval 60
```

Now you can just: `ssh stepbattle-mac`

## A5. Enable Screen Sharing (backup GUI access)

Some Xcode operations (signing certs, some settings) are GUI-only.

1. **System Settings → General → Sharing**
2. Toggle on **Screen Sharing**
3. From Windows: install **RealVNC Viewer** (free), connect to
   `<mac-tailscale-name>:5900`, log in with the Mac account password

You'll only need this occasionally.

## A6. Prevent the Mac from sleeping

The Mac must stay awake (or at least reachable) 24/7 for remote builds.

1. **System Settings → Lock Screen**
   - "Turn display off when inactive" → **Never** (or long duration like 3 hours)
   - "Require password after screen saver begins" → keep for security
2. **System Settings → Battery → Options**
   - "Prevent automatic sleeping on power adapter when the display is off" → **ON**
   - "Wake for network access" → **ON**
3. **System Settings → Energy** (M-series desktop only, some options move)
   - "Start up automatically after a power failure" → **ON**
4. (Optional but recommended) install **Amphetamine** from the Mac App Store —
   free app with fine-grained wake control (e.g. "keep awake while an SSH session
   is active")

## A7. Test end-to-end BEFORE the Mac leaves

Simulate the "Mac is on a different network" scenario:
1. On Windows, disable Wi-Fi
2. Enable mobile hotspot (from your phone) and connect Windows to it
3. Verify: `ssh stepbattle-mac "flutter doctor -v"`
4. Should still work — Tailscale routes the connection over the internet

**If this test fails, DO NOT let the Mac leave until you've fixed it.** Once it's
in Germany, you can't easily debug remote-access issues without a phone call to
the friend who has physical access.

---

# 🟡 PHASE B — Do NOW in parallel (no physical Mac access needed)

## B1. Enroll in Apple Developer Program

**Why now:** approval takes 2-7 days for individuals, up to 2 weeks for
organizations. Start the clock immediately so it doesn't block later steps.

1. Go to https://developer.apple.com/programs/enroll
2. Sign in with an Apple ID (create one if needed — use a persistent email,
   NOT a Gmail alias)
3. Choose enrollment type:
   - **Individual** ($99/year, ~₹8,300):
     - Fastest, uses your legal name
     - App Store shows "By [Your Name]"
     - Recommended if you don't have a registered business yet
   - **Organization** ($99/year):
     - Requires D-U-N-S number (free to get from Dun & Bradstreet, 2-14 days)
     - App Store shows your business name
     - Recommended if you have a registered business (Razorpay merchant name)
4. Complete identity verification (government ID + credit card)
5. Wait for approval email — track status in Apple Developer dashboard

**Payment:** international credit card is required (Rupay may fail; use a
Visa/Mastercard with international transactions enabled).

## B2. Push latest code to GitHub

On Windows PowerShell:
```powershell
cd C:\Users\admin\Desktop\stepBattle
git status
git add -A
git commit -m "checkpoint before iOS setup"
git push origin main
```

Also verify the GitHub URL of the repo:
```powershell
git remote get-url origin
```
Note this URL — you'll clone from it on the Mac.

---

# 🟢 PHASE C — After Mac is in Germany, do remotely from Windows via SSH

All steps below assume you've SSH'd into the Mac from Windows (`ssh stepbattle-mac`).
Some Xcode GUI steps require Screen Sharing (RealVNC Viewer) — flagged with
**[GUI]** below.

## C1. Install CocoaPods (iOS native dependency manager)

Flutter iOS builds require CocoaPods to resolve native dependencies (Firebase,
Razorpay, Stripe, health, etc.).

Via SSH on Mac:
```bash
brew install cocoapods
pod --version   # verify — should print something like "1.15.2"
```

## C2. Xcode command-line tools + license accept

```bash
sudo xcode-select --install
sudo xcodebuild -license accept
```

The `install` step may pop up a GUI dialog — accept it via Screen Sharing if
needed. If the tools are already installed, `xcode-select` will say so.

## C3. Verify Flutter can see iOS toolchain

```bash
flutter doctor -v
```

Should show all-green for at minimum:
- ✅ Flutter (channel stable, latest version)
- ✅ **Xcode - develop for iOS and macOS**
- ✅ Connected device (iOS Simulator counts)
- ✅ HTTP Host Availability

Fix any RED lines before proceeding. Common fixes:
- Missing Ruby/gems → `brew install ruby` then re-run
- Missing android-sdk (if you also want to build Android on the Mac) → install
  Android Studio, or ignore if you're iOS-only on this machine

## C4. Clone the StepBattle repo

```bash
mkdir -p ~/dev
cd ~/dev
git clone <github-url-from-B2> stepBattle
cd stepBattle
```

Configure git identity on the Mac (so any commits from here are attributed
correctly):
```bash
git config user.name "Your Name"
git config user.email "your-email@example.com"
```

## C5. Add iOS platform to the Flutter project

Check if the `ios/` folder already exists:
```bash
ls -la ios 2>&1
```

**If missing** (likely — the project is Android-only right now):
```bash
flutter create --platforms=ios .
```
This adds only iOS platform files — leaves your existing Android and shared Dart
code untouched.

**If present**, skip.

Commit the new files:
```bash
git add ios/
git commit -m "add iOS platform"
git push origin main
```

## C6. Install Flutter deps + iOS pods

```bash
flutter pub get
cd ios
pod install
cd ..
```

First `pod install` takes 5-10 minutes (downloads all native SDKs including
Firebase, Razorpay, Stripe). Subsequent runs are fast.

If `pod install` fails with signing errors, that's fine for now — we'll fix
signing in the next section.

## C7. **[GUI]** Open project in Xcode, configure bundle ID + signing

Via Screen Sharing (RealVNC Viewer):

1. In Terminal on Mac: `open ~/dev/stepBattle/ios/Runner.xcworkspace`
   (**Runner.xcworkspace**, NOT `Runner.xcodeproj` — always use the workspace)
2. In Xcode's left sidebar, select the **Runner** project (blue icon at top)
3. Select the **Runner** TARGET (under TARGETS, not PROJECTS)
4. **General** tab:
   - **Display Name**: `StepBattle`
   - **Bundle Identifier**: `com.vipasa.stepbattle`
     (must be globally unique across the App Store — reserve this in App Store
     Connect first, or you'll get a conflict later)
   - **Minimum Deployments**: iOS 14.0 or later
5. **Signing & Capabilities** tab:
   - Check **Automatically manage signing**
   - **Team**: select your Apple Developer team (appears after B1 approval)
   - Bundle Identifier at the top should match what you set in General
   - Xcode auto-creates a provisioning profile — wait for the green checkmark

If Xcode says "Failed to register bundle identifier" — it's taken, or you need
to reserve it via App Store Connect first.

## C8. Reserve app on App Store Connect

You can do this from your Windows browser (not Mac-specific).

1. Go to https://appstoreconnect.apple.com
2. **My Apps → +** → **New App**
3. Fill in:
   - **Platforms**: iOS
   - **Name**: StepBattle
   - **Primary Language**: English (India)
   - **Bundle ID**: pick the one you registered in Xcode (`com.vipasa.stepbattle`)
   - **SKU**: any internal code, e.g. `STEPBATTLE-IOS-001`
4. **Create** — reserves the bundle ID. Don't submit for review yet.

## C9. **[GUI]** Enable required iOS capabilities in Xcode

Runner target → **Signing & Capabilities** → **+ Capability** button (top-left):

Add:
- **Push Notifications** — required for FCM push
- **Background Modes** — check:
  - ✅ Background fetch
  - ✅ Remote notifications
  - ✅ Background processing (for step-count updates)
- **HealthKit** — iOS equivalent of Android Health Connect
- **Sign in with Apple** — **REQUIRED** by Apple review if you support Google
  Sign-in. Non-negotiable — Apple rejects apps that offer 3rd-party sign-in
  without also offering Apple sign-in.

## C10. Firebase iOS app registration

From your Windows browser:
1. Firebase Console → StepBattle project → gear icon → **Project Settings**
2. Scroll to **Your apps** → **Add app → iOS icon**
3. **iOS bundle ID**: `com.vipasa.stepbattle` (must match Xcode)
4. **App nickname**: `StepBattle iOS`
5. **App Store ID**: leave blank for now (fill in after your first App Store
   Connect submission)
6. Register
7. Download `GoogleService-Info.plist`
8. SCP the file to the Mac:
   ```powershell
   scp GoogleService-Info.plist stepbattle-mac:~/dev/stepBattle/ios/Runner/
   ```
9. **[GUI]** In Xcode: right-click the `Runner` folder in the sidebar → **Add Files
   to Runner** → select the plist → check **"Copy items if needed"** and
   **"Add to targets: Runner"**

## C11. Info.plist permission strings

iOS requires human-readable descriptions for every sensitive permission the app
requests. Missing strings = app crashes on permission request AND Apple review
rejects the build.

Via SSH on Mac, open `ios/Runner/Info.plist` in an editor (nano, or edit
locally on Windows and push via git). Add inside the top-level `<dict>`:

```xml
<key>NSHealthShareUsageDescription</key>
<string>StepBattle reads your daily step count to score battles and build streaks.</string>

<key>NSHealthUpdateUsageDescription</key>
<string>StepBattle records step data for battle history.</string>

<key>NSMotionUsageDescription</key>
<string>StepBattle uses motion data to count your steps automatically.</string>

<key>NSCameraUsageDescription</key>
<string>StepBattle needs camera access for profile photos.</string>

<key>NSPhotoLibraryUsageDescription</key>
<string>StepBattle needs photo access to set your profile picture.</string>

<key>NSPhotoLibraryAddUsageDescription</key>
<string>StepBattle saves battle share cards to your Photos.</string>

<key>NSLocationWhenInUseUsageDescription</key>
<string>StepBattle uses location during Track sessions to map your walk.</string>

<key>NSUserTrackingUsageDescription</key>
<string>StepBattle uses this to keep your battle history synced across devices.</string>
```

Then Google Sign-In URL scheme — find `REVERSED_CLIENT_ID` in
`GoogleService-Info.plist` (a value like `com.googleusercontent.apps.123...`),
then add to Info.plist:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>REVERSED_CLIENT_ID_VALUE_FROM_GOOGLE_SERVICE_INFO_PLIST</string>
    </array>
  </dict>
</array>
```

Commit and push:
```bash
cd ~/dev/stepBattle
git add ios/Runner/Info.plist ios/Runner/GoogleService-Info.plist
git commit -m "iOS Info.plist permissions + Firebase config"
git push origin main
```

## C12. APNs setup for iOS push notifications

FCM on iOS delivers via Apple Push Notification service (APNs). You need to give
Firebase your APNs key so it can sign and deliver pushes.

From your Windows browser:
1. Go to https://developer.apple.com/account/resources/authkeys/list
2. **Create a Key**:
   - Name: `StepBattle APNs`
   - Enable: **Apple Push Notifications service (APNs)**
   - Continue → Register → Download the `.p8` file (**you can only download it
     ONCE — store safely in a password manager**)
   - Note the **Key ID** shown on the download page
3. Go to Firebase Console → StepBattle project → **Project Settings → Cloud
   Messaging** tab
4. Under **Apple app configuration**, click **Upload** for **APNs Authentication
   Key**
5. Upload the `.p8` file, enter Key ID and your Team ID (found at
   https://developer.apple.com/account under Membership)
6. Save

Now iOS pushes work end-to-end.

## C13. Razorpay iOS registration

1. Log into Razorpay Dashboard → **Account & Settings → Website & App Settings**
2. Under **Apps**, click **Add App**
3. Type: **iOS**
4. **Bundle ID**: `com.vipasa.stepbattle` (must match Xcode)
5. Save

Razorpay whitelists this bundle ID for payment processing on iOS.

## C14. Supabase Auth OAuth redirect URIs for iOS

If you use Google Sign-In through Supabase, add iOS-specific redirect URIs:

1. Supabase Dashboard → **Authentication → URL Configuration**
2. Under **Redirect URLs**, add:
   ```
   com.vipasa.stepbattle://login-callback
   io.supabase.stepbattle://login-callback
   ```
3. Save

Adjust scheme names to match your app's actual URL schemes.

---

# 🏗 First iOS build

## Build script — run from Windows via SSH

Create `~/dev/stepBattle/build-ios.sh` on the Mac:

```bash
#!/bin/bash
set -euo pipefail

cd ~/dev/stepBattle

echo "→ Pulling latest code…"
git pull origin main

echo "→ Cleaning previous build…"
flutter clean

echo "→ Fetching Flutter deps…"
flutter pub get

echo "→ Installing iOS pods…"
cd ios && pod install && cd ..

echo "→ Building iOS release IPA…"
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist

echo ""
echo "✅ Build complete."
echo "IPA is at: $(pwd)/build/ios/ipa/*.ipa"
```

Make it executable:
```bash
chmod +x ~/dev/stepBattle/build-ios.sh
```

You'll also need `ios/ExportOptions.plist` — create it via **Xcode → Product →
Archive → Distribute → App Store Connect** the first time; Xcode generates it
for you. Copy it into the repo so future CLI builds use it.

**From Windows, kick a build:**
```powershell
ssh stepbattle-mac "bash ~/dev/stepBattle/build-ios.sh"
```

Takes ~15-30 minutes the first time (compiling all native pods). Subsequent
builds are much faster (~3-5 minutes).

## Upload to TestFlight (first-time)

Two paths:

**A. Via Xcode GUI** (Screen Sharing) — easiest for first upload:
1. Xcode → **Product → Archive**
2. When archive completes → **Distribute App → App Store Connect → Upload**
3. Follow prompts
4. Once uploaded, wait ~10-30 min for App Store Connect processing

**B. Via CLI + Fastlane** (faster once set up):
```bash
brew install fastlane
cd ~/dev/stepBattle/ios
fastlane init
# follow prompts, choose "Manual setup"
```
Then a `Fastfile` lets you run: `fastlane beta` to build + upload in one command.

---

# 🔁 Ongoing development workflow

The typical loop once everything is set up:

```
[Windows: edit Dart code] → git commit + push
                              ↓
[Windows: SSH into Mac] → git pull + build-ios.sh
                              ↓
[Mac: IPA generated]      → uploaded to TestFlight (via Xcode or fastlane)
                              ↓
[TestFlight → your phone] → install & test
```

For quick UI iteration, you can also:
- **Run in iOS Simulator** on the Mac (via SSH): `flutter run -d iphone`
- Use **VNC/Screen Sharing** to see the simulator visually
- Or use `flutter run --release --no-sound-null-safety` for closer-to-prod behavior

---

# 🚨 Known gotchas for StepBattle-specific packages

## `flutter_3d_controller_fork` (vendored 3D character viewer)
- Your project vendors a fork under `packages/flutter_3d_controller_fork/`
- iOS support is unverified — test the arena scene ASAP after first build
- If it breaks on iOS, may need upstream patches or a per-platform code branch

## `razorpay_flutter`
- iOS has stricter background rules — Razorpay checkout must be in foreground
- SDK works but occasionally hangs on cancel; test refund flow end-to-end

## `pedometer` + `health`
- iOS uses HealthKit (needs the capability in C9 above)
- Free-tier Apple accounts CAN test HealthKit on simulator, but real step data
  needs a physical device
- StepBattle's step sync logic may need iOS-specific branches — Motion Coprocessor
  data delivery is different from Android's TYPE_STEP_COUNTER

## `flutter_local_notifications`
- iOS notification categories and actions need explicit registration in native
  code — check the package docs for the AppDelegate.swift changes

## `sentry_flutter` / `posthog_flutter`
- Both need iOS-specific init — check pubspec docs

---

# 📅 Ongoing maintenance calendar

Set calendar reminders:

- **11 months from Developer enrollment** → Apple Developer renewal ($99)
- **11 months from Distribution certificate** → cert renewal in Xcode
- **Every Xcode update** → run `flutter doctor -v` to catch toolchain regressions
- **Every 30 days on the Mac** → `brew upgrade` to keep Homebrew packages fresh

---

# 🆘 Troubleshooting quick reference

| Symptom | Fix |
|---|---|
| SSH hangs from Windows | Check Tailscale is running on both. `tailscale status` on the Mac should show Windows as connected. |
| `pod install` fails with "no such module" | `pod repo update && pod install --repo-update` |
| Xcode build fails with signing errors | Check Team is selected in Signing & Capabilities. Delete `~/Library/Developer/Xcode/DerivedData` and re-build. |
| Flutter doctor shows Xcode red | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| Push notifications not arriving on iOS | Verify APNs .p8 key was uploaded to Firebase Console. Verify Push Notifications capability is enabled in Xcode. |
| App crashes on launch with "NSHealthShareUsageDescription" error | Missing Info.plist string — see C11 |
| Google Sign-In redirect fails | Verify REVERSED_CLIENT_ID in Info.plist CFBundleURLSchemes matches GoogleService-Info.plist |

---

# ✅ Progress checklist

Copy this checklist and check items off as you complete them.

## Phase A (before Mac leaves)
- [ ] A1. Tailscale installed on Mac + Windows, both online
- [ ] A2. Remote Login enabled on Mac
- [ ] A3. SSH key auth working from Windows
- [ ] A4. SSH alias `stepbattle-mac` configured in Windows ~/.ssh/config
- [ ] A5. Screen Sharing enabled on Mac
- [ ] A6. Sleep + power settings adjusted; Amphetamine installed
- [ ] A7. End-to-end test: SSH works via mobile hotspot (Tailscale routing verified)

## Phase B (in parallel, starts external clocks)
- [ ] B1. Apple Developer Program enrollment submitted
- [ ] B2. Latest code pushed to GitHub

## Phase C (after Mac in Germany + Developer approved)
- [ ] C1. CocoaPods installed via Homebrew
- [ ] C2. Xcode command-line tools installed + license accepted
- [ ] C3. `flutter doctor -v` all-green for iOS toolchain
- [ ] C4. StepBattle repo cloned on Mac at `~/dev/stepBattle`
- [ ] C5. iOS platform added via `flutter create --platforms=ios .` (if missing)
- [ ] C6. `flutter pub get` + `pod install` succeed
- [ ] C7. Bundle identifier + Team configured in Xcode
- [ ] C8. App reserved in App Store Connect
- [ ] C9. All iOS capabilities added (Push, Background, HealthKit, Sign in with Apple)
- [ ] C10. Firebase iOS app registered + GoogleService-Info.plist added
- [ ] C11. Info.plist permission strings + Google URL scheme added
- [ ] C12. APNs .p8 key created + uploaded to Firebase
- [ ] C13. iOS bundle registered in Razorpay Dashboard
- [ ] C14. Supabase Auth iOS redirect URIs added

## First build
- [ ] `build-ios.sh` runs cleanly from Windows via SSH
- [ ] IPA uploaded to TestFlight (via Xcode Distribute → App Store Connect)
- [ ] Install via TestFlight on physical iPhone (Vipasa or friend)
- [ ] Smoke test: sign in, view Home, create battle, take steps, view arena
- [ ] Report first bugs — expect several since iOS has never been tested

---

**When something goes wrong or you're unsure of a step, come back to this doc's
section for that step. If it's still unclear, ping Claude in a new session with
the specific step number.**
