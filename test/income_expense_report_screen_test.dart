import 'dart:async';
import 'dart:typed_data';

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

  testWidgets(
    'filters ledger activity by cost center and keeps unassigned rows visible',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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
      var loaderCalls = 0;
      final reports = ReportsProvider(
        incomeExpenseReportLoader: (startDate, endDate) async {
          loaderCalls++;
          return IncomeExpenseReport(
            startDate: startDate,
            endDate: endDate,
            currency: 'SAR',
            costCenters: const [
              IncomeExpenseCostCenter(id: 10, code: 'CC-A', name: 'مركز أ'),
              IncomeExpenseCostCenter(id: 20, code: 'CC-B', name: 'مركز ب'),
            ],
            rows: const [
              IncomeExpenseAccountRow(
                accountId: 1,
                accountCode: '4101',
                accountName: 'إيراد إيجار',
                accountType: 'Revenue',
                debitMinor: 500,
                creditMinor: 8000,
                costCenterId: 10,
                costCenterCode: 'CC-A',
                costCenterName: 'مركز أ',
              ),
              IncomeExpenseAccountRow(
                accountId: 2,
                accountCode: '5101',
                accountName: 'مصروف صيانة',
                accountType: 'Expense',
                debitMinor: 2500,
                creditMinor: 500,
                costCenterId: 20,
                costCenterCode: 'CC-B',
                costCenterName: 'مركز ب',
              ),
              IncomeExpenseAccountRow(
                accountId: 3,
                accountCode: '4102',
                accountName: 'إيراد غير مخصص',
                accountType: 'Revenue',
                debitMinor: 0,
                creditMinor: 1000,
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

      expect(loaderCalls, 1);
      expect(find.text('إيراد إيجار'), findsOneWidget);
      expect(find.text('مصروف صيانة'), findsOneWidget);
      expect(find.text('إيراد غير مخصص'), findsOneWidget);
      expect(find.text('صافي الإيرادات'), findsOneWidget);
      expect(find.text('صافي المصروفات'), findsOneWidget);
      expect(find.text('صافي نتيجة الفترة'), findsNWidgets(2));
      expect(reports.incomeExpenseReport?.revenueNetMinor, 8500);
      expect(reports.incomeExpenseReport?.expenseNetMinor, 2000);
      expect(reports.incomeExpenseReport?.netResultMinor, 6500);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'معاينة التقرير'),
            )
            .onPressed,
        isNotNull,
      );

      await tester.tap(
        find.byKey(const ValueKey('incomeExpenseCostCenterFilter')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('CC-A - مركز أ').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .state<FormFieldState<String>>(
              find.byKey(const ValueKey('incomeExpenseCostCenterFilter')),
            )
            .value,
        'center:10',
      );
      expect(find.text('إيراد إيجار'), findsOneWidget);
      expect(find.text('مصروف صيانة'), findsNothing);
      expect(find.text('إيراد غير مخصص'), findsNothing);
      expect(loaderCalls, 1, reason: 'client-side filtering must not re-query');
      expect(reports.incomeExpenseReport?.netResultMinor, 6500);

      await tester.tap(
        find.byKey(const ValueKey('incomeExpenseCostCenterFilter')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('غير مخصص').last);
      await tester.pumpAndSettle();
      expect(find.text('إيراد غير مخصص'), findsOneWidget);
      expect(find.text('إيراد إيجار'), findsNothing);
      expect(find.text('مصروف صيانة'), findsNothing);

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
    },
  );

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

  testWidgets(
    'discards a PDF preview when the same period is refreshed during generation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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

      final firstResult = Completer<IncomeExpenseReport>();
      final refreshedResult = Completer<IncomeExpenseReport>();
      final pdfStarted = Completer<void>();
      final pdfBytes = Completer<Uint8List>();
      var loaderCalls = 0;
      late String startDate;
      late String endDate;

      IncomeExpenseReport reportFor(int creditMinor) => IncomeExpenseReport(
        startDate: startDate,
        endDate: endDate,
        currency: 'SAR',
        rows: [
          IncomeExpenseAccountRow(
            accountId: 1,
            accountCode: '4101',
            accountName: 'إيراد إيجار',
            accountType: 'Revenue',
            debitMinor: 0,
            creditMinor: creditMinor,
          ),
        ],
      );

      final reports = ReportsProvider(
        incomeExpenseReportLoader: (start, end) {
          loaderCalls++;
          startDate = start;
          endDate = end;
          return loaderCalls == 1 ? firstResult.future : refreshedResult.future;
        },
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<ReportsProvider>.value(
          value: reports,
          child: MaterialApp(
            home: Scaffold(
              body: IncomeExpenseReportScreen(
                companyInfoLoader: () async => null,
                pdfBuilder: (report, companyInfo, currency) {
                  if (!pdfStarted.isCompleted) pdfStarted.complete();
                  return pdfBytes.future;
                },
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('عرض التقرير'));
      await tester.pump();
      firstResult.complete(reportFor(8000));
      await tester.pumpAndSettle();
      expect(reports.incomeExpenseReport?.rows.single.creditMinor, 8000);

      await tester.tap(find.text('معاينة التقرير'));
      await tester.pump();
      expect(pdfStarted.isCompleted, isTrue);

      await tester.tap(find.text('عرض التقرير'));
      await tester.pump();
      expect(loaderCalls, 2);
      expect(reports.incomeExpenseReport, isNull);
      refreshedResult.complete(reportFor(9000));
      await tester.pumpAndSettle();
      expect(reports.incomeExpenseReport?.rows.single.creditMinor, 9000);

      pdfBytes.complete(Uint8List.fromList([1, 2, 3]));
      await tester.pumpAndSettle();
      expect(find.text('معاينة المستند'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      reports.dispose();
    },
  );
}
