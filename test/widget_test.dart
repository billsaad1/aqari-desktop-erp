import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app/core/app_theme.dart';
import 'package:app/core/erp_data_table.dart';
import 'package:app/main.dart';
import 'package:app/providers/auth_provider.dart';
import 'package:app/providers/navigation_provider.dart';

void main() {
  testWidgets('Initial app test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => NavigationProvider()),
        ],
        child: const ERPApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Verify that the redesigned login screen is visible.
    expect(find.text('مرحبًا بعودتك'), findsOneWidget);
    expect(find.text('دخول إلى النظام'), findsOneWidget);
  });

  testWidgets('Material 3 Cairo theme and interactive desktop table states', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: ErpDataTable(
            columns: [DataColumn(label: Text('السجل'))],
            rows: [
              DataRow(cells: [DataCell(Text('عنصر تفاعلي'), onTap: _noop)]),
              DataRow(cells: [DataCell(Text('عنصر للعرض'))]),
            ],
          ),
        ),
      ),
    );

    final theme = Theme.of(tester.element(find.byType(ErpDataTable)));
    final renderedTable = tester.widget<DataTable>(find.byType(DataTable));
    expect(theme.useMaterial3, isTrue);
    expect(theme.textTheme.bodyMedium?.fontFamily, 'Cairo');
    expect(renderedTable.rows.first.onHover, isNotNull);
    expect(
      renderedTable.rows.first.mouseCursor?.resolve(const {}),
      SystemMouseCursors.click,
    );
    expect(
      renderedTable.rows.last.mouseCursor?.resolve(const {}),
      SystemMouseCursors.basic,
    );
  });
}

void _noop() {}
