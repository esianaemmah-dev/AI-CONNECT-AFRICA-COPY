import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// Local account throttling survives an app restart. No credentials are stored.
class LocalAuthThrottle {
  static final _queues = <String, Future<bool>>{};
  Future<bool> check(String account, Future<bool> Function() verify) {
    final previous = _queues[account] ?? Future.value(false);
    final next = previous.then(
      (_) => _check(account, verify),
      onError: (Object _, StackTrace __) => _check(account, verify),
    );
    _queues[account] = next;
    return next.whenComplete(() {
      if (identical(_queues[account], next)) _queues.remove(account);
    });
  }

  Future<bool> _check(String account, Future<bool> Function() verify) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'auth_attempts_$account';
    final until = prefs.getInt('${key}_until') ?? 0;
    if (DateTime.now().millisecondsSinceEpoch < until) return false;
    if (await verify()) {
      await prefs.remove(key);
      await prefs.remove('${key}_until');
      return true;
    }
    final failures = (prefs.getInt(key) ?? 0) + 1;
    await prefs.setInt(key, failures >= 5 ? 0 : failures);
    if (failures >= 5) {
      await prefs.setInt(
        '${key}_until',
        DateTime.now().add(const Duration(seconds: 30)).millisecondsSinceEpoch,
      );
    }
    return false;
  }
}

class StaffLease {
  final issuedAt = DateTime.now();
  DateTime lastActivity = DateTime.now();
  DateTime authenticatedAt = DateTime.now();
  bool revoked = false;
  bool get valid =>
      !revoked &&
      DateTime.now().difference(issuedAt) < const Duration(hours: 1) &&
      DateTime.now().difference(lastActivity) < const Duration(minutes: 5);
  bool get fresh =>
      valid &&
      DateTime.now().difference(authenticatedAt) < const Duration(seconds: 60);
  void touch() {
    if (valid) lastActivity = DateTime.now();
  }

  void requireValid({bool sensitive = false}) {
    if (!valid || (sensitive && !fresh)) {
      throw StateError('Sign in again to continue.');
    }
    touch();
  }
}

String newRecoveryCode() => base64UrlEncode(
  List<int>.generate(24, (_) => Random.secure().nextInt(256)),
);
