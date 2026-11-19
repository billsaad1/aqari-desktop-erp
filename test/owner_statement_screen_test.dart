import 'dart:async';

import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/owner_statement_screen.dart';
import 'package:app/models/account_statement_report_model.dart';
import 'package:app/providers/reports_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Map<String, dynamic> _ownerRow({bool reportable = true}) => {
  'id': 702,
  'name': 'مالك التقرير',
  'account_id': 210701,
  'account_code': '210701',
  'account_name': 'حساب المالك الجاري',
  'is_reportable': reportable ? 1 : 0,
};

AccountStatementReport _report({
  required int accountId,
  required String startDate,
  required String endDate,
}) => AccountStatementReport(
  accountId: accountId,
  accountCode: '210701',
  accountName: 'حساب المالك الجاري',
  accountType: 'Liability',
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

  testWidgets('viewer can read owner liability statement but cannot print', (
    tester,
  ) async {
    final reports = ReportsProvider(
      ownerStatementAccountsLoader: () async => [_ownerRow()],
      ownerStatementLoader: (ownerId, accountId, start, end) async =>
          _report(accountId: accountId, startDate: start, endDate: end),
    );
    reports.syncAuthorization(userId: 91, canViewReports: true);

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(home: Scaffold(body: OwnerStatementScreen())),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مالك التقرير').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('عرض الكشف'));
    await tester.pumpAndSettle();

    expect(find.text('كشف حساب المالك'), findsOneWidget);
    expect(find.text('مالك التقرير'), findsNWidgets(2));
    expect(find.text('145.25 ريال سعودي'), findsNWidgets(2));
    expect(
      find.textContaining('الرصيد الدائن موجب ويعبر عن مبلغ مستحق للمالك'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'طباعة'))
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
      permissionRows: const [],
    );
    await tester.pump();
    reports.syncAuthorization(userId: 91, canViewReports: false);
    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(reports.ownerStatementAccounts, isEmpty);
    expect(reports.ownerStatementReport, isNull);

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
    await tester.pump();
    reports.syncAuthorization(userId: 91, canViewReports: true);
    await tester.pumpAndSettle();
    expect(reports.ownerStatementAccountsLoaded, isTrue);
    expect(reports.ownerStatementAccounts, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  test(
    'does not load a statement for a non-reportable owner account',
    () async {
      var reportLoaderCalled = false;
      final reports = ReportsProvider(
        ownerStatementAccountsLoader: () async => [
          _ownerRow(reportable: false),
        ],
        ownerStatementLoader: (ownerId, accountId, start, end) async {
          reportLoaderCalled = true;
          return _report(accountId: accountId, startDate: start, endDate: end);
        },
      );
      await reports.loadOwnerStatementAccounts();
      await reports.loadOwnerStatement(702, '2026-01-01', '2026-01-31');

      expect(reportLoaderCalled, isFalse);
      expect(reports.ownerStatementReport, isNull);
      expect(
        reports.ownerStatementErrorMessage,
        contains('حساب التزامات تفصيلي صالح'),
      );
      reports.dispose();
    },
  );

  test('reloading owners discards a stale pending statement result', () async {
    final pendingOwners = Completer<List<Map<String, dynamic>>>();
    final pendingReport = Completer<AccountStatementReport>();
    var ownerLoads = 0;
    final reports = ReportsProvider(
      ownerStatementAccountsLoader: () {
        ownerLoads++;
        return ownerLoads == 1
            ? Future.value([_ownerRow()])
            : pendingOwners.future;
      },
      ownerStatementLoader: (ownerId, accountId, start, end) =>
          pendingReport.future,
    );
    await reports.loadOwnerStatementAccounts();
    final reportRequest = reports.loadOwnerStatement(
      702,
      '2026-01-01',
      '2026-01-31',
    );
    expect(reports.isOwnerStatementLoading, isTrue);

    final ownersRequest = reports.loadOwnerStatementAccounts();
    expect(reports.isOwnerStatementLoading, isFalse);
    pendingReport.complete(
      _report(
        accountId: 210701,
        startDate: '2026-01-01',
        endDate: '2026-01-31',
      ),
    );
    await reportRequest;
    pendingOwners.complete([_ownerRow()]);
    await ownersRequest;

    expect(reports.ownerStatementReport, isNull);
    expect(reports.isOwnerStatementLoading, isFalse);
    reports.dispose();
  });
}
