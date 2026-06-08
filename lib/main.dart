import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';
import 'firebase_options.dart';
import 'services/background_sync.dart';
import 'services/native_step_service.dart';
import 'utils/app_logger.dart';

/// Top-level FCM background/terminated message handler. Must be a top-level
/// (or static) function annotated with `@pragma('vm:entry-point')` because it
/// runs in its own isolate. The OS renders `notification` messages itself, so
/// there's nothing to do here for the wake-the-phone use case.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Silent "sync_wake" pushes (sent ~2 min before a battle ends) wake the app
  // so it uploads fresh steps before the server freezes the score. Other
  // (visible) notifications are rendered by the OS; nothing to do for them.
  if (message.data['type'] == 'sync_wake') {
    await headlessStepSync();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hive must be initialized before any service that persists state.
  // The native step tracker needs its baseline persisted across launches.
  await Hive.initFlutter();
  await Hive.openBox(NativeStepService.boxName);

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Register the FCM background handler so push sent by the server (battle
  // results, invites) is delivered while the app is backgrounded/terminated.
  // `notification`-type messages are shown by the OS automatically; this
  // handler just keeps data payloads from being dropped.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Load .env (bundled as an asset) BEFORE initializing Supabase. Treat
  // missing values as fatal in debug so we notice locally; in release we
  // fall through to a placeholder so the app at least starts (Firestore
  // paths still work) — Supabase calls will fail loudly via RLS denial.
  await dotenv.load(fileName: '.env');
  final supaUrl = dotenv.env['SUPABASE_URL'];
  final supaKey = dotenv.env['SUPABASE_ANON_KEY'];
  if (supaUrl == null || supaUrl.isEmpty || supaKey == null || supaKey.isEmpty) {
    AppLogger.session.e('supabaseInit:missingEnv', fields: {
      'hasUrl': supaUrl != null && supaUrl.isNotEmpty,
      'hasKey': supaKey != null && supaKey.isNotEmpty,
    });
    assert(false,
        '.env is missing SUPABASE_URL or SUPABASE_ANON_KEY. Copy .env.example.');
  } else {
    await Supabase.initialize(url: supaUrl, anonKey: supaKey);
    AppLogger.session.i('supabaseInit:done', fields: {'url': supaUrl});
  }

  // Background sync plumbing (foreground-service config + WorkManager init).
  // Android-only inside; safe no-op elsewhere. The periodic task itself is
  // registered after login (see MainShell), and the foreground service is
  // started/stopped based on active battles.
  await BackgroundSync.initEarly();

  // Emit a session header so per-session log folders start with build/device
  // context. Wrapped so a logging hiccup never blocks app startup.
  unawaited(_emitSessionHeader());

  // Catch every unhandled framework error and surface it into _session.log
  // — these otherwise vanish into the platform stderr.
  FlutterError.onError = (details) {
    AppLogger.session.e(
      'flutterError',
      fields: {'library': details.library, 'context': details.context?.toString()},
      error: details.exception,
      stack: details.stack,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.session.e('platformError', error: error, stack: stack);
    return false;
  };

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0E0E10),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(
    const ProviderScope(
      child: StepBattleApp(),
    ),
  );
}

Future<void> _emitSessionHeader() async {
  try {
    final pkg = await PackageInfo.fromPlatform();
    final fields = <String, dynamic>{
      'appName': pkg.appName,
      'version': pkg.version,
      'build': pkg.buildNumber,
      'package': pkg.packageName,
    };
    final deviceInfo = DeviceInfoPlugin();
    if (defaultTargetPlatform == TargetPlatform.android) {
      final a = await deviceInfo.androidInfo;
      fields.addAll({
        'platform': 'android',
        'model': a.model,
        'manufacturer': a.manufacturer,
        'sdkInt': a.version.sdkInt,
        'release': a.version.release,
      });
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      final i = await deviceInfo.iosInfo;
      fields.addAll({
        'platform': 'ios',
        'model': i.utsname.machine,
        'systemVersion': i.systemVersion,
      });
    }
    AppLogger.session.i('sessionStart', fields: fields);
  } catch (e, s) {
    AppLogger.session.e('sessionHeaderFailed', error: e, stack: s);
  }
}
