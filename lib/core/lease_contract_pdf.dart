import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'lease_contract_terms.dart';
import 'print_utils.dart';

/// Builds a data-driven Arabic lease document from the saved company settings
/// and the selected owner, tenant, property, unit and contract records.
class LeaseContractPdf {
  static Future<Uint8List> build({
    required Map<String, dynamic>? companyInfo,
    required Map<String, dynamic> contract,
    required Map<String, dynamic> owner,
    required Map<String, dynamic> tenant,
    required Map<String, dynamic> property,
    required Map<String, dynamic> unit,
    String? cityName,
    String? unitTypeName,
  }) async {
    final theme = await PrintUtils.loadArabicTheme();
    final contractId = _value(contract['id'], fallback: '—');
    final issueDate = DateFormat('yyyy/MM/dd').format(DateTime.now());
    final startDate = _formatDate(contract['start_date']);
    final endDate = _formatDate(contract['end_date']);
    final rent = (contract['rent_amount'] as num?)?.toDouble() ?? 0;
    final currency = PrintUtils.currencyInArabic(
      companyInfo?['default_currency'],
      fallback: 'عملة المنشأة',
    );
    final purpose = _value(contract['purpose'], fallback: 'غير محدد');
    final unitType = _value(unitTypeName, fallback: 'غير محدد');
    final clauses = LeaseContractTerms.resolve(
      companyInfo?['terms_conditions'],
    );
    final electricityReading = _value(
      contract['electricity_reading'],
      fallback: 'غير مدونة',
    );
    final ownerName = _value(owner['name'], fallback: 'غير محدد');
    final tenantName = _value(tenant['name'], fallback: 'غير محدد');
    final pdf = pw.Document();
    final documentPageTheme = PrintUtils.pageTheme(
      theme: theme,
      companyInfo: companyInfo,
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(28, 24, 28, 32),
    );

    pdf.addPage(
      pw.MultiPage(
        pageTheme: documentPageTheme,
        maxPages: 20,
        header: (_) => PrintUtils.buildHeader(companyInfo, false),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          _documentTitle('عقد إيجار'),
          _metadata(contractId, issueDate),
          pw.SizedBox(height: 7),
          _sectionTitle('بيانات الطرفين'),
          pw.SizedBox(height: 5),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: _partyCard(
                  number: 1,
                  title: 'الطرف الأول (المؤجر)',
                  fields: [
                    _field('الاسم', ownerName),
                    _field('الصفة', 'المالك / الوكيل الشرعي'),
                    _field(
                      'رقم الهوية',
                      _value(owner['identity_number'], fallback: 'غير مدون'),
                      valueDirection: pw.TextDirection.ltr,
                    ),
                    _field(
                      'تاريخ إصدار الهوية',
                      _formatOptionalDate(owner['identity_issue_date']),
                      valueDirection: pw.TextDirection.ltr,
                    ),
                    _field(
                      'جهة الإصدار',
                      _value(owner['identity_source'], fallback: 'غير مدون'),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: _partyCard(
                  number: 2,
                  title: 'الطرف الثاني (المستأجر)',
                  fields: [
                    _field('الاسم', tenantName),
                    if (_value(
                      tenant['nationality_name'],
                      fallback: '',
                    ).isNotEmpty)
                      _field('الجنسية', _value(tenant['nationality_name'])),
                    _field(
                      'رقم الهوية',
                      _value(tenant['identity_number'], fallback: 'غير مدون'),
                      valueDirection: pw.TextDirection.ltr,
                    ),
                    _field(
                      'تاريخ إصدار الهوية',
                      _formatOptionalDate(tenant['identity_issue_date']),
                      valueDirection: pw.TextDirection.ltr,
                    ),
                    _field(
                      'جهة الإصدار',
                      _value(tenant['identity_source'], fallback: 'غير مدون'),
                    ),
                    _field(
                      'رقم الهاتف',
                      _value(tenant['mobile'], fallback: 'غير مدون'),
                      valueDirection: pw.TextDirection.ltr,
                    ),
                    if (_value(tenant['profession'], fallback: '').isNotEmpty)
                      _field('المهنة', _value(tenant['profession'])),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 7),
          _sectionTitle('بيانات العين المؤجرة والاتفاق المالي'),
          pw.SizedBox(height: 5),
          _detailCard([
            _numberedItem(
              3,
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  _amountField(rent, currency),
                  _field(
                    'كتابةً',
                    formatAmountInWords(rent, companyInfo?['default_currency']),
                  ),
                ],
              ),
            ),
            _numberedItem(
              4,
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Text(
                    'مدة الإيجار',
                    textDirection: pw.TextDirection.rtl,
                    textAlign: pw.TextAlign.right,
                    style: const pw.TextStyle(
                      fontSize: 9,
                      color: PdfColors.grey700,
                    ),
                  ),
                  pw.Row(
                    children: [
                      pw.Expanded(
                        child: _field(
                          'من',
                          startDate,
                          valueDirection: pw.TextDirection.ltr,
                        ),
                      ),
                      pw.SizedBox(width: 8),
                      pw.Expanded(
                        child: _field(
                          'إلى',
                          endDate,
                          valueDirection: pw.TextDirection.ltr,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _numberedItem(
              5,
              _field(
                'طريقة دفع الإيجار',
                _value(contract['payment_method'], fallback: 'غير محددة'),
              ),
            ),
            _numberedItem(
              6,
              pw.Row(
                children: [
                  pw.Expanded(child: _field('نوع العقار', unitType)),
                  pw.SizedBox(width: 8),
                  pw.Expanded(child: _field('الغرض من الاستئجار', purpose)),
                ],
              ),
            ),
            _numberedItem(
              7,
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Row(
                    children: [
                      pw.Expanded(
                        child: _field(
                          'العقار',
                          _value(property['name'], fallback: 'غير محدد'),
                        ),
                      ),
                      pw.SizedBox(width: 8),
                      pw.Expanded(
                        child: _field(
                          'الوحدة',
                          _value(unit['unit_number'], fallback: 'غير محدد'),
                          valueDirection: pw.TextDirection.ltr,
                        ),
                      ),
                    ],
                  ),
                  _field(
                    'العنوان',
                    [
                      _value(property['address'], fallback: 'غير مدون'),
                      if (cityName != null && cityName.trim().isNotEmpty)
                        cityName.trim(),
                    ].join('، '),
                  ),
                ],
              ),
            ),
          ]),
          pw.SizedBox(height: 7),
          _sectionTitle('الشروط والأحكام'),
          pw.SizedBox(height: 2),
          for (var index = 0; index < clauses.length; index++)
            _clause(
              index + 8,
              clauses[index].contains('عداد الكهرباء')
                  ? '${clauses[index]} القراءة المسجلة: $electricityReading'
                  : clauses[index],
            ),
        ],
      ),
    );

    pdf.addPage(
      pw.Page(
        pageTheme: documentPageTheme,
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            PrintUtils.buildHeader(companyInfo, false),
            _documentTitle('اعتماد وتوقيعات الأطراف'),
            pw.SizedBox(height: 9),
            _metadata(contractId, issueDate),
            pw.SizedBox(height: 20),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: _signatureParty(
                    role: 'الطرف الثاني — المستأجر',
                    name: tenantName,
                    identity: _value(
                      tenant['identity_number'],
                      fallback: 'غير مدون',
                    ),
                  ),
                ),
                pw.SizedBox(width: 10),
                _stampArea(),
                pw.SizedBox(width: 10),
                pw.Expanded(
                  child: _signatureParty(
                    role: 'الطرف الأول — المؤجر',
                    name: ownerName,
                    identity: _value(
                      owner['identity_number'],
                      fallback: 'غير مدون',
                    ),
                  ),
                ),
              ],
            ),
            pw.Spacer(),
            pw.Container(height: 0.7, color: PrintUtils.softBorder),
            pw.SizedBox(height: 7),
            pw.Text(
              'توقيع الطرفين وختم المنشأة',
              textDirection: pw.TextDirection.rtl,
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 12),
            PrintUtils.buildFooter(companyInfo),
          ],
        ),
      ),
    );

    return pdf.save();
  }

  static pw.Widget _documentTitle(String title) => pw.Center(
    child: pw.Padding(
      padding: const pw.EdgeInsets.only(top: 4, bottom: 8),
      child: pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            title,
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontSize: 17,
              fontWeight: pw.FontWeight.bold,
              color: PrintUtils.brandNavy,
            ),
          ),
          pw.SizedBox(height: 5),
          pw.Container(width: 72, height: 2, color: PrintUtils.brandEmerald),
        ],
      ),
    ),
  );

  static pw.Widget _metadata(String number, String date) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: pw.BoxDecoration(
      color: PrintUtils.softSurface,
      border: pw.Border.all(color: PrintUtils.softBorder),
      borderRadius: pw.BorderRadius.circular(5),
    ),
    child: pw.Row(
      children: [
        pw.Expanded(
          child: _metadataItem('رقم العقد', number, pw.TextDirection.ltr),
        ),
        pw.SizedBox(width: 12),
        pw.Expanded(
          child: _metadataItem(
            'تاريخ إصدار النسخة',
            date,
            pw.TextDirection.ltr,
          ),
        ),
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
          color: PrintUtils.brandNavy,
        ),
      ),
    ],
  );

  static pw.Widget _sectionTitle(String text) => pw.Container(
    padding: const pw.EdgeInsets.only(bottom: 4),
    decoration: const pw.BoxDecoration(
      border: pw.Border(
        bottom: pw.BorderSide(color: PrintUtils.brandEmerald, width: 1),
      ),
    ),
    child: pw.Text(
      text,
      textDirection: pw.TextDirection.rtl,
      textAlign: pw.TextAlign.right,
      style: pw.TextStyle(
        fontSize: 11.5,
        fontWeight: pw.FontWeight.bold,
        color: PrintUtils.brandNavy,
      ),
    ),
  );

  static pw.Widget _partyCard({
    required int number,
    required String title,
    required List<pw.Widget> fields,
  }) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PrintUtils.softBorder),
      borderRadius: pw.BorderRadius.circular(5),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          height: 15,
          child: pw.Stack(
            children: [
              pw.Positioned(
                top: 0,
                right: 0,
                child: pw.Container(
                  width: 22,
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text(
                    '$number.',
                    textDirection: pw.TextDirection.ltr,
                    textAlign: pw.TextAlign.right,
                    style: pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                      color: PrintUtils.brandEmerald,
                    ),
                  ),
                ),
              ),
              pw.Positioned(
                top: 0,
                left: 0,
                right: 26,
                child: pw.Text(
                  title,
                  textDirection: pw.TextDirection.rtl,
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                    color: PrintUtils.brandEmerald,
                  ),
                ),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 2),
        ...fields,
      ],
    ),
  );

  static pw.Widget _detailCard(List<pw.Widget> fields) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: pw.BoxDecoration(
      color: PrintUtils.softSurface,
      border: pw.Border.all(color: PrintUtils.softBorder),
      borderRadius: pw.BorderRadius.circular(5),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: fields,
    ),
  );

  static pw.Widget _field(
    String label,
    String value, {
    pw.TextDirection valueDirection = pw.TextDirection.rtl,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1.2),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          width: 112,
          child: pw.Text(
            label,
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.right,
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
        ),
        pw.SizedBox(width: 7),
        pw.Expanded(
          child: pw.Text(
            value,
            textDirection: valueDirection,
            textAlign: pw.TextAlign.right,
            style: const pw.TextStyle(fontSize: 9.5),
          ),
        ),
      ],
    ),
  );

  static pw.Widget _numberedItem(int number, pw.Widget child) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          width: 22,
          alignment: pw.Alignment.topRight,
          child: pw.Text(
            '${_arabicDigits(number.toString())}.',
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.right,
            style: pw.TextStyle(
              fontSize: 9.5,
              fontWeight: pw.FontWeight.bold,
              color: PrintUtils.brandEmerald,
            ),
          ),
        ),
        pw.SizedBox(width: 4),
        pw.Expanded(child: child),
      ],
    ),
  );

  static pw.Widget _amountField(double amount, String currency) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1.2),
    child: pw.Row(
      children: [
        pw.SizedBox(
          width: 112,
          child: pw.Text(
            'مقدار الإيجار رقماً',
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.right,
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
        ),
        pw.SizedBox(width: 7),
        pw.Expanded(
          child: pw.Row(
            children: [
              pw.Text(
                PrintUtils.formatPdfAmount(amount),
                textDirection: pw.TextDirection.ltr,
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: PrintUtils.brandNavy,
                ),
              ),
              pw.SizedBox(width: 5),
              pw.Text(
                currency,
                textDirection: pw.TextDirection.rtl,
                style: const pw.TextStyle(fontSize: 9.5),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  static pw.Widget _clause(int number, String text) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Container(
          width: 22,
          alignment: pw.Alignment.topRight,
          child: pw.Text(
            '${_arabicDigits(number.toString())}.',
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.right,
            style: pw.TextStyle(
              fontSize: 9.5,
              fontWeight: pw.FontWeight.bold,
              color: PrintUtils.brandEmerald,
            ),
          ),
        ),
        pw.SizedBox(width: 5),
        pw.Expanded(
          child: pw.Text(
            text,
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.right,
            style: const pw.TextStyle(fontSize: 9.5, lineSpacing: 3),
          ),
        ),
      ],
    ),
  );

  static pw.Widget _signatureParty({
    required String role,
    required String name,
    required String identity,
  }) => pw.Container(
    height: 205,
    padding: const pw.EdgeInsets.all(11),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PrintUtils.softBorder),
      borderRadius: pw.BorderRadius.circular(6),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          role,
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.right,
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: pw.FontWeight.bold,
            color: PrintUtils.brandNavy,
          ),
        ),
        pw.SizedBox(height: 13),
        _signatureInfo('الاسم', name, pw.TextDirection.rtl),
        pw.SizedBox(height: 6),
        _signatureInfo('رقم الهوية', identity, pw.TextDirection.ltr),
        pw.Spacer(),
        pw.Text(
          'التوقيع',
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.right,
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 3),
        pw.Container(height: 0.8, color: PdfColors.grey700),
        pw.SizedBox(height: 12),
        pw.Row(
          children: [
            pw.Text(
              'تاريخ التوقيع',
              textDirection: pw.TextDirection.rtl,
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            ),
            pw.SizedBox(width: 5),
            pw.Expanded(
              child: pw.Container(height: 0.6, color: PrintUtils.softBorder),
            ),
          ],
        ),
      ],
    ),
  );

  static pw.Widget _signatureInfo(
    String label,
    String value,
    pw.TextDirection direction,
  ) => pw.Row(
    children: [
      pw.Text(
        '$label: ',
        textDirection: pw.TextDirection.rtl,
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
      ),
      pw.Expanded(
        child: pw.Text(
          value,
          textDirection: direction,
          textAlign: pw.TextAlign.right,
          style: const pw.TextStyle(fontSize: 8.5),
        ),
      ),
    ],
  );

  static pw.Widget _stampArea() => pw.Container(
    width: 102,
    height: 150,
    alignment: pw.Alignment.center,
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PrintUtils.softBorder, width: 0.8),
      borderRadius: pw.BorderRadius.circular(6),
    ),
    child: pw.Text(
      'الختم الرسمي',
      textDirection: pw.TextDirection.rtl,
      textAlign: pw.TextAlign.center,
      style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
    ),
  );

  static String _value(Object? value, {String fallback = 'غير مدون'}) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? fallback : text;
  }

  static String _formatDate(Object? raw) {
    final parsed = DateTime.tryParse(raw?.toString() ?? '');
    return parsed == null
        ? _value(raw)
        : DateFormat('yyyy/MM/dd').format(parsed);
  }

  static String _formatOptionalDate(Object? raw) {
    if (raw == null || raw.toString().trim().isEmpty) return 'غير مدون';
    return _formatDate(raw);
  }

  static String _arabicDigits(String value) => value.replaceAllMapped(
    RegExp(r'\d'),
    (match) => String.fromCharCode(0x0660 + int.parse(match.group(0)!)),
  );

  static String formatAmountInWords(double amount, Object? rawCurrency) {
    final currency = PrintUtils.currencyInArabic(
      rawCurrency,
      fallback: 'عملة المنشأة',
    );
    return _amountInWords(amount, currency);
  }

  static String _amountInWords(double amount, String currency) {
    final cents = (amount.abs() * 100).round();
    final majorUnits = cents ~/ 100;
    final minorUnits = cents % 100;
    final majorText = '${_integerInWords(majorUnits)} $currency';
    if (minorUnits == 0) return majorText;
    return '$majorText و${_integerInWords(minorUnits)} ${_fractionName(currency)}';
  }

  static String _fractionName(String currency) {
    if (currency.contains('سعودي')) return 'هللة';
    if (currency.contains('دولار') || currency == 'يورو') return 'سنت';
    if (currency.contains('كويتي') ||
        currency.contains('إماراتي') ||
        currency.contains('بحريني') ||
        currency.contains('يمني')) {
      return 'فلس';
    }
    if (currency.contains('عماني')) return 'بيسة';
    if (currency.contains('قطري')) return 'درهم';
    if (currency.contains('مصري')) return 'قرش';
    return 'جزء من مئة $currency';
  }

  static String _integerInWords(int value) {
    if (value == 0) return 'صفر';
    if (value < 0) return 'سالب ${_integerInWords(-value)}';
    const scales = ['', 'ألف', 'مليون', 'مليار', 'تريليون'];
    const pluralScales = ['', 'آلاف', 'ملايين', 'مليارات', 'تريليونات'];
    final groups = <int>[];
    var remaining = value;
    while (remaining > 0) {
      groups.add(remaining % 1000);
      remaining ~/= 1000;
    }
    if (groups.length > scales.length) return value.toString();
    final words = <String>[];
    for (var i = groups.length - 1; i >= 0; i--) {
      final group = groups[i];
      if (group == 0) continue;
      if (i == 0) {
        words.add(_underThousand(group));
      } else if (group == 1) {
        words.add(scales[i]);
      } else if (group == 2) {
        words.add('${scales[i]}ان');
      } else if (group <= 10) {
        words.add('${_underThousand(group)} ${pluralScales[i]}');
      } else {
        words.add('${_underThousand(group)} ${scales[i]}');
      }
    }
    return words.join(' و');
  }

  static String _underThousand(int value) {
    const ones = [
      '',
      'واحد',
      'اثنان',
      'ثلاثة',
      'أربعة',
      'خمسة',
      'ستة',
      'سبعة',
      'ثمانية',
      'تسعة',
      'عشرة',
      'أحد عشر',
      'اثنا عشر',
      'ثلاثة عشر',
      'أربعة عشر',
      'خمسة عشر',
      'ستة عشر',
      'سبعة عشر',
      'ثمانية عشر',
      'تسعة عشر',
    ];
    const tens = [
      '',
      '',
      'عشرون',
      'ثلاثون',
      'أربعون',
      'خمسون',
      'ستون',
      'سبعون',
      'ثمانون',
      'تسعون',
    ];
    const hundreds = [
      '',
      'مئة',
      'مئتان',
      'ثلاثمئة',
      'أربعمئة',
      'خمسمئة',
      'ستمئة',
      'سبعمئة',
      'ثمانمئة',
      'تسعمئة',
    ];
    final parts = <String>[];
    final hundredsValue = value ~/ 100;
    final remainder = value % 100;
    if (hundredsValue > 0) parts.add(hundreds[hundredsValue]);
    if (remainder > 0) {
      if (remainder < 20) {
        parts.add(ones[remainder]);
      } else {
        final unit = remainder % 10;
        final ten = remainder ~/ 10;
        parts.add(unit == 0 ? tens[ten] : '${ones[unit]} و${tens[ten]}');
      }
    }
    return parts.join(' و');
  }
}
