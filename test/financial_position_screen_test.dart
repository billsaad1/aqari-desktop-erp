import 'dart:async';

import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/financial_position_screen.dart';
import 'package:app/models/financial_position_report_model.dart';
import 'package:app/providers/reports_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

FinancialPositionReport _report(String date) => FinancialPositionReport(
  asOfDate: date,
  currency: 'SAR',
  rows: const [
    FinancialPositionAccountRow(
      accountId: 1,
      accountCode: '1101',
      accountName: 'الصندوق الرئيسي',
      accountType: 'Asset',
      debitMinor: 100000,
      creditMinor: 0,
    ),
    FinancialPositionAccountRow(
      accountId: 2,
      accountCode: '3',
      accountName: 'رأس المال',
      accountType: 'Equity',
      debitMinor: 0,
      creditMinor: 80000,
    ),
    FinancialPositionAccountRow(
      accountId: 3,
      accountCode: '4101',
      accountName: 'إيراد إيجار',
      accountType: 'Revenue',
      debitMinor: 0,
      creditMinor: 30000,
    ),
    FinancialPositionAccountRow(
      accountId: 4,
      accountCode: '5101',
      accountName: 'مصروف إداري',
      accountType: 'Expense',
      debitMinor: 10000,
      creditMinor: 0,
    ),
  ],
);

void main() {
  tearDown(() {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  testWidgets('denies the report without reports.view', (tester) async {
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
          home: Scaffold(body: FinancialPositionScreen()),
        ),
      ),
    );

    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(find.text('قائمة المركز المالي الداخلية'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets('shows posted balance report and clears when view is revoked', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1100);
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
    var loaderCalled = false;
    final reports = ReportsProvider(
      financialPositionReportLoader: (date) async {
        loaderCalled = true;
        return _report(date);
      },
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: FinancialPositionScreen()),
        ),
      ),
    );
    await tester.tap(find.text('عرض القائمة'));
    await tester.pumpAndSettle();

    expect(loaderCalled, isTrue);
    expect(find.text('الصندوق الرئيسي'), findsOneWidget);
    expect(
      find.text('المعادلة متوازنة وفق تصنيف الحسابات المسجل في دليل الحسابات.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'معاينة / حفظ PDF'),
          )
          .onPressed,
      isNotNull,
    );

    PermissionRuntime.activate(
      userId: 44,
      role: 'DataEntry',
      permissionRows: const [],
    );
    await tester.pump();
    expect(reports.financialPositionReport, isNull);
    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  test('ignores a stale financial-position request after clearing', () async {
    final completer = Completer<FinancialPositionReport>();
    final reports = ReportsProvider(
      financialPositionReportLoader: (_) => completer.future,
    );

    final load = reports.loadFinancialPositionReport('2026-06-30');
    reports.clearFinancialPositionReport();
    completer.complete(_report('2026-06-30'));
    await load;

    expect(reports.financialPositionReport, isNull);
    expect(reports.isFinancialPositionReportLoading, isFalse);
    reports.dispose();
  });
}
