import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_theme.dart';
import '../../database/database_location_exception.dart';

class DatabaseStartupRecoveryApp extends StatelessWidget {
  const DatabaseStartupRecoveryApp({super.key, required this.exception});

  final DatabaseLocationException exception;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'استرداد قاعدة البيانات',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: _DatabaseStartupRecoveryScreen(exception: exception),
    );
  }
}

class _DatabaseStartupRecoveryScreen extends StatelessWidget {
  const _DatabaseStartupRecoveryScreen({required this.exception});

  final DatabaseLocationException exception;

  @override
  Widget build(BuildContext context) {
    final details = [
      exception.message,
      if (exception.legacyPath != null)
        'المسار القديم: ${exception.legacyPath}',
      if (exception.activePath != null)
        'المسار الحالي: ${exception.activePath}',
    ].join('\n');

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.storage_rounded,
                      size: 48,
                      color: Color(0xFFB45309),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'تعذر تحديد قاعدة البيانات بأمان',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'لم نفتح قاعدة غير مؤكدة ولم نحذف أو نستبدل أي ملف. أوقفنا بدء النظام حتى لا تُخفى بيانات أو تُكتب على نسخة خاطئة.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    SelectableText(details),
                    const SizedBox(height: 16),
                    const Text(
                      'احتفظ بالنسختين كما هما، ولا تشغّل إصدارًا أقدم ولا تحذف أي ملف. انسخ تفاصيل التشخيص وأرسلها للدعم لمراجعة النسخة الصحيحة.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: details));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('تم نسخ تفاصيل التشخيص'),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_all_outlined),
                      label: const Text('نسخ تفاصيل التشخيص'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
