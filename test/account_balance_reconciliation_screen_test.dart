import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/account_balance_reconciliation_screen.dart';
import 'package:app/models/account_balance_reconciliation_report_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AccountBalanceReconciliationReport _report() =>
    AccountBalanceReconciliationReport(
      rows: const [
        AccountBalanceReconciliationRow(
          accountId: 1,
          code: '1101',
          name: 'الصندوق الرئيسي',
          accountType: 'Asset',
          storedBalanceMinor: 10000,
          ledgerBalanceMinor: 8000,
          isSupportedAccountType: true,
        ),
        AccountBalanceReconciliationRow(
          accountId: 2,
          code: '4101',
          name: 'إيراد مطابق',
          accountType: 'Revenue',
          storedBalanceMinor: 8000,
          ledgerBalanceMinor: 8000,
          isSupportedAccountType: true,
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

  testWidgets('requires reports.view', (tester) async {
    PermissionRuntime.activate(
      userId: 4,
      role: 'DataEntry',
      permissionRows: const [],
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AccountBalanceReconciliationScreen()),
      ),
    );

    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(find.text('مطابقة أرصدة الحسابات الداخلية'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shows discrepancies and clears results when access is revoked', (
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
    var loaderCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountBalanceReconciliationScreen(
            loader: () async {
              loaderCalls++;
              return _report();
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('فحص الأرصدة الآن'));
    await tester.pumpAndSettle();

    expect(loaderCalls, 1);
    expect(find.text('مطابقة أرصدة الحسابات الداخلية'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1'), findsNWidgets(2));
    expect(find.text('يحتاج مراجعة'), findsOneWidget);
    expect(find.text('1101'), findsOneWidget);
    expect(find.text('4101'), findsNothing);
    expect(find.text('20.00'), findsOneWidget);
    expect(
      find.textContaining('لا يعدّل الأرصدة ولا يطابق كشوف البنك'),
      findsOneWidget,
    );

    await tester.tap(find.text('إظهار الحسابات المطابقة'));
    await tester.pumpAndSettle();
    expect(find.text('4101'), findsOneWidget);
    expect(find.text('مطابق'), findsOneWidget);

    PermissionRuntime.activate(
      userId: 44,
      role: 'DataEntry',
      permissionRows: const [],
    );
    await tester.pump();
    expect(find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'), findsOneWidget);
    expect(find.text('1101'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
