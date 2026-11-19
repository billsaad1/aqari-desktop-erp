import 'dart:typed_data';

import 'package:app/core/pdf_preview_dialog.dart';
import 'package:app/core/permission_policy.dart';
import 'package:app/core/print_utils.dart';
import 'package:app/features/reports_inquiry/property_unit_inquiry_screen.dart';
import 'package:app/providers/reports_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  setUp(PermissionRuntime.clear);
  tearDown(PermissionRuntime.clear);

  test('authorization changes notify long-lived PDF previews', () {
    var notifications = 0;
    void listener() => notifications++;
    PermissionRuntime.authorizationRevision.addListener(listener);

    final viewAndPrint = [
      {
        'screen_name': 'reports',
        'can_view': 1,
        'can_print': 1,
        'can_add': 0,
        'can_edit': 0,
        'can_delete': 0,
        'can_post': 0,
      },
    ];
    PermissionRuntime.activate(
      userId: 7,
      role: 'Accountant',
      permissionRows: viewAndPrint,
    );
    expect(notifications, 1);

    PermissionRuntime.activate(
      userId: 7,
      role: 'Accountant',
      permissionRows: viewAndPrint,
    );
    expect(notifications, 1, reason: 'unchanged authorization is quiet');

    PermissionRuntime.activate(
      userId: 7,
      role: 'Accountant',
      permissionRows: [
        {...viewAndPrint.single, 'can_print': 0},
      ],
    );
    expect(notifications, 2);

    PermissionRuntime.activate(
      userId: 8,
      role: 'Accountant',
      permissionRows: [
        {...viewAndPrint.single, 'can_print': 0},
      ],
    );
    expect(notifications, 3);

    PermissionRuntime.authorizationRevision.removeListener(listener);
    PermissionRuntime.clear();
    expect(notifications, 3);
  });

  test('view-only reports permission allows preview but not output', () {
    PermissionRuntime.activate(
      userId: 7,
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

    expect(
      () => PermissionRuntime.require('reports', AppPermissionAction.view),
      returnsNormally,
    );
    expect(
      PermissionRuntime.allows('reports', AppPermissionAction.print),
      isFalse,
    );
    expect(
      () => PermissionRuntime.require('reports', AppPermissionAction.print),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'save and print abort before platform actions when authorization is lost',
    () async {
      var checks = 0;
      bool denied() {
        checks++;
        return false;
      }

      await expectLater(
        PrintUtils.savePdf(
          Uint8List.fromList([1, 2, 3]),
          'report',
          isAuthorized: denied,
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        PrintUtils.printPdf(
          Uint8List.fromList([1, 2, 3]),
          'report',
          isAuthorized: denied,
        ),
        throwsA(isA<StateError>()),
      );
      expect(checks, 2);
    },
  );

  testWidgets('opening a protected preview requires view permission', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () {}, child: const Text('host')),
          ),
        ),
      ),
    );
    final context = tester.element(find.text('host'));

    expect(
      () => PdfDocumentPreviewDialog.show(
        context: context,
        bytes: Uint8List(0),
        fileName: 'report',
        preferredIntent: PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      ),
      throwsA(isA<StateError>()),
    );
  });

  testWidgets('reports viewer can open preview but cannot output PDF', (
    tester,
  ) async {
    PermissionRuntime.activate(
      userId: 7,
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
    final provider = ReportsProvider(
      propertyInquiryPropertiesLoader: () async => [
        {'id': 1, 'name': 'عقار اختباري'},
      ],
      propertyInquiryUnitsLoader: (propertyId) async => [
        {
          'id': 10,
          'unit_number': '12-A',
          'status': 'شاغرة',
          'active_contract_count': 0,
        },
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(
          home: Scaffold(body: PropertyUnitInquiryScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('عقار اختباري').last);
    await tester.pumpAndSettle();

    expect(find.text('معاينة PDF'), findsOneWidget);
    expect(find.text('معاينة / طباعة'), findsNothing);
    expect(find.text('حفظ PDF'), findsNothing);
    final previewButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'معاينة PDF'),
    );
    expect(previewButton.onPressed, isNotNull);
    expect(find.text('12-A'), findsOneWidget);

    PermissionRuntime.activate(
      userId: 7,
      role: 'Accountant',
      permissionRows: [
        {
          'screen_name': 'reports',
          'can_view': 0,
          'can_print': 0,
          'can_add': 0,
          'can_edit': 0,
          'can_delete': 0,
          'can_post': 0,
        },
      ],
    );
    await tester.pump();
    expect(
      find.text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      findsOneWidget,
    );
    expect(find.text('12-A'), findsNothing);
  });
}
