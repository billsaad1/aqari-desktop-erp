import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'database/database_helper.dart';
import 'providers/auth_provider.dart';
import 'providers/navigation_provider.dart';
import 'providers/accounting_provider.dart';
import 'providers/property_provider.dart';
import 'features/auth/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Database
  await DatabaseHelper.instance.database;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => NavigationProvider()),
        ChangeNotifierProvider(create: (_) => AccountingProvider()),
        ChangeNotifierProvider(create: (_) => PropertyProvider()),
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
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Tajawal', // Will add font later
      ),
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
