import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../models/user_model.dart';

class AuthService {
  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final GoogleSignIn _googleSignIn;

  AuthService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    GoogleSignIn? googleSignIn,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _googleSignIn = googleSignIn ?? GoogleSignIn();

  // ---------------------------------------------------------------------------
  // Auth state
  // ---------------------------------------------------------------------------

  User? get currentUser => _auth.currentUser;

  Stream<User?> authStateChanges() => _auth.authStateChanges();

  // ---------------------------------------------------------------------------
  // Sign in methods
  // ---------------------------------------------------------------------------

  Future<UserCredential> signInWithGoogle() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) {
      throw FirebaseAuthException(
        code: 'sign-in-cancelled',
        message: 'Google sign-in was cancelled.',
      );
    }
    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    return _auth.signInWithCredential(credential);
  }

  Future<UserCredential> signInWithApple() async {
    final appleProvider = AppleAuthProvider()
      ..addScope('email')
      ..addScope('name');
    return _auth.signInWithProvider(appleProvider);
  }

  Future<UserCredential> signInWithEmail(String email, String password) async {
    return _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  Future<UserCredential> signUpWithEmail(String email, String password) async {
    return _auth.createUserWithEmailAndPassword(
        email: email, password: password);
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
  }

  // ---------------------------------------------------------------------------
  // Firestore user doc
  // ---------------------------------------------------------------------------

  DocumentReference<Map<String, dynamic>> _userDoc(String uid) =>
      _firestore.collection('users').doc(uid);

  /// Check if user doc exists in Firestore (i.e., has completed onboarding).
  Future<bool> userDocExists(String uid) async {
    final doc = await _userDoc(uid).get();
    return doc.exists;
  }

  /// Fetch user model from Firestore.
  Future<UserModel?> getUser(String uid) async {
    final doc = await _userDoc(uid).get();
    if (!doc.exists) return null;
    return UserModel.fromFirestore(doc);
  }

  /// Stream of user model changes.
  Stream<UserModel?> watchUser(String uid) {
    return _userDoc(uid).snapshots().map((doc) {
      if (!doc.exists) return null;
      return UserModel.fromFirestore(doc);
    });
  }

  /// Create the initial user document after onboarding.
  Future<void> createUserDoc({
    required String uid,
    required String email,
    required String displayName,
    required int dailyStepGoal,
    String? avatarURL,
  }) async {
    final now = DateTime.now();
    final userCode = await _generateUniqueUserCode();
    final user = UserModel(
      userId: uid,
      userCode: userCode,
      displayName: displayName,
      avatarURL: avatarURL,
      email: email,
      dailyStepGoal: dailyStepGoal,
      createdAt: now,
      lastActiveAt: now,
    );
    await _userDoc(uid).set(user.toFirestore());
  }

  /// Generate a userCode not in use by another user. Retries up to 5 times.
  Future<String> _generateUniqueUserCode() async {
    for (var i = 0; i < 5; i++) {
      final code = UserModel.generateUserCode();
      final existing = await _firestore
          .collection('users')
          .where('userCode', isEqualTo: code)
          .limit(1)
          .get();
      if (existing.docs.isEmpty) return code;
    }
    // Extremely unlikely. Fall back to timestamp-suffixed code.
    return '#${DateTime.now().microsecondsSinceEpoch.toRadixString(36).toUpperCase().substring(0, 5)}';
  }

  /// Update specific fields on the user document.
  Future<void> updateUser(String uid, Map<String, dynamic> data) async {
    await _userDoc(uid).update(data);
  }

  /// Backfill any missing fields on an existing user doc.
  /// Called after sign-in to handle schema migrations non-destructively.
  /// Safe to call every launch — only writes if something is missing.
  Future<void> ensureUserDataComplete(String uid) async {
    final doc = await _userDoc(uid).get();
    if (!doc.exists) return; // Not onboarded yet
    final data = doc.data()!;

    final updates = <String, dynamic>{};

    // 1. userCode — generate if missing
    final code = data['userCode'] as String?;
    if (code == null || code.isEmpty) {
      updates['userCode'] = await _generateUniqueUserCode();
    }

    // 2. XP tracking fields — default to 0/empty if absent
    if (data['lastStepXPThreshold'] == null) {
      updates['lastStepXPThreshold'] = 0;
    }
    if (data['lastStepXPDate'] == null) {
      updates['lastStepXPDate'] = '';
    }

    if (updates.isNotEmpty) {
      await _userDoc(uid).update(updates);
    }
  }
}

class FirebaseAuthException implements Exception {
  final String code;
  final String message;
  const FirebaseAuthException({required this.code, required this.message});

  @override
  String toString() => 'FirebaseAuthException($code): $message';
}
