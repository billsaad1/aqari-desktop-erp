import 'package:app/core/permission_policy.dart';
import 'package:app/features/master_data/lookups_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  tearDown(() => PermissionRuntime.clear());

  testWidgets('filters lookup names, clears search and shows no-match state', (
    tester,
  ) async {
    const firstCity = 'مدينة الاختبار ألف';
    const secondCity = 'مدينة الاختبار باء';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LookupTab(
            config: LookupConfig('المدن', 'cities', const ['name']),
            displayFields: const ['name'],
            dataLoader: () async => const [
              {'id': 1, 'name': firstCity},
              {'id': 2, 'name': secondCity},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(firstCity), findsOneWidget);
    expect(find.text(secondCity), findsOneWidget);

    final searchField = find.byType(TextField);
    await tester.enterText(searchField, firstCity);
    await tester.pumpAndSettle();
    expect(find.text(firstCity), findsOneWidget);
    expect(find.text(secondCity), findsNothing);
    expect(find.textContaining('النتائج: 1 من 2'), findsOneWidget);

    await tester.tap(find.byTooltip('مسح البحث'));
    await tester.pumpAndSettle();
    expect(find.text(firstCity), findsOneWidget);
    expect(find.text(secondCity), findsOneWidget);

    await tester.enterText(searchField, 'عبارة غير موجودة');
    await tester.pumpAndSettle();
    expect(find.text('لا توجد نتائج مطابقة لعبارة البحث'), findsOneWidget);
    expect(find.text(firstCity), findsNothing);
  });

  testWidgets('searches cost centers by their visible code', (tester) async {
    const targetName = 'مركز التكلفة المستهدف';
    const otherName = 'مركز تكلفة آخر';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LookupTab(
            config: LookupConfig('مراكز التكلفة', 'cost_centers', const ['name']),
            displayFields: const ['code', 'name'],
            dataLoader: () async => const [
              {'id': 1, 'code': 'CC927', 'name': targetName},
              {'id': 2, 'code': 'CC928', 'name': otherName},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'CC927');
    await tester.pumpAndSettle();
    expect(find.text(targetName), findsOneWidget);
    expect(find.text(otherName), findsNothing);
  });
}
