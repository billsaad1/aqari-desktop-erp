import 'package:app/core/permission_policy.dart';
import 'package:app/features/tenant_notices/tenant_notices_screen.dart';
import 'package:app/providers/tenant_notices_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => _activateNoticePermissions(canPrint: true));
  tearDown(PermissionRuntime.clear);

  testWidgets(
    'PDF action requires issued status and current print permission',
    (tester) async {
      final provider = _FakeTenantNoticesProvider();
      addTearDown(provider.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<TenantNoticesProvider>.value(
          value: provider,
          child: const MaterialApp(home: Scaffold(body: TenantNoticesScreen())),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('مسودة'), findsOneWidget);
      expect(find.text('معاينة PDF'), findsNothing);
      expect(find.text('حفظ Word'), findsNothing);

      provider.notice['status'] = 'Issued';
      await tester.tap(find.byTooltip('تحديث'));
      await tester.pumpAndSettle();

      expect(find.text('صادر'), findsOneWidget);
      expect(find.text('معاينة PDF'), findsOneWidget);
      expect(find.text('حفظ Word'), findsNothing);

      _activateNoticePermissions(canPrint: false);
      await tester.pump();
      expect(find.text('معاينة PDF'), findsNothing);
      expect(find.text('حفظ Word'), findsNothing);
      await expectLater(provider.buildPdf(1), throwsA(isA<StateError>()));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

void _activateNoticePermissions({required bool canPrint}) {
  PermissionRuntime.activate(
    userId: 78,
    role: 'Accountant',
    permissionRows: [
      {
        'screen_name': 'notices',
        'can_view': 1,
        'can_add': 1,
        'can_edit': 0,
        'can_delete': 0,
        'can_print': canPrint ? 1 : 0,
        'can_post': 1,
      },
    ],
  );
}

class _FakeTenantNoticesProvider extends TenantNoticesProvider {
  final Map<String, dynamic> notice = {
    'id': 1,
    'status': 'Draft',
    'subject': 'إشعار للاختبار',
    'body': 'نص الإشعار.',
    'notice_date': '2026-11-19',
    'recipient_name_snapshot': 'مستأجر الاختبار',
    'recipient_phone_snapshot': '777000111',
  };

  @override
  List<Map<String, dynamic>> get notices => [notice];

  @override
  Future<void> loadNotices() async => notifyListeners();

  @override
  Future<Map<String, dynamic>?> loadNotice(int noticeId) async =>
      Map<String, dynamic>.from(notice);

  @override
  Future<List<Map<String, dynamic>>> loadEvents(int noticeId) async => [];

  @override
  Future<Map<String, dynamic>?> loadCompanyInfo() async => null;
}
