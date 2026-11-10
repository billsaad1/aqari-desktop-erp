import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'arabic_amount_words.dart';
import '../database/database_helper.dart';

class PrintUtils {
  static const PdfColor brandNavy = PdfColor.fromInt(0xFF17324F);
  static const PdfColor brandEmerald = PdfColor.fromInt(0xFF16856B);
  static const PdfColor softSurface = PdfColor.fromInt(0xFFF4F7F8);
  static const PdfColor softBorder = PdfColor.fromInt(0xFFD8E0E4);
  static const String _defaultCompanyName = 'مؤسسة عبدالله النقيب التجارية';
  static String? _cachedLogoPath;
  static DateTime? _cachedLogoModified;
  static pw.MemoryImage? _cachedLogoImage;
  static bool get usesShareSheet => Platform.isAndroid || Platform.isIOS;
  static String get savedPdfMessage => usesShareSheet
      ? 'تم تجهيز PDF؛ اختر تطبيق الملفات لحفظه من قائمة المشاركة'
      : 'تم حفظ ملف PDF';

  static Future<pw.ThemeData> loadArabicTheme() async {
    final regularData = await rootBundle.load(
      'assets/fonts/AqariPDFArabic-Regular.ttf',
    );
    final boldData = await rootBundle.load(
      'assets/fonts/AqariPDFArabic-Bold.ttf',
    );
    return pw.ThemeData.withFont(
      base: pw.Font.ttf(regularData),
      bold: pw.Font.ttf(boldData),
    );
  }

  static pw.PageTheme pageTheme({
    required pw.ThemeData theme,
    required Map<String, dynamic>? companyInfo,
    PdfPageFormat pageFormat = PdfPageFormat.a4,
    pw.EdgeInsets margin = const pw.EdgeInsets.fromLTRB(32, 30, 32, 32),
  }) => pw.PageTheme(
    pageFormat: pageFormat,
    textDirection: pw.TextDirection.rtl,
    theme: theme,
    margin: margin,
    buildBackground: (_) => buildWatermark(companyInfo),
  );

  static String formatPdfAmount(num amount) =>
      NumberFormat('#,##0.00', 'en_US').format(amount);

  static pw.TextDirection resolveTextDirection(
    String text, {
    pw.TextDirection? preferred,
  }) {
    if (RegExp(r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]').hasMatch(text)) {
      return pw.TextDirection.rtl;
    }
    if (preferred != null) return preferred;
    return RegExp(r'[A-Za-z0-9]').hasMatch(text)
        ? pw.TextDirection.ltr
        : pw.TextDirection.rtl;
  }

  static void clearLogoCache() {
    _cachedLogoPath = null;
    _cachedLogoModified = null;
    _cachedLogoImage = null;
  }

  static String suggestedPdfName(String name) {
    final safeName = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    return safeName.toLowerCase().endsWith('.pdf') ? safeName : '$safeName.pdf';
  }

  static String currencyInArabic(Object? raw, {String fallback = 'ريال'}) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) return fallback;
    final normalized = value.toLowerCase();
    if (normalized.contains('sar') || normalized.contains('سعودي')) {
      return 'ريال سعودي';
    }
    if (normalized.contains('yer') || normalized.contains('يمني')) {
      return 'ريال يمني';
    }
    if (normalized.contains('usd') || normalized.contains('دولار')) {
      return 'دولار أمريكي';
    }
    if (normalized.contains('aed') || normalized.contains('إمارات')) {
      return 'درهم إماراتي';
    }
    if (normalized.contains('kwd') || normalized.contains('كويتي')) {
      return 'دينار كويتي';
    }
    if (normalized.contains('omr') || normalized.contains('عماني')) {
      return 'ريال عماني';
    }
    if (normalized.contains('qar') || normalized.contains('قطري')) {
      return 'ريال قطري';
    }
    if (normalized.contains('bhd') || normalized.contains('بحريني')) {
      return 'دينار بحريني';
    }
    if (normalized.contains('egp') || normalized.contains('مصري')) {
      return 'جنيه مصري';
    }
    if (normalized.contains('eur') || normalized.contains('يورو')) {
      return 'يورو';
    }
    return value.replaceAll(RegExp(r'\s*\([A-Za-z]{3}\)\s*'), '').trim();
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
    final currency = currencyInArabic(companyInfo?['default_currency']);
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
        pageTheme: pageTheme(theme: theme, companyInfo: companyInfo),
        header: (_) => buildHeader(companyInfo, true),
        footer: (context) => buildPageFooter(context, companyInfo),
        build: (_) => [
          _documentTitle('قيد يومية'),
          pw.SizedBox(height: 14),
          pw.Row(
            children: [
              pw.Expanded(
                child: _metadataItem(
                  'رقم القيد',
                  journalNo.toString(),
                  pw.TextDirection.ltr,
                ),
              ),
              pw.SizedBox(width: 12),
              pw.Expanded(
                child: _metadataItem('تاريخ القيد', date, pw.TextDirection.ltr),
              ),
            ],
          ),
          pw.SizedBox(height: 6),
          if (description.trim().isNotEmpty)
            buildLabelValue('البيان', description.trim()),
          pw.SizedBox(height: 14),
          pw.TableHelper.fromTextArray(
            headers: ['الحساب', 'البيان', 'مدين', 'دائن'],
            data: lines
                .map(
                  (line) => [
                    line['account_name']?.toString() ?? '',
                    line['description']?.toString() ?? '',
                    formatPdfAmount((line['debit'] as num?)?.toDouble() ?? 0),
                    formatPdfAmount((line['credit'] as num?)?.toDouble() ?? 0),
                  ],
                )
                .toList(),
            headerStyle: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: brandNavy),
            cellStyle: const pw.TextStyle(fontSize: 9, lineSpacing: 2),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 5,
              vertical: 6,
            ),
            cellAlignments: {
              0: pw.Alignment.centerRight,
              1: pw.Alignment.centerRight,
              2: pw.Alignment.center,
              3: pw.Alignment.center,
            },
            tableDirection: pw.TextDirection.rtl,
            headerDirection: pw.TextDirection.rtl,
            columnWidths: const {
              0: pw.FlexColumnWidth(1.6),
              1: pw.FlexColumnWidth(2.4),
              2: pw.FlexColumnWidth(1),
              3: pw.FlexColumnWidth(1),
            },
            border: pw.TableBorder.all(color: softBorder, width: 0.5),
          ),
          pw.SizedBox(height: 10),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: softSurface,
              borderRadius: pw.BorderRadius.circular(5),
              border: pw.Border.all(color: softBorder),
            ),
            child: pw.Row(
              children: [
                pw.Expanded(child: _totalMetric('إجمالي المدين', debitTotal)),
                pw.Expanded(child: _totalMetric('إجمالي الدائن', creditTotal)),
                pw.Expanded(
                  child: _totalMetric('العملة', 0, displayValue: currency),
                ),
              ],
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

  static pw.Widget _totalMetric(
    String label,
    double value, {
    String? displayValue,
  }) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    mainAxisSize: pw.MainAxisSize.min,
    children: [
      pw.Text(
        label,
        textDirection: pw.TextDirection.rtl,
        textAlign: pw.TextAlign.center,
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
      ),
      pw.SizedBox(height: 3),
      pw.Text(
        displayValue ?? formatPdfAmount(value),
        textDirection: displayValue == null
            ? pw.TextDirection.ltr
            : pw.TextDirection.rtl,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: 10,
          fontWeight: pw.FontWeight.bold,
          color: brandNavy,
        ),
      ),
    ],
  );

  static pw.Widget buildHeader(
    Map<String, dynamic>? info,
    bool isFinancialDocument,
  ) {
    final nameAr = _firstNonEmpty(info?['name_ar']) ?? _defaultCompanyName;
    final nameEn = _firstNonEmpty(info?['name_en']);
    final activityAr = _firstNonEmpty(
      info?['activity_name_ar'],
      info?['activity'],
    );
    final activityEn = _firstNonEmpty(info?['activity_name_en']);
    final commercialRegister = _firstNonEmpty(info?['commercial_register']);
    final taxNumber = _firstNonEmpty(info?['tax_number']);
    final logo = _readLogo((info?['logo_path'] as String?)?.trim());

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            // In an RTL page, the first expanded block is physically on the right.
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                mainAxisSize: pw.MainAxisSize.min,
                children: [
                  pw.Text(
                    nameAr,
                    textDirection: pw.TextDirection.rtl,
                    textAlign: pw.TextAlign.start,
                    overflow: pw.TextOverflow.visible,
                    style: pw.TextStyle(
                      fontSize: 14,
                      fontWeight: pw.FontWeight.bold,
                      color: brandNavy,
                    ),
                  ),
                  if (activityAr != null) ...[
                    pw.SizedBox(height: 2.5),
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(left: 2, right: 4),
                      child: pw.Text(
                        activityAr,
                        textDirection: pw.TextDirection.rtl,
                        textAlign: pw.TextAlign.start,
                        overflow: pw.TextOverflow.visible,
                        style: const pw.TextStyle(fontSize: 8.5),
                      ),
                    ),
                  ],
                  if (commercialRegister != null ||
                      (isFinancialDocument && taxNumber != null))
                    pw.SizedBox(height: 2.5),
                  if (commercialRegister != null)
                    _companyNumberLine('س.ت:', commercialRegister),
                  if (isFinancialDocument && taxNumber != null) ...[
                    if (commercialRegister != null) pw.SizedBox(height: 1.5),
                    _companyNumberLine('الرقم الضريبي:', taxNumber),
                  ],
                ],
              ),
            ),
            pw.SizedBox(width: 10),
            pw.Container(
              width: 64,
              height: 64,
              alignment: pw.Alignment.center,
              child: logo == null
                  ? pw.SizedBox()
                  : pw.Image(
                      logo,
                      width: 64,
                      height: 64,
                      fit: pw.BoxFit.contain,
                    ),
            ),
            pw.SizedBox(width: 10),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                mainAxisSize: pw.MainAxisSize.min,
                children: [
                  if (nameEn != null)
                    pw.Text(
                      nameEn,
                      textDirection: pw.TextDirection.ltr,
                      textAlign: pw.TextAlign.left,
                      style: pw.TextStyle(
                        fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                        color: brandNavy,
                      ),
                    ),
                  if (activityEn != null) ...[
                    pw.SizedBox(height: 2.5),
                    pw.Text(
                      activityEn,
                      textDirection: pw.TextDirection.ltr,
                      textAlign: pw.TextAlign.left,
                      overflow: pw.TextOverflow.visible,
                      style: const pw.TextStyle(fontSize: 8.5),
                    ),
                  ],
                  if (commercialRegister != null) ...[
                    if (activityEn != null) pw.SizedBox(height: 1.5),
                    pw.Text(
                      'C.R. $commercialRegister',
                      textDirection: pw.TextDirection.ltr,
                      textAlign: pw.TextAlign.left,
                      overflow: pw.TextOverflow.visible,
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 6),
        pw.Container(height: 1.4, color: brandEmerald),
        pw.SizedBox(height: 5),
      ],
    );
  }

  static pw.Widget _companyNumberLine(String label, String value) => pw.Row(
    mainAxisSize: pw.MainAxisSize.min,
    children: [
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 2),
        child: pw.Text(
          label,
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.start,
          overflow: pw.TextOverflow.visible,
          style: const pw.TextStyle(fontSize: 8),
        ),
      ),
      pw.SizedBox(width: 3),
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 2),
        child: pw.Text(
          value,
          textDirection: pw.TextDirection.ltr,
          overflow: pw.TextOverflow.visible,
          style: const pw.TextStyle(fontSize: 8),
        ),
      ),
    ],
  );

  static pw.Widget buildFooter(Map<String, dynamic>? info) {
    final addressAr = _firstNonEmpty(info?['address_ar'], info?['address']);
    final addressEn = _firstNonEmpty(info?['address_en']);
    final poBox = _firstNonEmpty(info?['po_box']);
    final telephone = _firstNonEmpty(info?['telephone']);
    final fax = _firstNonEmpty(info?['fax']);
    final mobile = _firstNonEmpty(info?['mobile']);
    final englishParts = <String>[
      ?addressEn,
      if (poBox != null) 'P.O. Box $poBox',
      if (telephone != null) 'Tel. $telephone',
      if (fax != null) 'Fax $fax',
      if (mobile != null) 'Mobile $mobile',
    ];
    final contactFields = <(String, String)>[
      if (telephone != null) ('هاتف', telephone),
      if (fax != null) ('فاكس', fax),
      if (mobile != null) ('جوال', mobile),
    ];

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Container(height: 1, color: brandEmerald),
        pw.SizedBox(height: 5),
        if (addressAr != null || poBox != null)
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              if (addressAr != null)
                pw.Expanded(
                  flex: 3,
                  child: _footerInlineField(
                    'العنوان',
                    addressAr,
                    valueDirection: pw.TextDirection.rtl,
                  ),
                ),
              if (poBox != null)
                pw.Expanded(
                  child: _footerInlineField(
                    'ص.ب',
                    poBox,
                    valueDirection: pw.TextDirection.ltr,
                  ),
                ),
            ],
          ),
        if (contactFields.isNotEmpty) ...[
          pw.SizedBox(height: 4),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              for (final field in contactFields)
                pw.Expanded(
                  child: _footerInlineField(
                    field.$1,
                    field.$2,
                    valueDirection: pw.TextDirection.ltr,
                  ),
                ),
            ],
          ),
        ],
        if (englishParts.isNotEmpty) ...[
          pw.SizedBox(height: 4),
          pw.Text(
            englishParts.join('   |   '),
            textDirection: pw.TextDirection.ltr,
            textAlign: pw.TextAlign.center,
            overflow: pw.TextOverflow.visible,
            style: const pw.TextStyle(fontSize: 7.2, color: PdfColors.grey700),
          ),
        ],
      ],
    );
  }

  static pw.Widget _footerInlineField(
    String label,
    String value, {
    required pw.TextDirection valueDirection,
    pw.TextAlign valueAlignment = pw.TextAlign.center,
  }) => pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.center,
    children: [
      pw.Padding(
        padding: const pw.EdgeInsets.only(left: 2, right: 4),
        child: pw.Text(
          '$label:',
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.start,
          overflow: pw.TextOverflow.visible,
          style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700),
        ),
      ),
      pw.Expanded(
        child: pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4),
          child: pw.Text(
            value,
            textDirection: valueDirection,
            textAlign: valueDirection == pw.TextDirection.rtl
                ? pw.TextAlign.start
                : valueAlignment,
            overflow: pw.TextOverflow.visible,
            style: const pw.TextStyle(fontSize: 8.2, color: PdfColors.grey900),
          ),
        ),
      ),
    ],
  );

  static pw.Widget buildPageFooter(
    pw.Context context,
    Map<String, dynamic>? info,
  ) {
    return pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        buildFooter(info),
        if (context.pagesCount > 1) ...[
          pw.SizedBox(height: 4),
          pw.Align(
            alignment: pw.Alignment.center,
            child: pw.Text(
              'صفحة ${context.pageNumber} من ${context.pagesCount}',
              textDirection: pw.TextDirection.rtl,
              style: const pw.TextStyle(
                fontSize: 7.5,
                color: PdfColors.grey700,
              ),
            ),
          ),
        ],
      ],
    );
  }

  static pw.Widget buildWatermark(Map<String, dynamic>? info) {
    final logo = _readLogo((info?['logo_path'] as String?)?.trim());
    if (logo == null) return pw.SizedBox();
    return pw.Center(
      child: pw.Opacity(
        opacity: 0.03,
        child: pw.Image(logo, width: 220, fit: pw.BoxFit.contain),
      ),
    );
  }

  static pw.MemoryImage? _readLogo(String? logoPath) {
    if (logoPath == null || logoPath.isEmpty) return null;
    try {
      final file = File(logoPath);
      if (!file.existsSync()) return null;
      if (file.lengthSync() > 8 * 1024 * 1024) return null;
      final modified = file.lastModifiedSync();
      if (_cachedLogoPath == file.path && _cachedLogoModified == modified) {
        return _cachedLogoImage;
      }
      final extension = file.path.split('.').last.toLowerCase();
      if (!const {'png', 'jpg', 'jpeg'}.contains(extension)) return null;
      _cachedLogoPath = file.path;
      _cachedLogoModified = modified;
      _cachedLogoImage = pw.MemoryImage(file.readAsBytesSync());
      return _cachedLogoImage;
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
    String? targetName,
    required double amount,
    String? paymentMethod,
    required String accountName,
    String? description,
    List<Map<String, dynamic>> journalLines = const [],
    List<Map<String, dynamic>> installmentAllocations = const [],
    bool isFinancialDocument = true,
  }) async {
    final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
    final pdf = pw.Document();
    final theme = await loadArabicTheme();
    final currencyLabel = currencyInArabic(companyInfo?['default_currency']);
    final isReceipt = voucherType.contains('قبض');
    final hasParty = targetName != null && targetName.trim().isNotEmpty;
    final normalizedMethod = paymentMethod?.trim();
    final showPaymentMethod =
        normalizedMethod != null &&
        normalizedMethod.isNotEmpty &&
        normalizedMethod != 'نقداً/بنكي' &&
        normalizedMethod != 'حسب الحسابات المرحلة';

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pageTheme(
          theme: theme,
          companyInfo: companyInfo,
          pageFormat: PdfPageFormat.a5.landscape,
          margin: const pw.EdgeInsets.fromLTRB(24, 18, 24, 22),
        ),
        header: (_) => buildHeader(companyInfo, isFinancialDocument),
        footer: (context) => buildPageFooter(context, companyInfo),
        build: (_) => [
          _documentTitle(voucherType),
          pw.SizedBox(height: 6),
          pw.Row(
            children: [
              pw.Expanded(
                child: _metadataItem(
                  'رقم السند',
                  voucherNo.toString(),
                  pw.TextDirection.ltr,
                ),
              ),
              pw.SizedBox(width: 12),
              pw.Expanded(
                child: _metadataItem('تاريخ السند', date, pw.TextDirection.ltr),
              ),
            ],
          ),
          pw.SizedBox(height: 9),
          pw.Container(
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              color: softSurface,
              border: pw.Border.all(color: softBorder),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                if (hasParty)
                  isReceipt
                      ? pw.Padding(
                          padding: const pw.EdgeInsets.only(
                            left: 4,
                            right: 5,
                            bottom: 7,
                          ),
                          child: pw.Text(
                            'استلمنا من الأخ/الأخت ${targetName.trim()}',
                            textDirection: pw.TextDirection.rtl,
                            textAlign: pw.TextAlign.start,
                            overflow: pw.TextOverflow.visible,
                            style: pw.TextStyle(
                              fontSize: 11,
                              fontWeight: pw.FontWeight.bold,
                              color: brandNavy,
                            ),
                          ),
                        )
                      : buildLabelValue(
                          'اسم المستفيد',
                          targetName.trim(),
                          labelWidth: 100,
                          fontSize: 10.5,
                        ),
                pw.Row(
                  children: [
                    pw.Text(
                      isReceipt ? 'مبلغ وقدره (رقماً)' : 'المبلغ',
                      textDirection: pw.TextDirection.rtl,
                      style: const pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.grey700,
                      ),
                    ),
                    pw.SizedBox(width: 10),
                    pw.Text(
                      formatPdfAmount(amount),
                      textDirection: pw.TextDirection.ltr,
                      style: pw.TextStyle(
                        fontSize: 16,
                        fontWeight: pw.FontWeight.bold,
                        color: brandNavy,
                      ),
                    ),
                    pw.SizedBox(width: 7),
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 3),
                      child: pw.Text(
                        currencyLabel,
                        textDirection: pw.TextDirection.rtl,
                        textAlign: pw.TextAlign.start,
                        overflow: pw.TextOverflow.visible,
                        style: pw.TextStyle(
                          fontSize: 10.5,
                          fontWeight: pw.FontWeight.bold,
                          color: brandEmerald,
                        ),
                      ),
                    ),
                  ],
                ),
                if (isReceipt)
                  buildLabelValue(
                    'وكتابةً',
                    '${ArabicAmountWords.format(amount, currencyLabel)} فقط لا غير',
                    labelWidth: 100,
                    fontSize: 10,
                  ),
                if (description != null && description.trim().isNotEmpty)
                  buildLabelValue(
                    'البيان',
                    isReceipt
                        ? 'وذلك مقابل ${description.trim()}'
                        : description.trim(),
                    labelWidth: 100,
                    fontSize: 10,
                  ),
                if (showPaymentMethod)
                  buildLabelValue(
                    'طريقة الدفع',
                    normalizedMethod,
                    labelWidth: 100,
                    fontSize: 9,
                  ),
                if (accountName.trim().isNotEmpty)
                  buildLabelValue(
                    'الحساب',
                    accountName,
                    labelWidth: 72,
                    fontSize: 9,
                  ),
              ],
            ),
          ),
          pw.SizedBox(height: 18),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _signature('توقيع المحاسب'),
              _signature('الختم الرسمي'),
              _signature(isReceipt ? 'توقيع المستلم' : 'توقيع المستفيد'),
            ],
          ),
          if (journalLines.isNotEmpty || installmentAllocations.isNotEmpty) ...[
            pw.NewPage(),
            _documentTitle('ملحق تفاصيل السند'),
            buildLabelValue(
              'رقم السند',
              voucherNo.toString(),
              valueDirection: pw.TextDirection.ltr,
            ),
          ],
          if (journalLines.isNotEmpty) ...[
            pw.SizedBox(height: 10),
            _documentTitle('تفاصيل القيد المحاسبي'),
            pw.SizedBox(height: 5),
            pw.TableHelper.fromTextArray(
              headers: ['الحساب', 'مدين', 'دائن'],
              data: journalLines
                  .map(
                    (line) => [
                      line['account_name']?.toString() ?? '',
                      formatPdfAmount((line['debit'] as num?)?.toDouble() ?? 0),
                      formatPdfAmount(
                        (line['credit'] as num?)?.toDouble() ?? 0,
                      ),
                    ],
                  )
                  .toList(),
              headerStyle: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: pw.BoxDecoration(color: brandNavy),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 5,
                vertical: 5,
              ),
              tableDirection: pw.TextDirection.rtl,
              headerDirection: pw.TextDirection.rtl,
              columnWidths: const {
                0: pw.FlexColumnWidth(2.4),
                1: pw.FlexColumnWidth(1),
                2: pw.FlexColumnWidth(1),
              },
              border: pw.TableBorder.all(color: softBorder, width: 0.5),
            ),
          ],
          if (installmentAllocations.isNotEmpty) ...[
            pw.SizedBox(height: 10),
            _documentTitle('توزيع الدفعة على الأقساط'),
            pw.SizedBox(height: 5),
            pw.TableHelper.fromTextArray(
              headers: [
                'العقار',
                'الوحدة',
                'تاريخ الاستحقاق',
                'مبلغ القسط',
                'المبلغ المخصص',
              ],
              data: installmentAllocations
                  .map(
                    (installment) => [
                      installment['property_name']?.toString() ?? '',
                      installment['unit_number']?.toString() ?? '',
                      installment['due_date']?.toString() ?? '',
                      formatPdfAmount(
                        (installment['installment_amount'] as num?)
                                ?.toDouble() ??
                            0,
                      ),
                      formatPdfAmount(
                        (installment['allocated_amount'] as num?)?.toDouble() ??
                            0,
                      ),
                    ],
                  )
                  .toList(),
              headerStyle: pw.TextStyle(
                fontSize: 7.5,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: pw.BoxDecoration(color: brandNavy),
              cellStyle: const pw.TextStyle(fontSize: 7.5),
              cellPadding: const pw.EdgeInsets.symmetric(
                horizontal: 3,
                vertical: 4,
              ),
              tableDirection: pw.TextDirection.rtl,
              headerDirection: pw.TextDirection.rtl,
              columnWidths: const {
                0: pw.FlexColumnWidth(1.7),
                1: pw.FlexColumnWidth(0.8),
                2: pw.FlexColumnWidth(1.4),
                3: pw.FlexColumnWidth(1.2),
                4: pw.FlexColumnWidth(1.2),
              },
              border: pw.TableBorder.all(color: softBorder, width: 0.5),
            ),
          ],
        ],
      ),
    );
    return pdf.save();
  }

  static pw.Widget _documentTitle(String title) => pw.Center(
    child: pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text(
          title,
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: 16,
            fontWeight: pw.FontWeight.bold,
            color: brandNavy,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Container(width: 58, height: 2, color: brandEmerald),
      ],
    ),
  );

  static pw.Widget _metadataItem(
    String label,
    String value,
    pw.TextDirection direction,
  ) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    mainAxisSize: pw.MainAxisSize.min,
    children: [
      pw.Text(
        label,
        textDirection: pw.TextDirection.rtl,
        textAlign: pw.TextAlign.center,
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
      ),
      pw.SizedBox(height: 2),
      pw.Text(
        value,
        textDirection: direction,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: 10,
          fontWeight: pw.FontWeight.bold,
          color: brandNavy,
        ),
      ),
    ],
  );

  static pw.Widget buildLabelValue(
    String label,
    String value, {
    pw.TextDirection? valueDirection,
    double labelWidth = 100,
    double fontSize = 10,
  }) {
    final direction = resolveTextDirection(value, preferred: valueDirection);
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4.5),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: labelWidth,
            child: pw.Padding(
              padding: const pw.EdgeInsets.only(left: 2, right: 4),
              child: pw.Text(
                label,
                textDirection: pw.TextDirection.rtl,
                textAlign: pw.TextAlign.start,
                overflow: pw.TextOverflow.visible,
                style: const pw.TextStyle(color: PdfColors.grey700),
              ),
            ),
          ),
          pw.SizedBox(width: 6),
          pw.Expanded(
            child: pw.Padding(
              padding: const pw.EdgeInsets.only(left: 3, right: 5),
              child: pw.Text(
                value,
                textDirection: direction,
                textAlign: direction == pw.TextDirection.rtl
                    ? pw.TextAlign.start
                    : pw.TextAlign.right,
                overflow: pw.TextOverflow.visible,
                style: pw.TextStyle(fontSize: fontSize, lineSpacing: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _signature(String title) => pw.Expanded(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          title,
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontWeight: pw.FontWeight.bold,
            fontSize: 9,
            color: brandNavy,
          ),
        ),
        pw.SizedBox(height: 24),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 12),
          child: pw.Container(height: 0.7, color: PdfColors.grey700),
        ),
      ],
    ),
  );

  static Future<void> printVoucher({
    required String voucherType,
    required int voucherNo,
    required String date,
    String? targetName,
    required double amount,
    String? paymentMethod,
    required String accountName,
    String? description,
    List<Map<String, dynamic>> journalLines = const [],
    List<Map<String, dynamic>> installmentAllocations = const [],
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
      journalLines: journalLines,
      installmentAllocations: installmentAllocations,
      isFinancialDocument: isFinancialDocument,
    );
    await printPdf(bytes, '${voucherType}_$voucherNo');
  }
}
