import 'dart:async';

import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/tenant_collection_report_screen.dart';
import 'package:app/models/tenant_collection_report_model.dart';
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

  TenantCollectionReport report(String start, String end) =>
      TenantCollectionReport(
        startDate: start,
        endDate: end,
        currency: 'SAR',
        rows: const [
          TenantCollectionReportRow(
            voucherId: 11,
            voucherDate: '2026-01-10',
            tenantId: 21,
            tenantName: 'مستأجر تجريبي',
            isRefund: false,
            isVerifiedRefund: false,
            amountMinor: 10000,
            allocationStatus: 'التخصيص مطابق',
            sourceConsistencyStatus: 'سجلات التخصيص متطابقة',
            sourceReceiptVoucherIds: '',
            linkedAllocationMinor: 10000,
          ),
          TenantCollectionReportRow(
            voucherId: 12,
            voucherDate: '2026-01-11',
            tenantId: 21,
            tenantName: 'مستأجر تجريبي',
            isRefund: false,
            isVerifiedRefund: false,
            amountMinor: 5000,
            allocationStatus: 'لا يوجد تخصيص مثبت',
            sourceConsistencyStatus: 'لا توجد تخصيصات للمقارنة',
            sourceReceiptVoucherIds: '',
            linkedAllocationMinor: 0,
          ),
          TenantCollectionReportRow(
            voucherId: 13,
            voucherDate: '2026-01-12',
            tenantId: 21,
            tenantName: 'مستأجر تجريبي',
            isRefund: true,
            isVerifiedRefund: true,
            amountMinor: -2500,
            allocationStatus: 'مرتبط ومطابق',
            sourceConsistencyStatus: 'المصدر متسق وتحت السقف',
            sourceReceiptVoucherIds: '11',
            linkedAllocationMinor: 2500,
          ),
          TenantCollectionReportRow(
            voucherId: 14,
            voucherDate: '2026-01-13',
            tenantId: 21,
            tenantName: 'مستأجر تجريبي',
            isRefund: true,
            isVerifiedRefund: false,
            amountMinor: -1000,
            allocationStatus: 'مجموع تخصيصات الاسترداد لا يطابق السند',
            sourceConsistencyStatus: 'مجموع تخصيصات الاسترداد لا يطابق السند',
            sourceMismatchCount: 1,
            sourceReceiptVoucherIds: '11',
            linkedAllocationMinor: 500,
          ),
        ],
      );

  testWidgets('denies report access without reports.view', (tester) async {
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
          home: Scaffold(body: TenantCollectionReportScreen()),
        ),
      ),
    );

    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(find.text('تحصيل المستأجرين'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets(
    'shows receipt, verified refund, and unverified refund separately',
    (tester) async {
      PermissionRuntime.activate(
        userId: 44,
        role: 'Accountant',
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
        tenantCollectionReportLoader: (start, end) async {
          loaderCalled = true;
          return report(start, end);
        },
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<ReportsProvider>.value(
          value: reports,
          child: const MaterialApp(
            home: Scaffold(body: TenantCollectionReportScreen()),
          ),
        ),
      );
      await tester.tap(find.text('عرض التقرير'));
      await tester.pumpAndSettle();

      expect(loaderCalled, isTrue);
      expect(find.text('مستأجر تجريبي'), findsNWidgets(4));
      expect(find.text('قبض'), findsNWidgets(2));
      expect(find.text('استرداد مرتبط'), findsOneWidget);
      expect(find.text('استرداد للمراجعة'), findsOneWidget);
      expect(find.text('لا يوجد تخصيص مثبت'), findsOneWidget);
      expect(find.text('مرتبط ومطابق'), findsOneWidget);
      expect(
        find.text('مجموع تخصيصات الاسترداد لا يطابق السند'),
        findsNWidgets(2),
      );
      expect(find.text('اتساق مرجع التخصيص'), findsOneWidget);
      expect(find.text('سندات تخصيصها يحتاج مراجعة'), findsOneWidget);
      expect(reports.tenantCollectionReport?.grossReceiptsMinor, 15000);
      expect(reports.tenantCollectionReport?.linkedRefundsMinor, 2500);
      expect(reports.tenantCollectionReport?.unverifiedRefundsMinor, 1000);
      expect(reports.tenantCollectionReport?.netCollectedMinor, 12500);
      expect(reports.tenantCollectionReport?.unallocatedReceiptsMinor, 5000);
      expect(reports.tenantCollectionReport?.sourceMismatchVoucherCount, 1);
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
      expect(reports.tenantCollectionReport, isNull);
      expect(
        find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      reports.dispose();
    },
  );

  testWidgets('passes the selected tenant to the filtered report loader', (
    tester,
  ) async {
    PermissionRuntime.activate(
      userId: 44,
      role: 'Accountant',
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
    int? requestedTenantId;
    final reports = ReportsProvider(
      tenantCollectionReportTenantsLoader: () async => [
        {'id': 21, 'name': 'مستأجر تجريبي'},
      ],
      tenantCollectionReportFilteredLoader: (start, end, tenantId) async {
        requestedTenantId = tenantId;
        final unfiltered = report(start, end);
        return TenantCollectionReport(
          startDate: start,
          endDate: end,
          currency: unfiltered.currency,
          tenantId: tenantId,
          tenantName: 'مستأجر تجريبي',
          rows: unfiltered.rows
              .where((row) => row.tenantId == tenantId)
              .toList(growable: false),
        );
      },
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: TenantCollectionReportScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مستأجر تجريبي').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('عرض التقرير'));
    await tester.pumpAndSettle();

    expect(requestedTenantId, 21);
    expect(reports.tenantCollectionReport?.tenantId, 21);
    expect(
      reports.tenantCollectionReport?.rows.every((row) => row.tenantId == 21),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  test('ignores stale report results after clear', () async {
    final completer = Completer<TenantCollectionReport>();
    final reports = ReportsProvider(
      tenantCollectionReportLoader: (_, _) => completer.future,
    );
    final load = reports.loadTenantCollectionReport('2026-01-01', '2026-01-31');
    reports.clearTenantCollectionReport();
    completer.complete(report('2026-01-01', '2026-01-31'));
    await load;

    expect(reports.tenantCollectionReport, isNull);
    expect(reports.isTenantCollectionReportLoading, isFalse);
    reports.dispose();
  });
}
