import 'package:app/core/permission_policy.dart';
import 'package:app/features/master_data/lookups_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Finder tableCellText(String value) => find.byWidgetPredicate(
    (widget) => widget is Text && widget.data == value,
  );

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

    expect(tableCellText(firstCity), findsOneWidget);
    expect(tableCellText(secondCity), findsOneWidget);

    final searchField = find.byType(TextField);
    await tester.enterText(searchField, firstCity);
    await tester.pumpAndSettle();
    expect(tableCellText(firstCity), findsOneWidget);
    expect(tableCellText(secondCity), findsNothing);
    expect(find.textContaining('النتائج: 1 من 2'), findsOneWidget);

    await tester.tap(find.byTooltip('مسح البحث'));
    await tester.pumpAndSettle();
    expect(tableCellText(firstCity), findsOneWidget);
    expect(tableCellText(secondCity), findsOneWidget);

    await tester.enterText(searchField, 'عبارة غير موجودة');
    await tester.pumpAndSettle();
    expect(find.text('لا توجد نتائج مطابقة لعبارة البحث'), findsOneWidget);
    expect(tableCellText(firstCity), findsNothing);
  });

  testWidgets('searches cost centers by their visible code', (tester) async {
    const targetName = 'مركز التكلفة المستهدف';
    const otherName = 'مركز تكلفة آخر';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LookupTab(
            config: LookupConfig('مراكز التكلفة', 'cost_centers', const [
              'name',
            ]),
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
    expect(tableCellText(targetName), findsOneWidget);
    expect(tableCellText(otherName), findsNothing);
  });

  testWidgets('bank lookup repairs invalid account links using cash accounts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LookupTab(
            config: LookupConfig('البنوك', 'banks', const [
              'name',
              'account_id',
            ]),
            displayFields: const ['name', 'account_id'],
            dataLoader: () async => const [
              {'id': 1, 'name': 'بنك تجريبي', 'account_id': 5},
            ],
            bankAccountLoader: () async => const [
              {'id': 9, 'code': '1102', 'name': 'البنك'},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tableCellText('حساب غير صالح (#5)'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('الحساب المرتبط حاليًا غير صالح'),
      findsOneWidget,
    );
    expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
    expect(find.byType(TextFormField), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    expect(find.text('1102 — البنك'), findsOneWidget);
  });
}
