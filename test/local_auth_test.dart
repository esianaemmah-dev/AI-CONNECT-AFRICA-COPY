import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_connect_africa/services/auth/local_auth.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'five failures persist a cooldown and never invoke verification while locked',
    () async {
      var called = 0;
      for (var i = 0; i < 5; i++) {
        expect(
          await LocalAuthThrottle().check('teacher:1', () async {
            called++;
            return false;
          }),
          isFalse,
        );
      }
      expect(
        await LocalAuthThrottle().check('teacher:1', () async {
          called++;
          return true;
        }),
        isFalse,
      );
      expect(called, 5);
      expect(
        await LocalAuthThrottle().check('teacher:2', () async => true),
        isTrue,
      );
    },
  );
  test(
    'success clears failures; sessions enforce idle expiry and revocation',
    () async {
      await LocalAuthThrottle().check('admin', () async => false);
      expect(
        await LocalAuthThrottle().check('admin', () async => true),
        isTrue,
      );
      expect(
        (await SharedPreferences.getInstance()).getInt('auth_attempts_admin'),
        isNull,
      );
      final lease = StaffLease();
      expect(lease.valid, isTrue);
      lease.lastActivity = DateTime.now().subtract(const Duration(minutes: 6));
      expect(() => lease.requireValid(), throwsStateError);
      lease.touch();
      expect(
        lease.valid,
        isFalse,
        reason: 'interaction cannot revive an expired session',
      );
      final revoked = StaffLease()..revoked = true;
      expect(() => revoked.requireValid(), throwsStateError);
    },
  );
  test('recovery codes contain 192 bits and are independently generated', () {
    final first = newRecoveryCode();
    expect(first.length, 32);
    expect(newRecoveryCode(), isNot(first));
  });
}
