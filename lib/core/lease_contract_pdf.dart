import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'print_utils.dart';

/// Builds the exact, two-page Arabic lease form supplied by the company.
/// Data is passed from the selected property owner, tenant, unit and contract;
/// the letterhead, logo and footer are bundled app assets (never remote URLs).
class LeaseContractPdf {
  static const _defaultOwnerName = 'عبدالله محمد أحمد النقيب';
  static const _defaultOwnerIdentity = '1029836135';
  static const _defaultOwnerIdentityDate = '1998/01/17';
  static const _defaultOwnerIdentitySource = 'البيت';

  static const List<String> _clauses = [
    'لا يجوز للطرف الثاني أن يؤجر العقار بهذا العقد لأي شخص من جانبه.',
    'الطرف الأول غير ملزم بأي تعويض عما قد يقوم به الطرف الثاني من إصلاح أو تحسين في العقار المؤجر.',
    'عند رغبة أحد الطرفين في إخلاء العقار المؤجر فيجب إبلاغ الطرف الآخر قبل ذلك بمدة شهرين كتابياً ولأي سبب من الأسباب، وبدون معارضة من الطرف الثاني إذا كانت الرغبة من الطرف الأول.',
    'على الطرف الثاني التحلي بالأخلاق الحميدة مع من يشتركون معه في المبنى، وعدم صدور أي شكاوى من قبل جيرانه لتعريضهم لأي أذى من قبله.',
    'عند خروج الطرف الثاني من العقار عليه إصلاح أو دفع قيمة الإصلاح لأي تلف حصل في العقار نتيجة استعماله خلال فترة استئجاره.',
    'على الطرف الثاني عدم ترك أي نوع من المتروكات أو الأثاث التالف أو البضاعة خارج حدود العقار المؤجر له، مثل مدخل العمارة أو السلم أو السطح أو ارتدادات العقار أو الرصيف.',
    'قراءة عداد الكهرباء عند بدء الإيجار.',
    'حرر هذا العقد من نسختين، مع كل طرف نسخة، والتزم الطرفان باحترام بنوده كاملة، والله الموفق.',
  ];

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
    final contractId = _value(contract['id']);
    final date = DateFormat('yyyy/MM/dd').format(DateTime.now());
    final startDate = _formatDate(contract['start_date']);
    final endDate = _formatDate(contract['end_date']);
    final rent = (contract['rent_amount'] as num?)?.toDouble() ?? 0;
    final rentDigits = NumberFormat('#,##0.00', 'en_US').format(rent);
    final purpose = _value(contract['purpose'], fallback: 'سكني');
    final propertyAddress = [
      _value(property['address'], fallback: ''),
      _value(cityName, fallback: ''),
      'العقار ${_value(property['name'])}',
      'الوحدة ${_value(unit['unit_number'])}',
    ].where((part) => part.trim().isNotEmpty).join(' - ');
    final unitType = _value(unitTypeName, fallback: '........................');
    final ownerName = _value(owner['name'], fallback: _defaultOwnerName);
    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageTheme: _pageTheme(theme),
        build: (_) => _pageFrame(
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              PrintUtils.buildHeader(companyInfo, false),
              pw.SizedBox(height: 2),
              _metadata(contractId, date),
              pw.SizedBox(height: 4),
              pw.Center(
                child: pw.Text(
                  'عقد إيجار',
                  textDirection: pw.TextDirection.rtl,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    fontSize: 18,
                    fontWeight: pw.FontWeight.bold,
                    decoration: pw.TextDecoration.underline,
                  ),
                ),
              ),
              pw.SizedBox(height: 7),
              _sectionTitle('١. الطرف الأول (المؤجر)'),
              _line('الاسم: $ownerName   —   الصفة: المالك / الوكيل الشرعي'),
              _line(
                'رقم الهوية: ${_value(owner['identity_number'], fallback: _defaultOwnerIdentity)}   تاريخها: ${_value(owner['identity_issue_date'], fallback: _defaultOwnerIdentityDate)}   مصدرها: ${_value(owner['identity_source'], fallback: _defaultOwnerIdentitySource)}',
              ),
              pw.SizedBox(height: 3),
              _sectionTitle('٢. الطرف الثاني (المستأجر)'),
              _line('الاسم: ${_value(tenant['name'])}'),
              _line(
                'رقم الهوية: ${_value(tenant['identity_number'])}   تاريخها: ${_value(tenant['identity_issue_date'])}   مصدرها: ${_value(tenant['identity_source'])}',
              ),
              _line(
                'رقم الهاتف: ${_value(tenant['mobile'])}   المهنة: ${_value(tenant['profession'])}',
              ),
              pw.SizedBox(height: 4),
              _clause(
                '٣',
                'مقدار الإيجار: $rentDigits ريال سعودي فقط، كتابة: ${_amountInWords(rent)} ريال سعودي فقط لا غير.',
              ),
              _clause('٤', 'مدة الإيجار: من $startDate إلى $endDate.'),
              _clause(
                '٥',
                'طريقة دفع الإيجار: ${_value(contract['payment_method'])}.',
              ),
              _clause(
                '٦',
                'نوع العقار المستأجر والغرض من استئجاره: $unitType / $purpose.',
              ),
              _clause('٧', 'عنوان العقار المستأجر: $propertyAddress.'),
              for (var i = 0; i < _clauses.length; i++)
                _clause(
                  '${i + 8}',
                  i == 6
                      ? 'قراءة عداد الكهرباء عند بدء الإيجار: ${_value(contract['electricity_reading'])}.'
                      : _clauses[i],
                ),
              pw.Spacer(),
              PrintUtils.buildFooter(companyInfo),
            ],
          ),
        ),
      ),
    );

    pdf.addPage(
      pw.Page(
        pageTheme: _pageTheme(theme),
        build: (_) => _pageFrame(
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              PrintUtils.buildHeader(companyInfo, false),
              pw.SizedBox(height: 2),
              _metadata(contractId, date),
              pw.SizedBox(height: 38),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  _signatureColumn('الطرف الثاني المستأجر'),
                  _signatureColumn('الختم الرسمي'),
                  _signatureColumn('الطرف الأول المؤجر'),
                ],
              ),
              pw.Spacer(),
              PrintUtils.buildFooter(companyInfo),
            ],
          ),
        ),
      ),
    );

    return pdf.save();
  }

  static pw.PageTheme _pageTheme(pw.ThemeData theme) => pw.PageTheme(
    pageFormat: PdfPageFormat.a4,
    textDirection: pw.TextDirection.rtl,
    theme: theme,
    margin: const pw.EdgeInsets.fromLTRB(26, 22, 26, 22),
    buildBackground: (_) => pw.Stack(
      children: [
        PrintUtils.buildWatermark(null),
        pw.Positioned.fill(
          child: pw.Padding(
            padding: const pw.EdgeInsets.all(18),
            child: pw.Container(
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey600, width: 0.55),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  static pw.Widget _pageFrame(pw.Widget child) => pw.Padding(
    padding: const pw.EdgeInsets.fromLTRB(8, 5, 8, 13),
    child: child,
  );

  static pw.Widget _metadata(String number, String date) => pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [
      _line('رقم العقد: $number', size: 8),
      _line('التاريخ: $date', size: 8),
    ],
  );

  static pw.Widget _sectionTitle(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 2, bottom: 1),
    child: pw.Text(
      text,
      textDirection: pw.TextDirection.rtl,
      textAlign: pw.TextAlign.right,
      style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
    ),
  );

  static pw.Widget _line(String text, {double size = 13}) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 3),
    child: pw.Text(
      text,
      textDirection: pw.TextDirection.rtl,
      textAlign: pw.TextAlign.right,
      style: pw.TextStyle(fontSize: size, lineSpacing: 3),
    ),
  );

  static pw.Widget _clause(String number, String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 5),
    child: pw.Text(
      '$number. $text',
      textDirection: pw.TextDirection.rtl,
      textAlign: pw.TextAlign.right,
      style: const pw.TextStyle(fontSize: 12.5, lineSpacing: 3),
    ),
  );

  static pw.Widget _signatureColumn(String label) => pw.Expanded(
    child: pw.Column(
      children: [
        pw.Text(
          label,
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.center,
          style: const pw.TextStyle(fontSize: 10),
        ),
        pw.SizedBox(height: 31),
        pw.Container(height: 0.65, color: PdfColors.grey700),
      ],
    ),
  );

  static String _value(
    Object? value, {
    String fallback = '....................',
  }) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? fallback : text;
  }

  static String _formatDate(Object? raw) {
    final parsed = DateTime.tryParse(raw?.toString() ?? '');
    return parsed == null
        ? _value(raw)
        : DateFormat('yyyy/MM/dd').format(parsed);
  }

  static String _amountInWords(double amount) {
    final cents = (amount.abs() * 100).round();
    final riyals = cents ~/ 100;
    final halalas = cents % 100;
    final riyalsText = _integerInWords(riyals);
    if (halalas == 0) return riyalsText;
    return '$riyalsText و${_integerInWords(halalas)} هللة';
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
