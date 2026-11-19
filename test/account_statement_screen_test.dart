import 'dart:async';

import 'package:app/core/permission_policy.dart';
import 'package:app/features/reports_inquiry/account_statement_screen.dart';
import 'package:app/models/account_statement_report_model.dart';
import 'package:app/providers/accounting_provider.dart';
import 'package:app/providers/reports_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _ReadOnlyAccountingProvider extends AccountingProvider {
  @override
  List<Map<String, dynamic>> get detailAccounts => const [
    {
      'id': 501,
      'code': '1104',
      'name': 'حساب تجريبي',
      'account_type': 'Asset',
      'parent_id': 11,
    },
  ];

  @override
  bool get isLoading => false;

  @override
  Future<void> loadAccounts() async {}
}

class _LoadingAccountingProvider extends _ReadOnlyAccountingProvider {
  final _pendingLoad = Completer<void>();

  @override
  bool get isLoading => true;

  @override
  Future<void> loadAccounts() => _pendingLoad.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PermissionRuntime.activate(
      userId: 45,
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

  testWidgets('shows opening-only statement to a viewer without print access', (
    tester,
  ) async {
    final reports = ReportsProvider(
      accountStatementLoader: (accountId, startDate, endDate) async =>
          AccountStatementReport(
            accountId: accountId,
            accountCode: '1104',
            accountName: 'حساب تجريبي',
            accountType: 'Asset',
            currency: 'SAR',
            startDate: startDate,
            endDate: endDate,
            openingBalance: 145.25,
            totalDebit: 0,
            totalCredit: 0,
            closingBalance: 145.25,
            lines: const [],
          ),
    );
    final accounting = _ReadOnlyAccountingProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportsProvider>.value(value: reports),
          ChangeNotifierProvider<AccountingProvider>.value(value: accounting),
        ],
        child: const MaterialApp(
          home: Scaffold(body: AccountStatementScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1104 - حساب تجريبي').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('عرض الكشف'));
    await tester.pumpAndSettle();

    expect(find.text('145.25'), findsNWidgets(4));
    expect(find.text('العملة: ريال سعودي'), findsOneWidget);
    expect(
      find.text(
        'لا توجد حركات مرحلة في الفترة؛ الرصيد الافتتاحي والختامي ما زالا معروضين.',
      ),
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
      userId: 45,
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
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'طباعة'))
          .onPressed,
      isNotNull,
    );

    PermissionRuntime.activate(
      userId: 45,
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
    expect(
      tester
          .widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'طباعة'))
          .onPressed,
      isNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
    accounting.dispose();
  });

  testWidgets('shows an explicit loading state while accounts are loading', (
    tester,
  ) async {
    final reports = ReportsProvider();
    final accounting = _LoadingAccountingProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportsProvider>.value(value: reports),
          ChangeNotifierProvider<AccountingProvider>.value(value: accounting),
        ],
        child: const MaterialApp(
          home: Scaffold(body: AccountStatementScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('جارٍ تحميل الحسابات التفصيلية...'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    reports.dispose();
    accounting.dispose();
  });
}
