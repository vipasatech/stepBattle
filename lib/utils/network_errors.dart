import 'dart:io';

import 'package:flutter/services.dart';

/// Heuristic classifier for "is this exception a network / DNS failure?".
///
/// We can't always rely on the exception type — Google Sign-In surfaces
/// DNS failures as `PlatformException(code: 'network_error')`, Firestore
/// surfaces them as `FirebaseException(code: 'unavailable')` with a
/// `UnknownHostException` cause buried in the stringified message, and
/// raw HTTP calls throw `SocketException('Failed host lookup: ...')`. So
/// we sniff for any of these shapes and return true if it smells like
/// the device just isn't reachable.
///
/// The point of this helper is UX: when it returns true, show
/// [NoNetworkSheet] instead of a generic "something failed" message.
bool isNetworkError(Object error) {
  if (error is SocketException) return true;
  if (error is HandshakeException) return true;
  if (error is PlatformException && error.code == 'network_error') return true;

  final msg = error.toString().toLowerCase();
  return msg.contains('socketexception') ||
      msg.contains('failed host lookup') ||
      msg.contains('unknownhostexception') ||
      msg.contains('no address associated') ||
      msg.contains('unable to resolve host') ||
      msg.contains('cloud_firestore/unavailable') ||
      msg.contains('network is unreachable') ||
      // Google Sign-In ApiException 7 is "NETWORK_ERROR" on Android.
      msg.contains('apiexception: 7');
}
