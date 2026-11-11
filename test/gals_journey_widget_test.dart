import 'package:ai_connect_africa/db/otic_database.dart';
import 'package:ai_connect_africa/features/gals/gals_field_store.dart';
import 'package:ai_connect_africa/features/gals/gals_pack.dart';
import 'package:ai_connect_africa/features/gals/gals_screen.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('paper lesson to saved peer session through the screen', (
    tester,
  ) async {
    final db = OticDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    final store = GalsFieldStore(db);
    final pack = await GalsPack.load();
    final lesson = pack.lesson('vision-road-journey-lesson')!;
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [galsFieldStoreProvider.overrideWithValue(store)],
        child: const MaterialApp(home: GalsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('gals-lesson-${pack.lessons.first.id}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(lesson.title).last);
    await tester.pumpAndSettle();
    Future<void> tap(Finder target) async {
      await tester.ensureVisible(target);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    for (final q in lesson.quiz) {
      await tap(find.byKey(ValueKey('${q.id}-${q.correct}')));
    }
    await tester.enterText(
      find.byKey(const ValueKey('reflection')),
      'Ask peers to choose their own symbols.',
    );
    await tap(find.text('Continue to champion'));
    await tester.enterText(
      find.byKey(const ValueKey('champion-alias')),
      'Fictional Neri',
    );
    await tap(find.text('Save champion'));
    await tap(find.text('Save lesson completion'));
    final plan = pack.sessionPlans.singleWhere(
      (p) => p.id == lesson.sessionPlanId,
    );
    for (final activity in plan.activities) {
      await tap(find.byKey(ValueKey('activity-${activity.id}')));
    }
    await tester.enterText(find.byKey(const ValueKey('age-band')), 'Unknown');
    await tester.enterText(
      find.byKey(const ValueKey('location')),
      'Example Garden',
    );
    await tester.enterText(find.byKey(const ValueKey('attendance')), '4');
    await tap(find.text('Save sharing on this device'));
    expect(tester.takeException(), isNull);
    final champion = (await store.champions()).single;
    expect((await store.sharingFor(champion.id)).single.sessionAttendances, 4);
    await tap(find.text('5 Saved'));
    expect(find.textContaining('4 session attendances'), findsOneWidget);
  });
}
