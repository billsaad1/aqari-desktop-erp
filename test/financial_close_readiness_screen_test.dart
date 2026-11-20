import 'dart:async';

import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/financial_close_readiness_screen.dart';
import 'package:app/models/financial_close_readiness_report_model.dart';
import 'package:app/providers/reports_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

FinancialCloseReadinessReport _report(String start, String end) =>
    FinancialCloseReadinessReport(
      startDate: start,
      endDate: end,
      currency: 'SAR',
      unpostedEntries: const [
        FinancialCloseEntryIssue(
          journalEntryId: 17,
          entryDate: '2026-06-30',
          description: 'مسودة تحتاج مراجعة',
          debitMinor: 12000,
          creditMinor: 10000,
          lineCount: 2,
          isPosted: false,
        ),
      ],
      unbalancedPostedEntries: const [
        FinancialCloseEntryIssue(
          journalEntryId: 19,
          entryDate: '2026-06-29',
          description: 'قيد مرحل غير متوازن',
          debitMinor: 9000,
          creditMinor: 8000,
          lineCount: 2,
          isPosted: true,
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

  testWidgets('denies report without reports.view', (tester) async {
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
          home: Scaffold(body: FinancialCloseReadinessScreen()),
        ),
      ),
    );

    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(find.text('مراجعة جاهزية الإقفال المالي'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  testWidgets('shows draft and imbalance findings then clears on revoke', (
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
      financialCloseReadinessLoader: (start, end) async {
        loaderCalled = true;
        return _report(start, end);
      },
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<ReportsProvider>.value(
        value: reports,
        child: const MaterialApp(
          home: Scaffold(body: FinancialCloseReadinessScreen()),
        ),
      ),
    );
    await tester.tap(find.text('فحص الفترة'));
    await tester.pumpAndSettle();

    expect(loaderCalled, isTrue);
    expect(find.text('قيد غير مرحّل'), findsOneWidget);
    expect(find.text('قيد مرحّل غير متوازن'), findsOneWidget);
    expect(
      find.text(
        'توجد قيود أو استثناءات مطابقة داخلية تحتاج معالجة يدوية قبل القفل.',
      ),
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
    expect(reports.financialCloseReadinessReport, isNull);
    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
  });

  test('ignores stale close-readiness response after clear', () async {
    final completer = Completer<FinancialCloseReadinessReport>();
    final reports = ReportsProvider(
      financialCloseReadinessLoader: (_, _) => completer.future,
    );

    final load = reports.loadFinancialCloseReadinessReport(
      '2026-06-01',
      '2026-06-30',
    );
    reports.clearFinancialCloseReadinessReport();
    completer.complete(_report('2026-06-01', '2026-06-30'));
    await load;

    expect(reports.financialCloseReadinessReport, isNull);
    expect(reports.isFinancialCloseReadinessLoading, isFalse);
    reports.dispose();
  });
}
