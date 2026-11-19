import 'dart:async';

import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/tenant_statement_screen.dart';
import 'package:app/models/account_statement_report_model.dart';
import 'package:app/providers/reports_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Map<String, dynamic> _tenantRow({bool reportable = true}) => {
  'id': 901,
  'name': 'مستأجر التقرير',
  'account_id': 501,
  'account_code': '120901',
  'account_name': 'ذمم مستأجر التقرير',
  'is_reportable': reportable ? 1 : 0,
};

AccountStatementReport _report({
  required int accountId,
  required String startDate,
  required String endDate,
}) => AccountStatementReport(
  accountId: accountId,
  accountCode: '120901',
  accountName: 'ذمم مستأجر التقرير',
  accountType: 'Asset',
  currency: 'SAR',
  startDate: startDate,
  endDate: endDate,
  openingBalance: 145.25,
  totalDebit: 0,
  totalCredit: 0,
  closingBalance: 145.25,
  lines: const [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PermissionRuntime.activate(
      userId: 91,
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
  });

  tearDown(() {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  testWidgets(
    'viewer can read an opening-only tenant statement but cannot print or save it',
    (tester) async {
      final reports = ReportsProvider(
        tenantStatementAccountsLoader: () async => [_tenantRow()],
        tenantStatementLoader: (tenantId, accountId, start, end) async =>
            _report(accountId: accountId, startDate: start, endDate: end),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<ReportsProvider>.value(
          value: reports,
          child: const MaterialApp(
            home: Scaffold(body: TenantStatementScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('مستأجر التقرير').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('عرض الكشف'));
      await tester.pumpAndSettle();

      expect(find.text('كشف حساب المستأجر'), findsOneWidget);
      expect(find.text('145.25 ريال سعودي'), findsNWidgets(2));
      expect(
        find.text(
          'لا توجد حركات مرحلة في الفترة المحددة؛ الرصيد الافتتاحي والختامي معروضان أعلاه.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'طباعة'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'حفظ PDF'),
            )
            .onPressed,
        isNull,
      );

      PermissionRuntime.activate(
        userId: 91,
        role: 'DataEntry',
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
      await tester.pump();
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'طباعة'),
            )
            .onPressed,
        isNotNull,
      );

      PermissionRuntime.activate(
        userId: 91,
        role: 'DataEntry',
        permissionRows: [
          {
            'screen_name': 'reports',
            'can_view': 0,
            'can_add': 0,
            'can_edit': 0,
            'can_delete': 0,
            'can_print': 0,
            'can_post': 0,
          },
        ],
      );
      await tester.pump();
      expect(
        find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
        findsOneWidget,
      );
      expect(reports.tenantStatementAccounts, isEmpty);
      expect(reports.tenantStatementReport, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      reports.dispose();
    },
  );

  test('clearing tenant report discards an in-flight stale result', () async {
    final pending = Completer<AccountStatementReport>();
    final reports = ReportsProvider(
      tenantStatementAccountsLoader: () async => [_tenantRow()],
      tenantStatementLoader: (tenantId, accountId, start, end) =>
          pending.future,
    );
    await reports.loadTenantStatementAccounts();

    final request = reports.loadTenantStatement(
      901,
      '2026-01-01',
      '2026-01-31',
    );
    reports.clearTenantStatementReport(notify: false);
    pending.complete(
      _report(accountId: 501, startDate: '2026-01-01', endDate: '2026-01-31'),
    );
    await request;

    expect(reports.tenantStatementReport, isNull);
    expect(reports.isTenantStatementLoading, isFalse);
    reports.dispose();
  });

  test(
    'reloading tenant accounts clears the loading state of an old report',
    () async {
      final pendingAccounts = Completer<List<Map<String, dynamic>>>();
      final pendingReport = Completer<AccountStatementReport>();
      var accountsLoadCount = 0;
      final reports = ReportsProvider(
        tenantStatementAccountsLoader: () {
          accountsLoadCount++;
          return accountsLoadCount == 1
              ? Future.value([_tenantRow()])
              : pendingAccounts.future;
        },
        tenantStatementLoader: (tenantId, accountId, start, end) =>
            pendingReport.future,
      );
      await reports.loadTenantStatementAccounts();

      final reportRequest = reports.loadTenantStatement(
        901,
        '2026-01-01',
        '2026-01-31',
      );
      expect(reports.isTenantStatementLoading, isTrue);

      final accountsRequest = reports.loadTenantStatementAccounts();
      expect(reports.isTenantStatementLoading, isFalse);
      pendingReport.complete(
        _report(accountId: 501, startDate: '2026-01-01', endDate: '2026-01-31'),
      );
      await reportRequest;
      pendingAccounts.complete([_tenantRow()]);
      await accountsRequest;

      expect(reports.tenantStatementReport, isNull);
      expect(reports.isTenantStatementLoading, isFalse);
      reports.dispose();
    },
  );

  test(
    'does not load a statement for a tenant without a valid detail account',
    () async {
      var reportLoaderCalled = false;
      final reports = ReportsProvider(
        tenantStatementAccountsLoader: () async => [
          _tenantRow(reportable: false),
        ],
        tenantStatementLoader: (tenantId, accountId, start, end) async {
          reportLoaderCalled = true;
          return _report(accountId: accountId, startDate: start, endDate: end);
        },
      );
      await reports.loadTenantStatementAccounts();
      await reports.loadTenantStatement(901, '2026-01-01', '2026-01-31');

      expect(reportLoaderCalled, isFalse);
      expect(reports.tenantStatementReport, isNull);
      expect(reports.tenantStatementErrorMessage, contains('حساب ذمم تفصيلي'));
      reports.dispose();
    },
  );
}
