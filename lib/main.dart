import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'database/database_helper.dart';
import 'database/database_location_exception.dart';
import 'providers/auth_provider.dart';
import 'providers/navigation_provider.dart';
import 'providers/accounting_provider.dart';
import 'providers/property_provider.dart';
import 'providers/leasing_provider.dart';
import 'providers/reports_provider.dart';
import 'providers/sms_provider.dart';
import 'providers/tenant_notices_provider.dart';
import 'features/auth/login_screen.dart';
import 'features/system_settings/database_startup_recovery_screen.dart';
import 'core/app_theme.dart';
import 'core/session_idle_guard.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Do not show the normal ERP until the live database is located and opened.
  try {
    await DatabaseHelper.instance.database;
  } catch (error) {
    final exception = error is DatabaseLocationException
        ? error
        : DatabaseLocationException(
            message:
                'تعذر تهيئة قاعدة البيانات بأمان. لم نحذف أي ملف. أرسل تفاصيل الخطأ للدعم: $error',
          );
    runApp(DatabaseStartupRecoveryApp(exception: exception));
    return;
  }
  try {
    await DatabaseHelper.instance.migrateLegacySmsCredentials();
  } catch (_) {
    // The SMS settings screen exposes a safe recovery prompt if the OS vault
    // is temporarily unavailable; unrelated ERP modules must still open.
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => NavigationProvider()),
        ChangeNotifierProvider(create: (_) => AccountingProvider()),
        ChangeNotifierProxyProvider<AuthProvider, PropertyProvider>(
          create: (_) => PropertyProvider(),
          update: (context, auth, provider) {
            final next = provider ?? PropertyProvider();
            next.syncAuthorization(
              userId: auth.currentUser?.id,
              canViewProperties: auth.canAccessScreen('properties'),
              canViewLeasing: auth.canAccessScreen('leasing'),
            );
            return next;
          },
        ),
        ChangeNotifierProvider(create: (_) => LeasingProvider()),
        ChangeNotifierProxyProvider<AuthProvider, ReportsProvider>(
          create: (_) => ReportsProvider(),
          update: (context, auth, provider) {
            final next = provider ?? ReportsProvider();
            next.syncAuthorization(
              userId: auth.currentUser?.id,
              canViewReports: auth.canAccessScreen('reports'),
            );
            return next;
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, SmsProvider>(
          create: (_) => SmsProvider(),
          update: (context, auth, provider) {
            final next = provider ?? SmsProvider();
            next.syncAuthorization(
              userId: auth.currentUser?.id,
              canViewSms: auth.canAccessScreen('sms'),
            );
            return next;
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, TenantNoticesProvider>(
          create: (_) => TenantNoticesProvider(),
          update: (context, auth, provider) {
            final next = provider ?? TenantNoticesProvider();
            next.syncAuthorization(
              userId: auth.currentUser?.id,
              canViewNotices: auth.canAccessScreen('notices'),
            );
            return next;
          },
        ),
      ],
      child: const ERPApp(),
    ),
  );
}

class ERPApp extends StatelessWidget {
  const ERPApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مؤسسة عبدالله النقيب التجارية - ERP',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      builder: (context, child) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => SessionIdleGuard.notifyGlobalActivity(),
        onPointerMove: (_) => SessionIdleGuard.notifyGlobalActivity(),
        onPointerSignal: (_) => SessionIdleGuard.notifyGlobalActivity(),
        child: child ?? const SizedBox.shrink(),
      ),
      scrollBehavior: const MaterialScrollBehavior().copyWith(scrollbars: true),
      // RTL Support for Arabic
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ar', 'SA'), // Arabic
      ],
      locale: const Locale('ar', 'SA'),
      home: const LoginScreen(),
    );
  }
}
