import 'dart:async';

import 'package:app/features/reports_inquiry/trial_balance_screen.dart';
import 'package:app/models/trial_balance_report_model.dart';
import 'package:app/providers/reports_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:app/core/permission_policy.dart';

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
        child: const MaterialApp(home: Scaffold(body: TrialBalanceScreen())),
      ),
    );

    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(find.text('ميزان المراجعة'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets(
    'loads posted-balance report and clears it when view is revoked',
    (tester) async {
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
        trialBalanceLoader: (startDate, endDate) async {
          loaderCalled = true;
          return TrialBalanceReport(
            startDate: startDate,
            endDate: endDate,
            currency: 'SAR',
            rows: const [
              TrialBalanceRow(
                accountId: 1,
                accountCode: '1101',
                accountName: 'الصندوق الرئيسي',
                accountType: 'Asset',
                openingDebitMinor: 10000,
                openingCreditMinor: 0,
                periodDebitMinor: 2000,
                periodCreditMinor: 0,
                closingDebitMinor: 12000,
                closingCreditMinor: 0,
              ),
              TrialBalanceRow(
                accountId: 2,
                accountCode: '4101',
                accountName: 'الإيراد',
                accountType: 'Revenue',
                openingDebitMinor: 0,
                openingCreditMinor: 10000,
                periodDebitMinor: 0,
                periodCreditMinor: 2000,
                closingDebitMinor: 0,
                closingCreditMinor: 12000,
              ),
            ],
          );
        },
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<ReportsProvider>.value(
          value: reports,
          child: const MaterialApp(home: Scaffold(body: TrialBalanceScreen())),
        ),
      );
      await tester.tap(find.text('عرض الميزان'));
      await tester.pumpAndSettle();

      expect(loaderCalled, isTrue);
      expect(find.text('الصندوق الرئيسي'), findsOneWidget);
      expect(
        find.text(
          'إجمالي المدين والدائن متساويان في الافتتاح والحركة والإقفال',
        ),
        findsOneWidget,
      );
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
      expect(reports.trialBalanceReport, isNull);
      expect(
        find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      reports.dispose();
    },
  );

  test('ignores a stale trial balance request after clearing', () async {
    final completer = Completer<TrialBalanceReport>();
    final reports = ReportsProvider(
      trialBalanceLoader: (_, _) => completer.future,
    );

    final load = reports.loadTrialBalance('2026-01-01', '2026-01-31');
    reports.clearTrialBalance();
    completer.complete(
      TrialBalanceReport(
        startDate: '2026-01-01',
        endDate: '2026-01-31',
        currency: 'SAR',
        rows: const [],
      ),
    );
    await load;

    expect(reports.trialBalanceReport, isNull);
    expect(reports.isTrialBalanceLoading, isFalse);
    reports.dispose();
  });
}
