import 'dart:io';

/// Whether in-app purchase affordances — Buy XP, the Pro/Family upgrade
/// path — may be rendered and opened on this platform.
///
/// **False on iOS.** App Store Review guideline 3.1.1 requires that any
/// digital content consumed inside the app (in-game currency, premium
/// feature unlocks, subscriptions) be sold through Apple's own in-app
/// purchase system. XP and Pro are squarely that, and we sell both
/// through Razorpay, so those affordances cannot exist inside the iOS
/// binary. Note *exist*, not *be disabled*: a visible button that
/// no-ops is still a 3.1.1 finding at review, and a dead control is
/// worse for the user than no control. Every gate keyed off this getter
/// removes the widget, it does not grey it out.
///
/// The Stripe checkouts you see in other iOS apps are not a precedent
/// for us — those sell physical goods and real-world services (rides,
/// deliveries, bookings), which guideline 3.1.5 says must NOT use IAP.
/// Different category, opposite rule.
///
/// **Decision 2026-11-17:** iOS ships free-only, and XP/Pro are sold on
/// stepbattle.fit instead — the same split BGMI runs with Midasbuy, and
/// Free Fire and Genshin with their web stores. A purchase made on the
/// web credits the same Supabase account, so an iOS user who buys there
/// sees the XP land in the app. What makes it legal is that the sale
/// happens outside the app; Apple's rules govern the binary, not your
/// website.
///
/// That carries one hard constraint: **the app must never link to, name
/// or hint at that store.** Apple's anti-steering rule under 3.1.1(a)
/// still applies outside the handful of storefronts with an external
/// purchase link entitlement (the US since May 2025, reportedly the EU,
/// Japan and Brazil). India has none, and India is where our users are.
/// So no "available on our website" copy, no URL in a support string,
/// nothing. Discovery happens off-platform or not at all.
///
/// **Android is untouched in every respect.** This getter is
/// unconditionally true there, so every branch guarded by it is the
/// pre-existing one, byte for byte.
class Purchases {
  Purchases._();

  static bool get enabled => !Platform.isIOS;
}
