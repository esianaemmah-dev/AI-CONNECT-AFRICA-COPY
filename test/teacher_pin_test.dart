import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_connect_africa/features/teacher/teacher_pin.dart';
import 'package:ai_connect_africa/features/teacher/teacher_pin_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('TeacherPin', () {
    test('no PIN set means nothing is locked', () async {
      final pin = TeacherPin();
      expect(await pin.isSet(), isFalse);
      expect(await pin.verify('anything'), isTrue);
    });

    test('verifies the right PIN, rejects others', () async {
      final pin = TeacherPin();
      await pin.set('2468');
      expect(await pin.isSet(), isTrue);
      expect(await pin.verify('2468'), isTrue);
      expect(await pin.verify('2469'), isFalse);
      expect(await pin.verify(''), isFalse);
    });

    test('keeps the PIN so the Admin can look it up, and clears it', () async {
      final pin = TeacherPin();
      expect(await pin.plain(), isNull, reason: 'none set yet');
      await pin.set('2468');
      expect(await pin.plain(), isNull);
      await pin.clear();
      expect(await pin.plain(), isNull);
      expect(await pin.isSet(), isFalse);
    });

    test('the same PIN hashes differently on each set (salted)', () async {
      final pin = TeacherPin();
      final prefs = await SharedPreferences.getInstance();
      await pin.set('2468');
      final first = prefs.getString('teacher_pin_hash');
      await pin.set('2468');
      expect(prefs.getString('teacher_pin_hash'), isNot(first));
      expect(await pin.verify('2468'), isTrue);
    });

    test('rejects malformed PINs and can be removed', () async {
      final pin = TeacherPin();
      expect(() => pin.set('12'), throwsArgumentError);
      expect(() => pin.set('12ab'), throwsArgumentError);
      await pin.set('12345678');
      await pin.clear();
      expect(await pin.isSet(), isFalse);
    });
  });

  group('teacherProfileRedirect — teacher tools need a teacher signed in',
      () {
    String? gate(String path, {required bool signedIn}) =>
        teacherProfileRedirect(Uri.parse(path), signedIn: signedIn);

    test('signed out, the tools send the teacher to Teachers to sign in', () {
      expect(gate('/teacher', signedIn: false), '/teachers');
      expect(gate('/teacher/materials', signedIn: false), '/teachers');
      expect(gate('/teacher/sync', signedIn: false), '/teachers');
      expect(gate('/teachers/cloud', signedIn: false), '/teachers');
      expect(gate('/teachers/cloud', signedIn: true), isNull);
    });

    test('signed in, the tools open — on any device', () {
      expect(gate('/teacher', signedIn: true), isNull);
      expect(gate('/teacher/materials', signedIn: true), isNull);
    });

    test('Teachers itself and other routes need no profile', () {
      expect(gate('/teachers', signedIn: false), isNull, reason: 'no loop');
      expect(gate('/admin', signedIn: false), isNull);
      expect(gate('/class-sync', signedIn: false), isNull);
    });
  });

  group('teacherGateRedirect', () {
    String? gate(String path, {bool unlocked = false, bool pinSet = true}) =>
        teacherGateRedirect(Uri.parse(path),
            unlocked: unlocked, pinSet: pinSet);

    test('locks teacher routes, keeping the destination', () {
      expect(gate('/teacher'), '/unlock?to=%2Fteacher');
      expect(gate('/teacher/materials'), '/unlock?to=%2Fteacher%2Fmaterials');
      expect(gate('/teacher/7'), isNotNull);
      expect(gate('/teachers'), '/unlock?to=%2Fteachers');
      expect(gate('/admin'), isNull, reason: 'Admin has its own PIN');
    });

    test('lets everything through when unlocked or no PIN is set', () {
      expect(gate('/teacher', unlocked: true), isNull);
      expect(gate('/admin', pinSet: false), isNull);
    });

    test('never gates learner routes', () {
      for (final path in ['/', '/learners', '/settings', '/teachers-lounge']) {
        expect(gate(path), isNull, reason: path);
      }
    });
  });

  testWidgets('unlock screen: wrong PIN errors, right PIN continues',
      (tester) async {
    await tester.runAsync(() => TeacherPin().set('2468'));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/unlock',
      routes: [
        GoRoute(
          path: '/unlock',
          builder: (_, __) =>
              const TeacherUnlockScreen(destination: '/teacher'),
        ),
        GoRoute(
          path: '/teacher',
          builder: (_, __) => const Text('teacher dashboard'),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    await tester.enterText(find.byType(TextField), '1111');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('That PIN is not right.'), findsOneWidget);
    expect(container.read(teacherUnlockedProvider), isFalse);
    expect(find.text('teacher dashboard'), findsNothing);

    await tester.enterText(find.byType(TextField), '2468');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(container.read(teacherUnlockedProvider), isTrue);
    expect(find.text('teacher dashboard'), findsOneWidget);
  });
}
