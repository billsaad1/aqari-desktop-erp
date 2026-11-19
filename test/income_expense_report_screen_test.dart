import 'dart:async';

import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/income_expense_report_screen.dart';
import 'package:app/models/income_expense_report_model.dart';
import 'package:app/providers/reports_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  tearDown(() {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  testWidgets('denies the report screen without reports.view', (tester) async {
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
          home: Scaffold(body: IncomeExpenseReportScreen()),
        ),
      ),
    );

    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(find.text('حركة الإيرادات والمصروفات'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets('shows ledger-based revenue, expense, and period net result', (
    tester,
  ) async {
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
      incomeExpenseReportLoader: (startDate, endDate) async {
        loaderCalled = true;
        return IncomeExpenseReport(
          startDate: startDate,
          endDate: endDate,
          currency: 'SAR',
          rows: const [
            IncomeExpenseAccountRow(
              accountId: 1,
              accountCode: '4101',
              accountName: 'إيراد إيجار',
              accountType: 'Revenue',
              debitMinor: 500,
              creditMinor: 8000,
            ),
            IncomeExpenseAccountRow(
              accountId: 2,
              accountCode: '5101',
              accountName: 'مصروف صيانة',
              accountType: 'Expense',
              debitMinor: 2500,
              creditMinor: 500,
            ),
          ],
        );
      },
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: IncomeExpenseReportScreen()),
        ),
      ),
    );
    await tester.tap(find.text('عرض التقرير'));
    await tester.pumpAndSettle();

    expect(loaderCalled, isTrue);
    expect(find.text('إيراد إيجار'), findsOneWidget);
    expect(find.text('مصروف صيانة'), findsOneWidget);
    expect(find.text('صافي الإيرادات'), findsOneWidget);
    expect(find.text('صافي المصروفات'), findsOneWidget);
    expect(find.text('صافي نتيجة الفترة'), findsNWidgets(2));
    expect(reports.incomeExpenseReport?.revenueNetMinor, 7500);
    expect(reports.incomeExpenseReport?.expenseNetMinor, 2000);
    expect(reports.incomeExpenseReport?.netResultMinor, 5500);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'معاينة التقرير'),
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
    expect(reports.incomeExpenseReport, isNull);
    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  test('ignores a stale report request after clearing', () async {
    final completer = Completer<IncomeExpenseReport>();
    final reports = ReportsProvider(
      incomeExpenseReportLoader: (_, _) => completer.future,
    );

    final load = reports.loadIncomeExpenseReport('2026-01-01', '2026-01-31');
    reports.clearIncomeExpenseReport();
    completer.complete(
      IncomeExpenseReport(
        startDate: '2026-01-01',
        endDate: '2026-01-31',
        currency: 'SAR',
        rows: const [],
      ),
    );
    await load;

    expect(reports.incomeExpenseReport, isNull);
    expect(reports.isIncomeExpenseReportLoading, isFalse);
    reports.dispose();
  });
}
