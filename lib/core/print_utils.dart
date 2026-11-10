import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../database/database_helper.dart';

class PrintUtils {
  static const String _defaultCompanyName = 'مؤسسة عبدالله النقيب التجارية';
  static bool get usesShareSheet => Platform.isAndroid || Platform.isIOS;
  static String get savedPdfMessage => usesShareSheet
      ? 'تم تجهيز PDF؛ اختر تطبيق الملفات لحفظه من قائمة المشاركة'
      : 'تم حفظ ملف PDF';

  static Future<pw.ThemeData> loadArabicTheme() async {
    final regularData = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
    final boldData = await rootBundle.load('assets/fonts/Cairo-Bold.ttf');
    return pw.ThemeData.withFont(
      base: pw.Font.ttf(regularData),
      bold: pw.Font.ttf(boldData),
    );
  }

  static String suggestedPdfName(String name) {
    final safeName = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return safeName.toLowerCase().endsWith('.pdf') ? safeName : '$safeName.pdf';
  }

  static Future<bool> savePdf(Uint8List bytes, String name) async {
    final filename = suggestedPdfName(name);
    if (usesShareSheet) {
      await Printing.sharePdf(bytes: bytes, filename: filename);
      return true;
    }
    final location = await getSaveLocation(
      suggestedName: filename,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PDF', extensions: ['pdf']),
      ],
    );
    if (location == null) return false;
    await File(location.path).writeAsBytes(bytes, flush: true);
    return true;
  }

  static Future<void> printPdf(Uint8List bytes, String name) async {
    await Printing.layoutPdf(
      name: suggestedPdfName(name),
      onLayout: (_) async => bytes,
    );
  }

  static Future<Uint8List> buildJournalEntryPdf({
    required int journalNo,
    required String date,
    required String description,
    required List<Map<String, dynamic>> lines,
  }) async {
    final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
    final currency = companyInfo?['default_currency']?.toString() ?? 'ريال';
    final pdf = pw.Document();
    final theme = await loadArabicTheme();
    final debitTotal = lines.fold<double>(
      0,
      (sum, line) => sum + ((line['debit'] as num?)?.toDouble() ?? 0),
    );
    final creditTotal = lines.fold<double>(
      0,
      (sum, line) => sum + ((line['credit'] as num?)?.toDouble() ?? 0),
    );

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          buildBackground: (_) => buildWatermark(companyInfo),
        ),
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        theme: theme,
        header: (_) => buildHeader(companyInfo, true),
        footer: (context) => buildPageFooter(context, companyInfo),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'قيد يومية',
              textDirection: pw.TextDirection.rtl,
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 14),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'رقم القيد: $journalNo',
                textDirection: pw.TextDirection.rtl,
              ),
              pw.Text('التاريخ: $date', textDirection: pw.TextDirection.rtl),
            ],
          ),
          pw.SizedBox(height: 6),
          pw.Text('البيان: $description', textDirection: pw.TextDirection.rtl),
          pw.SizedBox(height: 14),
          pw.TableHelper.fromTextArray(
            headers: ['الحساب', 'البيان', 'مدين', 'دائن'],
            data: lines
                .map(
                  (line) => [
                    line['account_name']?.toString() ?? '',
                    line['description']?.toString() ?? '',
                    ((line['debit'] as num?)?.toDouble() ?? 0).toStringAsFixed(
                      2,
                    ),
                    ((line['credit'] as num?)?.toDouble() ?? 0).toStringAsFixed(
                      2,
                    ),
                  ],
                )
                .toList(),
            headerStyle: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: const pw.BoxDecoration(
              color: PdfColors.blueGrey800,
            ),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellAlignments: {
              0: pw.Alignment.centerRight,
              1: pw.Alignment.centerRight,
              2: pw.Alignment.center,
              3: pw.Alignment.center,
            },
          ),
          pw.SizedBox(height: 10),
          pw.Align(
            alignment: pw.Alignment.centerLeft,
            child: pw.Text(
              'الإجمالي: مدين ${debitTotal.toStringAsFixed(2)}  |  دائن ${creditTotal.toStringAsFixed(2)} $currency',
              textDirection: pw.TextDirection.rtl,
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11),
            ),
          ),
          pw.SizedBox(height: 32),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              _signature('المحاسب'),
              _signature('المراجع'),
              _signature('الاعتماد'),
            ],
          ),
        ],
      ),
    );
    return pdf.save();
  }

  static pw.Widget buildHeader(
    Map<String, dynamic>? info,
    bool isFinancialDocument,
  ) {
    final nameAr = (info?['name_ar'] as String?)?.trim();
    final nameEn = (info?['name_en'] as String?)?.trim();
    final activityAr = (info?['activity_name_ar'] as String?)?.trim();
    final activityEn = (info?['activity_name_en'] as String?)?.trim();
    final commercialRegister = (info?['commercial_register'] as String?)
        ?.trim();
    final taxNumber = (info?['tax_number'] as String?)?.trim();
    final logo = _readLogo((info?['logo_path'] as String?)?.trim());

    return pw.Column(
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (nameEn != null && nameEn.isNotEmpty)
                    pw.Text(
                      nameEn,
                      textDirection: pw.TextDirection.ltr,
                      style: pw.TextStyle(
                        fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  if (activityEn != null && activityEn.isNotEmpty)
                    pw.Text(
                      activityEn,
                      textDirection: pw.TextDirection.ltr,
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  if (isFinancialDocument &&
                      commercialRegister != null &&
                      commercialRegister.isNotEmpty)
                    pw.Text(
                      'C.R: $commercialRegister',
                      textDirection: pw.TextDirection.ltr,
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  if (isFinancialDocument &&
                      taxNumber != null &&
                      taxNumber.isNotEmpty)
                    pw.Text(
                      'VAT: $taxNumber',
                      textDirection: pw.TextDirection.ltr,
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                ],
              ),
            ),
            pw.SizedBox(width: 8),
            if (logo != null)
              pw.Container(
                width: 62,
                alignment: pw.Alignment.center,
                child: pw.Image(logo, height: 50, fit: pw.BoxFit.contain),
              )
            else
              pw.SizedBox(width: 24),
            pw.SizedBox(width: 8),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    nameAr?.isNotEmpty == true ? nameAr! : _defaultCompanyName,
                    textDirection: pw.TextDirection.rtl,
                    textAlign: pw.TextAlign.right,
                    style: pw.TextStyle(
                      fontSize: 13,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (activityAr != null && activityAr.isNotEmpty)
                    pw.Text(
                      activityAr,
                      textDirection: pw.TextDirection.rtl,
                      textAlign: pw.TextAlign.right,
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  if (isFinancialDocument &&
                      commercialRegister != null &&
                      commercialRegister.isNotEmpty)
                    pw.Text(
                      'س.ت: $commercialRegister',
                      textDirection: pw.TextDirection.rtl,
                      textAlign: pw.TextAlign.right,
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  if (isFinancialDocument &&
                      taxNumber != null &&
                      taxNumber.isNotEmpty)
                    pw.Text(
                      'الرقم الضريبي: $taxNumber',
                      textDirection: pw.TextDirection.rtl,
                      textAlign: pw.TextAlign.right,
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Divider(thickness: 1.2, color: PdfColors.blueGrey700),
      ],
    );
  }

  static pw.Widget buildFooter(Map<String, dynamic>? info) {
    final addressAr = _firstNonEmpty(info?['address_ar'], info?['address']);
    final addressEn = _firstNonEmpty(info?['address_en']);
    final poBox = _firstNonEmpty(info?['po_box']);
    final telephone = _firstNonEmpty(info?['telephone']);
    final fax = _firstNonEmpty(info?['fax']);
    final mobile = _firstNonEmpty(info?['mobile']);

    final arabicParts = <String>[
      if (addressAr != null) 'العنوان: $addressAr',
      if (poBox != null) 'ص.ب: $poBox',
      if (telephone != null) 'هاتف: $telephone',
      if (fax != null) 'فاكس: $fax',
      if (mobile != null) 'جوال: $mobile',
    ];
    final englishParts = <String>[
      if (addressEn != null) 'Address: $addressEn',
      if (poBox != null) 'P.O. Box: $poBox',
      if (telephone != null) 'Tel: $telephone',
      if (fax != null) 'Fax: $fax',
      if (mobile != null) 'Mobile: $mobile',
    ];

    return pw.Column(
      children: [
        pw.Divider(thickness: 0.8, color: PdfColors.grey600),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Text(
                arabicParts.join('  |  '),
                textDirection: pw.TextDirection.rtl,
                textAlign: pw.TextAlign.right,
                style: const pw.TextStyle(
                  fontSize: 7,
                  color: PdfColors.grey700,
                ),
              ),
            ),
            pw.SizedBox(width: 8),
            pw.Expanded(
              child: pw.Text(
                englishParts.join('  |  '),
                textDirection: pw.TextDirection.ltr,
                textAlign: pw.TextAlign.left,
                style: const pw.TextStyle(
                  fontSize: 7,
                  color: PdfColors.grey700,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static pw.Widget buildPageFooter(
    pw.Context context,
    Map<String, dynamic>? info,
  ) {
    return pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        buildFooter(info),
        pw.SizedBox(height: 3),
        pw.Align(
          alignment: pw.Alignment.center,
          child: pw.Text(
            'صفحة ${context.pageNumber} من ${context.pagesCount}',
            textDirection: pw.TextDirection.rtl,
            style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
          ),
        ),
      ],
    );
  }

  static pw.Widget buildWatermark(Map<String, dynamic>? info) {
    final logo = _readLogo((info?['logo_path'] as String?)?.trim());
    if (logo == null) return pw.SizedBox();
    return pw.Center(
      child: pw.Opacity(
        opacity: 0.075,
        child: pw.Image(logo, width: 260, fit: pw.BoxFit.contain),
      ),
    );
  }

  static pw.MemoryImage? _readLogo(String? logoPath) {
    if (logoPath == null || logoPath.isEmpty) return null;
    try {
      final file = File(logoPath);
      if (!file.existsSync()) return null;
      return pw.MemoryImage(file.readAsBytesSync());
    } catch (_) {
      return null;
    }
  }

  static String? _firstNonEmpty(Object? first, [Object? second]) {
    for (final value in [first, second]) {
      final text = value?.toString().trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  static Future<Uint8List> buildVoucherPdf({
    required String voucherType,
    required int voucherNo,
    required String date,
    required String targetName,
    required double amount,
    required String paymentMethod,
    required String accountName,
    String? description,
    bool isFinancialDocument = true,
  }) async {
    final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
    final pdf = pw.Document();
    final theme = await loadArabicTheme();
    final currency = (companyInfo?['default_currency'] as String?)?.trim();
    final currencyLabel = currency == null || currency.isEmpty
        ? 'ريال'
        : currency;

    pdf.addPage(
      pw.Page(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a5.landscape,
          textDirection: pw.TextDirection.rtl,
          theme: theme,
          buildBackground: (_) => buildWatermark(companyInfo),
        ),
        build: (_) => pw.Container(
          padding: const pw.EdgeInsets.all(10),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              buildHeader(companyInfo, isFinancialDocument),
              pw.Center(
                child: pw.Text(
                  voucherType,
                  textDirection: pw.TextDirection.rtl,
                  style: pw.TextStyle(
                    fontSize: 19,
                    fontWeight: pw.FontWeight.bold,
                    decoration: pw.TextDecoration.underline,
                  ),
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'رقم السند: $voucherNo',
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                  pw.Text(
                    'التاريخ: $date',
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 10),
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  color: PdfColors.grey100,
                  border: pw.Border.all(color: PdfColors.grey400),
                  borderRadius: pw.BorderRadius.circular(4),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      '${voucherType.contains('قبض') ? 'استلمنا من' : 'صرفنا إلى'}: $targetName',
                      textDirection: pw.TextDirection.rtl,
                      style: const pw.TextStyle(fontSize: 12),
                    ),
                    pw.SizedBox(height: 5),
                    pw.Text(
                      'المبلغ: ${amount.toStringAsFixed(2)} $currencyLabel',
                      textDirection: pw.TextDirection.rtl,
                      style: pw.TextStyle(
                        fontSize: 13,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    if (description != null &&
                        description.trim().isNotEmpty) ...[
                      pw.SizedBox(height: 5),
                      pw.Text(
                        'البيان: ${description.trim()}',
                        textDirection: pw.TextDirection.rtl,
                        style: const pw.TextStyle(fontSize: 10),
                      ),
                    ],
                    pw.SizedBox(height: 5),
                    pw.Text(
                      'طريقة الدفع: $paymentMethod  |  الحساب: $accountName',
                      textDirection: pw.TextDirection.rtl,
                      style: const pw.TextStyle(fontSize: 9),
                    ),
                  ],
                ),
              ),
              pw.Spacer(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  _signature('توقيع المحاسب'),
                  _signature('الختم الرسمي'),
                  _signature('توقيع المستلم'),
                ],
              ),
              pw.SizedBox(height: 5),
              buildFooter(companyInfo),
            ],
          ),
        ),
      ),
    );
    return pdf.save();
  }

  static pw.Widget _signature(String title) => pw.Column(
    children: [
      pw.Text(
        title,
        textDirection: pw.TextDirection.rtl,
        style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
      ),
      pw.SizedBox(height: 18),
      pw.Text('____________________', style: const pw.TextStyle(fontSize: 8)),
    ],
  );

  static Future<void> printVoucher({
    required String voucherType,
    required int voucherNo,
    required String date,
    required String targetName,
    required double amount,
    required String paymentMethod,
    required String accountName,
    String? description,
    bool isFinancialDocument = true,
  }) async {
    final bytes = await buildVoucherPdf(
      voucherType: voucherType,
      voucherNo: voucherNo,
      date: date,
      targetName: targetName,
      amount: amount,
      paymentMethod: paymentMethod,
      accountName: accountName,
      description: description,
      isFinancialDocument: isFinancialDocument,
    );
    await printPdf(bytes, '${voucherType}_$voucherNo');
  }
}
