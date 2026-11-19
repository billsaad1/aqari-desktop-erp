import 'dart:async';

import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/tenant_aging_report_screen.dart';
import 'package:app/models/tenant_aging_report_model.dart';
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

  TenantAgingReport report(String date) => TenantAgingReport(
    asOfDate: date,
    currency: 'SAR',
    rows: const [
      TenantAgingReportRow(
        installmentId: 71,
        contractId: 9,
        tenantId: 22,
        tenantName: 'مستأجر التقرير',
        propertyName: 'عقار تجريبي',
        unitNumber: '12-A',
        dueDate: '2026-05-31',
        daysOverdue: 30,
        bucket: TenantAgingBucket.days0To30,
        obligationMinor: 10000,
        paidMinor: 2500,
        balanceMinor: 7500,
      ),
      TenantAgingReportRow(
        installmentId: 72,
        contractId: 9,
        tenantId: 22,
        tenantName: 'مستأجر التقرير',
        propertyName: 'عقار تجريبي',
        unitNumber: '12-A',
        dueDate: '2026-07-01',
        daysOverdue: 0,
        bucket: TenantAgingBucket.notDue,
        obligationMinor: 5000,
        paidMinor: 0,
        balanceMinor: 5000,
      ),
    ],
    exceptions: const [
      TenantAgingReviewException(
        documentId: 801,
        documentDate: '2026-06-01',
        documentType: 'قبض',
        tenantName: 'مستأجر التقرير',
        amountMinor: 3000,
        reason: 'قبض مرحّل بلا تخصيص تفصيلي موثق.',
      ),
    ],
  );

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
          home: Scaffold(body: TenantAgingReportScreen()),
        ),
      ),
    );

    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(find.text('أعمار ديون المستأجرين'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets('loads cutoff balances and clears report on view revocation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PermissionRuntime.activate(
      userId: 44,
      role: 'Accountant',
      permissionRows: [
        {
          'screen_name': 'reports',
          'can_view': 1,
          'can_print': 0,
          'can_add': 0,
          'can_edit': 0,
          'can_delete': 0,
          'can_post': 0,
        },
      ],
    );
    String? requestedDate;
    final reports = ReportsProvider(
      tenantAgingReportLoader: (asOfDate) async {
        requestedDate = asOfDate;
        return report(asOfDate);
      },
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: TenantAgingReportScreen()),
        ),
      ),
    );
    await tester.tap(find.text('عرض التقرير'));
    await tester.pumpAndSettle();

    expect(requestedDate, isNotNull);
    expect(reports.tenantAgingReport?.asOfDate, requestedDate);
    expect(find.text('مستأجر التقرير'), findsNWidgets(3));
    expect(find.text('0–30 يومًا'), findsNWidgets(2));
    expect(
      find.text('غير مستحق'),
      findsNWidgets(2),
      reason: 'shown in the summary metric and in the table heading',
    );
    expect(
      find.text('استثناءات للمراجعة — لا تُخصم من الرصيد المؤكد'),
      findsOneWidget,
    );
    expect(find.text('قبض مرحّل بلا تخصيص تفصيلي موثق.'), findsOneWidget);
    expect(reports.tenantAgingReport?.totalOutstandingMinor, 12500);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'معاينة PDF'),
          )
          .onPressed,
      isNotNull,
      reason:
          'reports.view allows preview even when output permission is absent',
    );

    PermissionRuntime.activate(
      userId: 44,
      role: 'DataEntry',
      permissionRows: const [],
    );
    await tester.pump();
    expect(reports.tenantAgingReport, isNull);
    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(find.text('عقار تجريبي'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  test('ignores a stale aging query result after report clear', () async {
    final completer = Completer<TenantAgingReport>();
    final reports = ReportsProvider(
      tenantAgingReportLoader: (_) => completer.future,
    );
    final load = reports.loadTenantAgingReport('2026-06-30');
    reports.clearTenantAgingReport();
    completer.complete(report('2026-06-30'));
    await load;

    expect(reports.tenantAgingReport, isNull);
    expect(reports.isTenantAgingReportLoading, isFalse);
    reports.dispose();
  });
}
