import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'database/database_helper.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Database
  await DatabaseHelper.instance.database;

  runApp(
    MultiProvider(
      providers: [
        // Add providers here later for state management
        Provider<DatabaseHelper>.value(value: DatabaseHelper.instance),
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
      home: const InitialScreen(),
    );
  }
}

class InitialScreen extends StatelessWidget {
  const InitialScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تهيئة النظام'),
      ),
      body: Center(
        child: FutureBuilder(
          future: DatabaseHelper.instance.database,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const CircularProgressIndicator();
            } else if (snapshot.hasError) {
              return Text('خطأ في تهيئة قاعدة البيانات: \${snapshot.error}');
            } else {
              return const Text(
                'تم تهيئة قاعدة البيانات وإنشاء الجداول بنجاح!\nمرحباً بك في نظام مؤسسة عبدالله النقيب التجارية.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18),
              );
            }
          },
        ),
      ),
    );
  }
}
