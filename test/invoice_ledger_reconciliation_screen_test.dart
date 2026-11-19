import 'dart:async';

import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/invoice_ledger_reconciliation_screen.dart';
import 'package:app/models/invoice_ledger_reconciliation_report_model.dart';
import 'package:app/providers/reports_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

InvoiceLedgerReconciliationRow _matchedRow() =>
    InvoiceLedgerReconciliationRow.fromMap({
      'invoice_id': 301,
      'invoice_date': '2026-03-01',
      'tenant_name': 'مستأجر مطابق',
      'tenant_account_id': 51,
      'net_minor': 10000,
      'tax_minor': 1500,
      'total_minor': 11500,
      'tax_account_id': 2103,
      'installment_amount_minor': 10000,
      'journal_entry_id': 9001,
      'journal_entry_exists': 1,
      'journal_is_posted': 1,
      'linked_invoice_count': 1,
      'journal_debit_minor': 11500,
      'journal_credit_minor': 11500,
      'tenant_receivable_debit_minor': 11500,
      'revenue_credit_minor': 10000,
      'tax_liability_credit_minor': 1500,
    });

InvoiceLedgerReconciliationRow _missingLinkRow() =>
    InvoiceLedgerReconciliationRow.fromMap({
      'invoice_id': 302,
      'invoice_date': '2026-03-02',
      'tenant_name': 'مستأجر للمراجعة',
      'tenant_account_id': 52,
      'net_minor': 5000,
      'tax_minor': 0,
      'total_minor': 5000,
      'journal_entry_id': null,
      'journal_entry_exists': 0,
      'journal_is_posted': 0,
      'linked_invoice_count': 0,
      'journal_debit_minor': 0,
      'journal_credit_minor': 0,
      'tenant_receivable_debit_minor': 0,
      'revenue_credit_minor': 0,
      'tax_liability_credit_minor': 0,
    });

InvoiceLedgerReconciliationReport _report(String startDate, String endDate) =>
    InvoiceLedgerReconciliationReport(
      startDate: startDate,
      endDate: endDate,
      currency: 'SAR',
      rows: [_matchedRow(), _missingLinkRow()],
    );

void main() {
  tearDown(() {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  testWidgets('denies the screen without reports.view', (tester) async {
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
          home: Scaffold(body: InvoiceLedgerReconciliationScreen()),
        ),
      ),
    );

    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(find.text('مطابقة الفواتير مع دفتر الأستاذ'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets('shows reconciliation results and filters matched rows', (
    tester,
  ) async {
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
      invoiceLedgerReconciliationLoader: (startDate, endDate) async {
        loaderCalls++;
        return _report(startDate, endDate);
      },
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: InvoiceLedgerReconciliationScreen()),
        ),
      ),
    );
    await tester.tap(find.text('عرض المطابقة'));
    await tester.pumpAndSettle();

    expect(loaderCalls, 1);
    expect(find.text('301'), findsOneWidget);
    expect(find.text('302'), findsOneWidget);
    expect(find.text('مستأجر مطابق'), findsOneWidget);
    expect(find.text('مستأجر للمراجعة'), findsOneWidget);
    expect(find.text('الفواتير المعروضة'), findsOneWidget);
    expect(find.text('الفاتورة بلا رابط قيد'), findsOneWidget);
    expect(reports.invoiceLedgerReconciliationReport?.reconciledCount, 1);
    expect(reports.invoiceLedgerReconciliationReport?.reviewCount, 1);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'معاينة التقرير'),
          )
          .onPressed,
      isNotNull,
      reason: 'reports.view allows preview even when printing is denied',
    );

    await tester.tap(
      find.byKey(const ValueKey('invoiceLedgerReconciliationFilter')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('مطابق فقط').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .state<FormFieldState<String>>(
            find.byKey(const ValueKey('invoiceLedgerReconciliationFilter')),
          )
          .value,
      'matched',
    );
    expect(find.text('301'), findsOneWidget);
    expect(find.text('302'), findsNothing);
    expect(loaderCalls, 1, reason: 'status filtering is local to the report');

    PermissionRuntime.activate(
      userId: 44,
      role: 'DataEntry',
      permissionRows: const [],
    );
    await tester.pump();
    expect(reports.invoiceLedgerReconciliationReport, isNull);
    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  test('ignores a stale report request after clear', () async {
    final completer = Completer<InvoiceLedgerReconciliationReport>();
    final reports = ReportsProvider(
      invoiceLedgerReconciliationLoader: (_, _) => completer.future,
    );

    final load = reports.loadInvoiceLedgerReconciliationReport(
      '2026-03-01',
      '2026-03-31',
    );
    reports.clearInvoiceLedgerReconciliationReport();
    completer.complete(_report('2026-03-01', '2026-03-31'));
    await load;

    expect(reports.invoiceLedgerReconciliationReport, isNull);
    expect(reports.isInvoiceLedgerReconciliationLoading, isFalse);
    reports.dispose();
  });
}
