import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart' show Hmac, Pbkdf2, SecretKey;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _hashKey = 'teacher_pin_hash';
const _saltKey = 'teacher_pin_salt';
const _plainKey = 'teacher_pin_plain';

/// The Teachers PIN: one PIN every teacher on the device knows, guarding
/// the Teachers area. There each teacher signs in with their own PIN
/// (`TeacherProfileService`).
///
/// This keeps a curious learner on a shared classroom device out of the
/// class lists and the lesson materials. It is a classroom lock, not
/// security: a 4–8 digit PIN can be brute-forced by anyone who can copy the
/// app's files, and there is no account behind it. Only a salted hash is
/// stored, so the PIN itself is never readable from the preferences file.
///
/// With no PIN set nothing is gated — existing installs behave as before
/// until a teacher opts in.
class TeacherPin {
  static final _format = RegExp(r'^\d{4,8}$');

  static bool isValidFormat(String pin) => _format.hasMatch(pin);

  Future<bool> isSet() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_hashKey) != null;
  }

  Future<void> set(String pin) async {
    if (!isValidFormat(pin)) {
      throw ArgumentError('A PIN is 4 to 8 digits.');
    }
    final salt = newPinSalt();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_saltKey, salt);
    await prefs.setString(_hashKey, await hashPinStrong(salt, pin));
    await prefs.remove(_plainKey);
  }

  /// The Teachers PIN in the clear, for the Admin to look up; null when
  /// none is set, or when it was set before this was stored.
  Future<String?> plain() async => null;

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_hashKey);
    await prefs.remove(_saltKey);
    await prefs.remove(_plainKey);
  }

  /// True when [pin] is right — or when no PIN is set at all.
  Future<bool> verify(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final hash = prefs.getString(_hashKey);
    final salt = prefs.getString(_saltKey);
    if (hash == null || salt == null) return true;
    if (!await pinMatches(salt, pin, hash)) return false;
    if (pinNeedsUpgrade(hash)) {
      await prefs.setString(_hashKey, await hashPinStrong(salt, pin));
    }
    return true;
  }
}

/// The old PIN hash: one round of salted SHA-256. Still verified, never
/// written; a PIN stored this way is rehashed by [hashPinStrong] the next
/// time it is entered correctly.
String hashPin(String salt, String pin) =>
    sha256.convert(utf8.encode('$salt:$pin')).toString();

const _strongPrefix = 'pbkdf2\$';

/// PBKDF2 rounds for a new PIN hash. Kept moderate: it runs on every
/// sign-in and learner switch on 4 GB phones. A 4–8 digit PIN stays
/// guessable from a copied file whatever the rounds; encryption at rest
/// is the real protection.
@visibleForTesting
int pinKdfRounds = 20000;

/// A PIN hash for storing: `pbkdf2$<rounds>$<hex>`, PBKDF2-HMAC-SHA256 over
/// the salted PIN, computed off the UI isolate.
Future<String> hashPinStrong(String salt, String pin, {int? rounds}) {
  final r = rounds ?? pinKdfRounds;
  Future<String> work() async {
    final key =
        await Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: r,
          bits: 256,
        ).deriveKey(
          secretKey: SecretKey(utf8.encode(pin)),
          nonce: utf8.encode('otic-pin:$salt'),
        );
    final hex = [
      for (final b in await key.extractBytes())
        b.toRadixString(16).padLeft(2, '0'),
    ].join();
    return '$_strongPrefix$r\$$hex';
  }

  return pinHashInIsolate ? Isolate.run(work) : work();
}

/// Off in widget tests, whose fake clock never waits for an isolate.
@visibleForTesting
bool pinHashInIsolate = true;

/// Whether [pin] matches [stored], in either format.
Future<bool> pinMatches(String salt, String pin, String stored) async {
  if (!stored.startsWith(_strongPrefix)) return hashPin(salt, pin) == stored;
  final rounds = int.tryParse(stored.split(r'$')[1]);
  if (rounds == null || rounds < 1) return false;
  return await hashPinStrong(salt, pin, rounds: rounds) == stored;
}

/// Whether [stored] is in the old format and should be rehashed.
bool pinNeedsUpgrade(String stored) => !stored.startsWith(_strongPrefix);

/// A fresh random salt for [hashPin].
String newPinSalt() {
  final rng = Random.secure();
  return base64Url.encode(List<int>.generate(16, (_) => rng.nextInt(256)));
}

final teacherPinProvider = Provider((ref) => TeacherPin());

/// Whether the teacher has entered the PIN in this app session.
///
/// In memory only, so the lock returns on restart, and cleared whenever the
/// device is handed to a learner (see `LearnerSwitcher`).
final teacherUnlockedProvider = StateProvider<bool>((ref) => false);

/// Routes behind the Teachers PIN. Admin has its own PIN (`AdminScreen`).
bool isTeacherRoute(String location) =>
    location == '/teacher' ||
    location.startsWith('/teacher/') ||
    location == '/teachers' ||
    location.startsWith('/teachers/');

/// Where a request for a teacher tool (`/teacher*`) goes when no teacher
/// is signed in: to Teachers, where they sign in or create a profile.
/// Null to carry on. `/teachers` itself needs only the Teachers PIN.
String? teacherProfileRedirect(Uri uri, {required bool signedIn}) {
  final path = uri.path;
  if (path != '/teacher' && !path.startsWith('/teacher/') && !path.startsWith('/teachers/')) return null;
  return signedIn ? null : '/teachers';
}

/// Where the router should send a request for [uri], or null to let it
/// through: a locked teacher route goes to the PIN screen, carrying the
/// original destination so the teacher lands where they were going.
String? teacherGateRedirect(
  Uri uri, {
  required bool unlocked,
  required bool pinSet,
}) {
  if (!pinSet || unlocked || !isTeacherRoute(uri.path)) return null;
  return Uri(
    path: '/unlock',
    queryParameters: {'to': uri.toString()},
  ).toString();
}
