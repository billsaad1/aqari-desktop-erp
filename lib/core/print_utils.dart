import 'dart:io';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../database/database_helper.dart';

class PrintUtils {

  static pw.Widget buildHeader(Map<String, dynamic>? info, bool isFinancialDocument) {
    final String nameAr = info?['name_ar'] ?? 'مؤسسة عبدالله النقيب التجارية';
    final String? nameEn = info?['name_en'];
    final String? activityAr = info?['activity_name_ar'];
    final String? activityEn = info?['activity_name_en'];
    final String? cr = info?['commercial_register'];
    final String? vat = info?['tax_number'];
    final String? logoPath = info?['logo_path'];

    return pw.Column(
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            // Right Section (Arabic)
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(nameAr, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                  if (activityAr != null && activityAr.isNotEmpty) pw.Text(activityAr, style: const pw.TextStyle(fontSize: 10)),
                  if (isFinancialDocument && cr != null && cr.isNotEmpty) pw.Text('س.ت: $cr', style: const pw.TextStyle(fontSize: 10)),
                  if (isFinancialDocument && vat != null && vat.isNotEmpty) pw.Text('الرقم الضريبي: $vat', style: const pw.TextStyle(fontSize: 10)),
                ],
              ),
            ),

            // Center Section (Logo)
            if (logoPath != null && logoPath.isNotEmpty && File(logoPath).existsSync())
              pw.Container(
                width: 80,
                alignment: pw.Alignment.center,
                child: pw.Image(
                  pw.MemoryImage(File(logoPath).readAsBytesSync()),
                  height: 60,
                  fit: pw.BoxFit.contain,
                ),
              )
            else
              pw.Container(width: 80),

            // Left Section (English)
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  if (nameEn != null && nameEn.isNotEmpty) pw.Text(nameEn, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold), textDirection: pw.TextDirection.ltr),
                  if (activityEn != null && activityEn.isNotEmpty) pw.Text(activityEn, style: const pw.TextStyle(fontSize: 10), textDirection: pw.TextDirection.ltr),
                  if (isFinancialDocument && cr != null && cr.isNotEmpty) pw.Text('C.R: $cr', style: const pw.TextStyle(fontSize: 10), textDirection: pw.TextDirection.ltr),
                  if (isFinancialDocument && vat != null && vat.isNotEmpty) pw.Text('VAT: $vat', style: const pw.TextStyle(fontSize: 10), textDirection: pw.TextDirection.ltr),
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 5),
        pw.Divider(thickness: 1.5),
      ],
    );
  }

  static pw.Widget buildFooter(Map<String, dynamic>? info) {
    final String? addressAr = info?['address_ar'] ?? info?['address']; // Fallback
    final String? addressEn = info?['address_en'];
    final String? poBox = info?['po_box'];
    final String? tel = info?['telephone'];
    final String? fax = info?['fax'];
    final String? mobile = info?['mobile'];

    List<String> arParts = [];
    List<String> enParts = [];

    if (addressAr != null && addressAr.isNotEmpty) arParts.add('العنوان: $addressAr');
    if (poBox != null && poBox.isNotEmpty) {
      arParts.add('ص.ب: $poBox');
      enParts.add('P.O.Box: $poBox');
    }
    if (tel != null && tel.isNotEmpty) {
      arParts.add('تليفون: $tel');
      enParts.add('Tel: $tel');
    }
    if (fax != null && fax.isNotEmpty) {
      arParts.add('فاكس: $fax');
      enParts.add('Fax: $fax');
    }
    if (mobile != null && mobile.isNotEmpty) {
      arParts.add('جوال: $mobile');
      enParts.add('Mob: $mobile');
    }
    if (addressEn != null && addressEn.isNotEmpty) enParts.insert(0, 'Address: $addressEn');

    return pw.Column(
      children: [
        pw.Divider(thickness: 1.0, color: PdfColors.grey),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Expanded(
              child: pw.Text(
                arParts.join(' - '),
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
                textAlign: pw.TextAlign.right,
              ),
            ),
            pw.SizedBox(width: 10),
            pw.Expanded(
              child: pw.Text(
                enParts.join(' - '),
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
                textAlign: pw.TextAlign.left,
                textDirection: pw.TextDirection.ltr,
              ),
            ),
          ],
        ),
      ]
    );
  }

  static pw.Widget buildWatermark(Map<String, dynamic>? info) {
    final String? logoPath = info?['logo_path'];
    if (logoPath != null && logoPath.isNotEmpty && File(logoPath).existsSync()) {
      return pw.Center(
        child: pw.Opacity(
          opacity: 0.1,
          child: pw.Image(
            pw.MemoryImage(File(logoPath).readAsBytesSync()),
            width: 300,
          ),
        ),
      );
    }
    return pw.Container();
  }

  static Future<void> printVoucher({
    required String voucherType, // 'سند قبض' or 'سند صرف'
    required int voucherNo,
    required String date,
    required String targetName,
    required double amount,
    required String paymentMethod,
    required String accountName,
    bool isFinancialDocument = true,
  }) async {
    // 1. Fetch Company Info
    final companyInfo = await DatabaseHelper.instance.getCompanyInfo();

    // 2. Setup Fonts
    final fontData = await rootBundle.load("assets/fonts/Cairo-Regular.ttf").catchError((_) => ByteData.view(Uint8List(0).buffer));
    final ttf = fontData.lengthInBytes > 0 ? pw.Font.ttf(fontData) : pw.Font.helvetica();
    final fontBoldData = await rootBundle.load("assets/fonts/Cairo-Bold.ttf").catchError((_) => ByteData.view(Uint8List(0).buffer));
    final ttfBold = fontBoldData.lengthInBytes > 0 ? pw.Font.ttf(fontBoldData) : pw.Font.helveticaBold();

    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a5.landscape,
        textDirection: pw.TextDirection.rtl,
        theme: pw.ThemeData.withFont(base: ttf, bold: ttfBold),
        build: (pw.Context context) {
          return pw.Container(
            padding: const pw.EdgeInsets.all(10),
            // decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey, width: 2)), // Removed outer border to make it look like official letterhead
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                buildHeader(companyInfo, isFinancialDocument),
                pw.SizedBox(height: 10),
                // Title
                pw.Center(
                  child: pw.Text(voucherType, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, decoration: pw.TextDecoration.underline)),
                ),
                pw.SizedBox(height: 15),
                // Voucher Details
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('رقم السند: $voucherNo', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
                    pw.Text('التاريخ: $date', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
                  ],
                ),
                pw.SizedBox(height: 15),
                pw.Container(
                  padding: const pw.EdgeInsets.all(10),
                  color: PdfColors.grey100,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('${voucherType == 'سند قبض' ? 'استلمنا من السيد/ة' : 'صرفنا للسيد/ة'}: $targetName', style: const pw.TextStyle(fontSize: 14)),
                      pw.SizedBox(height: 8),
                      pw.Text('مبلغاً وقدره: $amount ريال', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                      pw.SizedBox(height: 8),
                      pw.Text('وذلك عن: سداد دفعة إيجارية', style: const pw.TextStyle(fontSize: 14)),
                      pw.SizedBox(height: 8),
                      pw.Text('طريقة الدفع: $paymentMethod ($accountName)', style: const pw.TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
                pw.Spacer(),
                // Signatures
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      children: [
                        pw.Text('توقيع المحاسب', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
                        pw.SizedBox(height: 25),
                        pw.Text('____________________'),
                      ]
                    ),
                    pw.Column(
                      children: [
                        pw.Text('الختم الرسمي', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
                        pw.SizedBox(height: 25),
                        pw.Text('____________________'),
                      ]
                    ),
                    pw.Column(
                      children: [
                        pw.Text('توقيع المستلم', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
                        pw.SizedBox(height: 25),
                        pw.Text('____________________'),
                      ]
                    ),
                  ]
                ),
                pw.Spacer(),
                buildFooter(companyInfo),
              ],
            ),
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
      name: '${voucherType}_$voucherNo',
    );
  }
}
