import 'dart:io';

import 'package:app/core/permission_policy.dart';
import 'package:app/database/database_helper.dart';
import 'package:app/features/master_data/lookups_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory testDirectory;
  late String testDocuments;

  setUpAll(() async {
    testDirectory = await Directory.systemTemp.createTemp(
      'aqari_lookups_screen_test_',
    );
    testDocuments = testDirectory.path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return testDocuments;
          }
          return null;
        });
  });

  setUp(() {
    PermissionRuntime.activate(
      userId: 1,
      role: 'SuperAdmin',
      permissionRows: const [],
    );
  });

  tearDownAll(() async {
    PermissionRuntime.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    await DatabaseHelper.instance.close();
    if (await testDirectory.exists()) {
      await testDirectory.delete(recursive: true);
    }
  });

  testWidgets(
    'search filters visible lookup fields and can be cleared',
    (tester) async {
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final firstCity = 'مدينة-اختبار-$suffix-ألف';
      final secondCity = 'مدينة-اختبار-$suffix-باء';
      await DatabaseHelper.instance.insertLookupData('cities', {
        'name': firstCity,
      });
      await DatabaseHelper.instance.insertLookupData('cities', {
        'name': secondCity,
      });
      final costCenterName = 'مركز-بحث-$suffix';
      await DatabaseHelper.instance.insertLookupData('cost_centers', {
        'name': costCenterName,
      });
      final costCenters = await DatabaseHelper.instance.getLookupData(
        'cost_centers',
      );
      final costCenter = costCenters.singleWhere(
        (row) => row['name'] == costCenterName,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LookupsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(firstCity), findsOneWidget);
      expect(find.text(secondCity), findsOneWidget);

      final searchField = find.byType(TextField).first;
      await tester.enterText(searchField, firstCity);
      await tester.pumpAndSettle();
      expect(find.text(firstCity), findsOneWidget);
      expect(find.text(secondCity), findsNothing);
      expect(find.textContaining('النتائج: 1 من '), findsOneWidget);

      await tester.tap(find.byTooltip('مسح البحث'));
      await tester.pumpAndSettle();
      expect(find.text(firstCity), findsOneWidget);
      expect(find.text(secondCity), findsOneWidget);

      await tester.enterText(searchField, 'عبارة غير موجودة-$suffix');
      await tester.pumpAndSettle();
      expect(find.text('لا توجد نتائج مطابقة لعبارة البحث'), findsOneWidget);
      expect(find.text(firstCity), findsNothing);

      final costCenterTab = find.text('مراكز التكلفة');
      await tester.ensureVisible(costCenterTab);
      await tester.tap(costCenterTab);
      await tester.pumpAndSettle();
      final costCenterSearch = find.byType(TextField).first;
      await tester.enterText(costCenterSearch, costCenter['code'].toString());
      await tester.pumpAndSettle();
      expect(find.text(costCenterName), findsOneWidget);
    },
  );
}
