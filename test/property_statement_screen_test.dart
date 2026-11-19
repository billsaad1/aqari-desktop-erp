import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/property_statement_screen.dart';
import 'package:app/models/property_statement_report_model.dart';
import 'package:app/providers/reports_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

PropertyStatementReport _report({
  int? costCenterId = 7,
  List<PropertyStatementLine>? lines,
  List<PropertyStatementGap>? gaps,
  String startDate = '2026-01-01',
  String endDate = '2026-01-31',
}) => PropertyStatementReport(
  propertyId: 3,
  propertyName: 'عقار النخيل',
  ownerName: 'مالك النخيل',
  costCenterId: costCenterId,
  costCenterCode: 'CC-7',
  costCenterName: 'النخيل',
  currency: 'SAR',
  startDate: startDate,
  endDate: endDate,
  openingBalanceMinor: 0,
  totalDebitMinor: 0,
  totalCreditMinor: 150000,
  closingBalanceMinor: -150000,
  lines:
      lines ??
      const [
        PropertyStatementLine(
          date: '2026-01-10',
          journalEntryId: 5,
          journalLineId: 9,
          accountCode: '4101',
          accountName: 'إيراد إيجار',
          description: 'إيجار يناير',
          debitMinor: 0,
          creditMinor: 150000,
          runningBalanceMinor: -150000,
        ),
      ],
  gaps: gaps ?? const [],
);

void main() {
  tearDown(() {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  testWidgets('denies the statement without reports.view', (tester) async {
    PermissionRuntime.activate(
      userId: 44,
      role: 'DataEntry',
      permissionRows: const [],
    );
    final reports = ReportsProvider();

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: PropertyStatementScreen()),
        ),
      ),
    );

    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(find.text('كشف حساب العقار'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets('shows attributed lines and keeps print gated separately', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    PermissionRuntime.activate(
      userId: 44,
      role: 'DataEntry',
      permissionRows: [
        {
          'screen_name': 'reports',
          'can_view': 1,
          'can_add': 0,
          'can_edit': 0,
          'can_delete': 0,
          'can_print': 0,
          'can_post': 0,
        },
      ],
    );

    var statementLoaded = false;
    final reports = ReportsProvider(
      propertyStatementPropertiesLoader: () async => [
        {
          'id': 3,
          'name': 'عقار النخيل',
          'cost_center_id': 7,
          'cost_center_code': 'CC-7',
          'cost_center_name': 'النخيل',
          'center_property_count': 1,
        },
      ],
      propertyStatementLoader: (propertyId, startDate, endDate) async {
        statementLoaded = true;
        return _report(startDate: startDate, endDate: endDate);
      },
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: PropertyStatementScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('عقار النخيل').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'عرض الكشف'));
    await tester.pumpAndSettle();

    expect(statementLoaded, isTrue);
    expect(find.text('4101 - إيراد إيجار'), findsOneWidget);
    expect(find.text('إيجار يناير'), findsOneWidget);

    // View is granted, print is not: the actions must stay disabled.
    final printButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'طباعة'),
    );
    expect(printButton.onPressed, isNull);
    final saveButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'حفظ PDF'),
    );
    expect(saveButton.onPressed, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets('enables print when the print permission is granted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    PermissionRuntime.activate(
      userId: 45,
      role: 'Accountant',
      permissionRows: [
        {
          'screen_name': 'reports',
          'can_view': 1,
          'can_add': 0,
          'can_edit': 0,
          'can_delete': 0,
          'can_print': 1,
          'can_post': 0,
        },
      ],
    );

    final reports = ReportsProvider(
      propertyStatementPropertiesLoader: () async => [
        {'id': 3, 'name': 'عقار النخيل', 'cost_center_id': 7},
      ],
      propertyStatementLoader: (propertyId, startDate, endDate) async =>
          _report(startDate: startDate, endDate: endDate),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: PropertyStatementScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('عقار النخيل').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'عرض الكشف'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<ElevatedButton>(
            find.widgetWithText(ElevatedButton, 'طباعة'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'حفظ PDF'),
          )
          .onPressed,
      isNotNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets('discloses gaps instead of attributing them', (tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );

    final reports = ReportsProvider(
      propertyStatementPropertiesLoader: () async => [
        {'id': 3, 'name': 'عقار النخيل'},
      ],
      propertyStatementLoader: (propertyId, startDate, endDate) async =>
          _report(
            startDate: startDate,
            endDate: endDate,
            costCenterId: null,
            lines: const [],
            gaps: const [
              PropertyStatementGap(
                reason: PropertyStatementGapReason.propertyWithoutCostCenter,
                lineCount: 2,
                debitMinor: 50000,
                creditMinor: 50000,
              ),
            ],
          ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: PropertyStatementScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    expect(
      find.text('عقار النخيل — بلا مركز تكلفة'),
      findsWidgets,
    );
    await tester.tap(find.text('عقار النخيل — بلا مركز تكلفة').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'عرض الكشف'));
    await tester.pumpAndSettle();

    expect(
      find.text('حركات لم يتم إسنادها إلى هذا العقار'),
      findsOneWidget,
    );
    expect(find.text('مركز التكلفة: غير مرتبط'), findsOneWidget);
    expect(
      find.textContaining('العقار بلا مركز تكلفة'),
      findsOneWidget,
    );
    expect(
      find.text('لا توجد حركات مرحلة لهذا العقار خلال الفترة المحددة.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets('warns in the picker when a centre is shared', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );

    final reports = ReportsProvider(
      propertyStatementPropertiesLoader: () async => [
        {
          'id': 3,
          'name': 'عقار مشترك',
          'cost_center_id': 7,
          'center_property_count': 2,
        },
      ],
      propertyStatementLoader: (propertyId, startDate, endDate) async =>
          _report(
            startDate: startDate,
            endDate: endDate,
            costCenterId: 7,
            lines: const [],
            gaps: const [
              PropertyStatementGap(
                reason: PropertyStatementGapReason.sharedCostCenter,
                lineCount: 1,
                debitMinor: 0,
                creditMinor: 70000,
              ),
            ],
          ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: PropertyStatementScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    expect(find.text('عقار مشترك — مركز تكلفة مشترك'), findsWidgets);

    await tester.tap(find.text('عقار مشترك — مركز تكلفة مشترك').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'عرض الكشف'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('مركز تكلفة مشترك مع عقارات أخرى'),
      findsOneWidget,
    );
    expect(
      find.text('لا توجد حركات مرحلة لهذا العقار خلال الفترة المحددة.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets('clears the report when view permission is revoked', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    PermissionRuntime.activate(
      userId: 44,
      role: 'DataEntry',
      permissionRows: [
        {
          'screen_name': 'reports',
          'can_view': 1,
          'can_add': 0,
          'can_edit': 0,
          'can_delete': 0,
          'can_print': 0,
          'can_post': 0,
        },
      ],
    );

    final reports = ReportsProvider(
      propertyStatementPropertiesLoader: () async => [
        {'id': 3, 'name': 'عقار النخيل', 'cost_center_id': 7},
      ],
      propertyStatementLoader: (propertyId, startDate, endDate) async =>
          _report(startDate: startDate, endDate: endDate),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: PropertyStatementScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('عقار النخيل').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'عرض الكشف'));
    await tester.pumpAndSettle();
    expect(find.text('إيجار يناير'), findsOneWidget);

    PermissionRuntime.activate(
      userId: 44,
      role: 'DataEntry',
      permissionRows: const [],
    );
    await tester.pumpAndSettle();

    expect(reports.propertyStatementReport, isNull);
    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });
}
