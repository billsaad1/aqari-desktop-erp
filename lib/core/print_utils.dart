import 'dart:io';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../database/database_helper.dart';

class PrintUtils {
  static Future<void> printVoucher({
    required String voucherType, // 'سند قبض' or 'سند صرف'
    required int voucherNo,
    required String date,
    required String targetName,
    required double amount,
    required String paymentMethod,
    required String accountName,
  }) async {
    // 1. Fetch Company Info
    final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
    final String companyName = companyInfo?['name_ar'] ?? 'مؤسسة عبدالله النقيب التجارية';
    final String companyAddress = companyInfo?['address'] ?? '';
    final String companyTax = companyInfo?['tax_number'] ?? '';
    final String? logoPath = companyInfo?['logo_path'];

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
            decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey, width: 2)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                // Header (Letterhead)
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(companyName, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                        pw.Text('العنوان: $companyAddress', style: const pw.TextStyle(fontSize: 10)),
                        if (companyTax.isNotEmpty) pw.Text('الرقم الضريبي: $companyTax', style: const pw.TextStyle(fontSize: 10)),
                      ],
                    ),
                    if (logoPath != null && logoPath.isNotEmpty && File(logoPath).existsSync())
                      pw.Image(
                        pw.MemoryImage(File(logoPath).readAsBytesSync()),
                        width: 60,
                        height: 60,
                      )
                  ],
                ),
                pw.Divider(thickness: 1.5),
                pw.SizedBox(height: 5),
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
                )
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
