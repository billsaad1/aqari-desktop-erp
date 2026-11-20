import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/internal_subledger_reconciliation_screen.dart';
import 'package:app/models/internal_subledger_reconciliation_report_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  tearDown(PermissionRuntime.clear);

  testWidgets('loads and displays internal reconciliation and allocation state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InternalSubledgerReconciliationScreen(
            reportLoader: (start, end) async =>
                InternalSubledgerReconciliationReport(
                  startDate: start,
                  endDate: end,
                  currency: 'SAR',
                  rows: const [
                    InternalSubledgerReconciliationRow(
                      source: InternalSubledgerSource.tenantReceipt,
                      sourceId: 42,
                      sourceDate: '2026-01-02',
                      partyName: 'مستأجر الواجهة',
                      amountMinor: 5000,
                      state: InternalSubledgerRowState.matched,
                      issueSummary: '',
                      journalEntryId: 72,
                      journalDate: '2026-01-02',
                      journalPosted: true,
                      journalDebitMinor: 5000,
                      journalCreditMinor: 5000,
                      controlCreditMinor: 5000,
                      allocatedMinor: 0,
                      allocationStatus: 'غير مخصص',
                    ),
                    InternalSubledgerReconciliationRow(
                      source: InternalSubledgerSource.directJournal,
                      sourceId: 43,
                      sourceDate: '2026-01-03',
                      partyName: 'قيد بلا مستند فرعي',
                      amountMinor: 3000,
                      state: InternalSubledgerRowState.needsReview,
                      issueSummary: 'قيد يمس حساب ذمم بلا رابط',
                      journalEntryId: 73,
                      journalDate: '2026-01-03',
                      journalPosted: true,
                    ),
                  ],
                ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('فحص الفترة'));
    await tester.pumpAndSettle();

    expect(find.text('مطابقة السجلات الفرعية مع دفتر الأستاذ'), findsOneWidget);
    expect(find.text('قبض مستأجر'), findsOneWidget);
    expect(find.text('غير مخصص'), findsOneWidget);
    expect(find.text('مطابق مع الأستاذ'), findsWidgets);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('غير مخصص / بلا مصدر').last);
    await tester.pumpAndSettle();

    expect(find.text('42'), findsOneWidget);
    expect(find.text('43'), findsNothing);
  });
}
