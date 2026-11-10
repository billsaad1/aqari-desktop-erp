import "../../core/print_utils.dart";
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../providers/leasing_provider.dart';
import '../../providers/accounting_provider.dart';
import '../../database/database_helper.dart';

class TaxInvoiceScreen extends StatefulWidget {
  const TaxInvoiceScreen({super.key});

  @override
  State<TaxInvoiceScreen> createState() => _TaxInvoiceScreenState();
}

class _TaxInvoiceScreenState extends State<TaxInvoiceScreen> {
  final _formKey = GlobalKey<FormState>();

  int? _selectedContractId;
  int? _selectedTenantId;
  int? _revenueAccountId;
  int? _taxAccountId;
  bool _isProcessing = false;

  final _dateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  final _netAmountController = TextEditingController();
  final _taxAmountController = TextEditingController();
  final _grossAmountController = TextEditingController();

  void _calculateGross() {
    double net = double.tryParse(_netAmountController.text) ?? 0.0;
    double tax = double.tryParse(_taxAmountController.text) ?? 0.0;
    _grossAmountController.text = (net + tax).toStringAsFixed(2);
  }

  @override
  void dispose() {
    _dateController.dispose();
    _netAmountController.dispose();
    _taxAmountController.dispose();
    _grossAmountController.dispose();
    super.dispose();
  }

  Future<void> _processInvoice({required bool saveAsPdf}) async {
    if (_isProcessing) return;
    if (!_formKey.currentState!.validate() ||
        _selectedContractId == null ||
        _selectedTenantId == null ||
        _revenueAccountId == null ||
        _taxAccountId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء تعبئة جميع الحقول المطلوبة')),
      );
      return;
    }
    final net = double.tryParse(_netAmountController.text) ?? 0.0;
    final tax = double.tryParse(_taxAmountController.text) ?? 0.0;
    if (net <= 0 ||
        tax < 0 ||
        DateTime.tryParse(_dateController.text) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تحقق من مبلغ وتاريخ الفاتورة')),
      );
      return;
    }

    final contractId = _selectedContractId!;
    final tenantId = _selectedTenantId!;
    final revenueAccountId = _revenueAccountId!;
    final taxAccountId = _taxAccountId!;
    final invoiceDate = _dateController.text;
    final leasingProvider = Provider.of<LeasingProvider>(
      context,
      listen: false,
    );
    final accountingProvider = Provider.of<AccountingProvider>(
      context,
      listen: false,
    );
    final tenantName = leasingProvider.tenants
        .firstWhere((t) => t['id'] == tenantId)['name']
        .toString();

    setState(() => _isProcessing = true);
    late final int invoiceId;
    try {
      invoiceId = await DatabaseHelper.instance.insertTaxInvoice(
        contractId: contractId,
        tenantId: tenantId,
        invoiceDate: invoiceDate,
        totalAmount: net,
        taxAmount: tax,
        revenueAccountId: revenueAccountId,
        taxAccountId: taxAccountId,
      );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر إصدار الفاتورة: $e')));
      if (mounted) setState(() => _isProcessing = false);
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم إصدار الفاتورة رقم $invoiceId وترحيل القيد')),
    );
    try {
      final printMessage = await _printInvoice(
        invoiceNo: invoiceId,
        contractNo: contractId,
        tenantName: tenantName,
        net: net,
        tax: tax,
        gross: net + tax,
        date: invoiceDate,
        saveAsPdf: saveAsPdf,
      );
      if (mounted && printMessage != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تم إصدار الفاتورة رقم $invoiceId. $printMessage'),
          ),
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'صدرت الفاتورة رقم $invoiceId، لكن تعذر تجهيز المستند: $e',
            ),
          ),
        );
    }
    await accountingProvider.loadAccounts();
    if (mounted) {
      _netAmountController.clear();
      _taxAmountController.clear();
      _grossAmountController.clear();
      setState(() => _isProcessing = false);
    }
  }

  Future<String?> _printInvoice({
    required int invoiceNo,
    required int contractNo,
    required String tenantName,
    required double net,
    required double tax,
    required double gross,
    required String date,
    required bool saveAsPdf,
  }) async {
    final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
    final String companyTax = companyInfo?['tax_number'] ?? '';
    final String companyName =
        companyInfo?['name_ar'] ?? 'مؤسسة عبدالله النقيب التجارية';
    final currency = companyInfo?['default_currency']?.toString() ?? 'ريال';

    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    pdf.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          buildBackground: (pw.Context context) =>
              PrintUtils.buildWatermark(companyInfo),
        ),
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        theme: theme,
        header: (_) => PrintUtils.buildHeader(companyInfo, true),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'فاتورة ضريبية',
              textDirection: pw.TextDirection.rtl,
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 16),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'رقم الفاتورة: $invoiceNo',
                textDirection: pw.TextDirection.rtl,
              ),
              pw.Text('التاريخ: $date', textDirection: pw.TextDirection.rtl),
            ],
          ),
          pw.Text(
            'رقم العقد: $contractNo',
            textDirection: pw.TextDirection.rtl,
          ),
          pw.Text(
            'العميل / المستأجر: $tenantName',
            textDirection: pw.TextDirection.rtl,
          ),
          pw.Text(
            'الرقم الضريبي للمنشأة: $companyTax',
            textDirection: pw.TextDirection.rtl,
          ),
          pw.SizedBox(height: 24),
          pw.TableHelper.fromTextArray(
            headers: ['الوصف', 'المبلغ'],
            data: [
              ['قيمة الإيجار (الصافي)', '${net.toStringAsFixed(2)} $currency'],
              [
                'ضريبة القيمة المضافة (VAT)',
                '${tax.toStringAsFixed(2)} $currency',
              ],
              ['الإجمالي مستحق الدفع', '${gross.toStringAsFixed(2)} $currency'],
            ],
            headerStyle: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: const pw.BoxDecoration(
              color: PdfColors.blueGrey800,
            ),
            cellStyle: const pw.TextStyle(fontSize: 10),
          ),
          pw.SizedBox(height: 32),
          pw.Center(
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(),
              data:
                  'Invoice: $invoiceNo\nSupplier: $companyName\nVAT: $companyTax\nTenant: $tenantName\nNet: ${net.toStringAsFixed(2)}\nTax: ${tax.toStringAsFixed(2)}\nTotal: ${gross.toStringAsFixed(2)}\nCurrency: $currency\nDate: $date',
              width: 90,
              height: 90,
            ),
          ),
          pw.SizedBox(height: 28),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                children: [
                  pw.Text('المحاسب'),
                  pw.SizedBox(height: 28),
                  pw.Text('________________'),
                ],
              ),
              pw.Column(
                children: [
                  pw.Text('استلمت أصل الفاتورة'),
                  pw.SizedBox(height: 28),
                  pw.Text('________________'),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    final bytes = await pdf.save();
    try {
      if (saveAsPdf) {
        final saved = await PrintUtils.savePdf(
          bytes,
          'فاتورة_ضريبية_$invoiceNo',
        );
        return saved ? PrintUtils.savedPdfMessage : 'أُلغي حفظ ملف PDF';
      }
      await PrintUtils.printPdf(bytes, 'فاتورة_ضريبية_$invoiceNo');
      return null;
    } catch (e) {
      return 'تعذر تجهيز/طباعة المستند: $e';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<LeasingProvider, AccountingProvider>(
      builder: (context, leasingProv, accProv, child) {
        if (leasingProv.isLoading || accProv.isLoading)
          return const Center(child: CircularProgressIndicator());

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 800),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'إصدار فاتورة ضريبية',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _selectedContractId,
                            items: leasingProv.contracts
                                .map(
                                  (c) => DropdownMenuItem<int>(
                                    value: c['id'],
                                    child: Text('عقد رقم: ${c['id']}'),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              setState(() {
                                _selectedContractId = val;
                                // Auto select tenant
                                if (val != null) {
                                  final contract = leasingProv.contracts
                                      .firstWhere((c) => c['id'] == val);
                                  _selectedTenantId = contract['tenant_id'];
                                }
                              });
                            },
                            decoration: const InputDecoration(
                              labelText: 'اختر العقد المرتبط',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _selectedTenantId,
                            items: leasingProv.tenants
                                .map(
                                  (t) => DropdownMenuItem<int>(
                                    value: t['id'],
                                    child: Text(t['name']),
                                  ),
                                )
                                .toList(),
                            onChanged: null,
                            decoration: const InputDecoration(
                              labelText: 'المستأجر المرتبط بالعقد',
                              border: OutlineInputBorder(),
                            ),
                            // Disable if auto-selected via contract, but keep it readable
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _revenueAccountId,
                            items: accProv.accounts
                                .where(
                                  (a) =>
                                      a['account_type'] == 'Revenue' &&
                                      a['parent_id'] != null,
                                )
                                .map(
                                  (a) => DropdownMenuItem<int>(
                                    value: a['id'],
                                    child: Text('${a['code']} - ${a['name']}'),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) =>
                                setState(() => _revenueAccountId = val),
                            decoration: const InputDecoration(
                              labelText: 'حساب إيراد الإيجار (Credit)',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _taxAccountId,
                            items: accProv.accounts
                                .where(
                                  (a) =>
                                      a['account_type'] == 'Liability' &&
                                      a['parent_id'] != null,
                                )
                                .map(
                                  (a) => DropdownMenuItem<int>(
                                    value: a['id'],
                                    child: Text('${a['code']} - ${a['name']}'),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) =>
                                setState(() => _taxAccountId = val),
                            decoration: const InputDecoration(
                              labelText: 'حساب ضريبة القيمة المضافة (Credit)',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _dateController,
                      decoration: const InputDecoration(
                        labelText: 'تاريخ الفاتورة',
                        border: OutlineInputBorder(),
                      ),
                      readOnly: true,
                      onTap: () async {
                        final current =
                            DateTime.tryParse(_dateController.text) ??
                            DateTime.now();
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: current,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null && mounted)
                          setState(
                            () => _dateController.text = DateFormat(
                              'yyyy-MM-dd',
                            ).format(picked),
                          );
                      },
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _netAmountController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'المبلغ الصافي',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (val) => _calculateGross(),
                            validator: (v) {
                              final value = double.tryParse(v ?? '');
                              return value == null || value <= 0
                                  ? 'أدخل مبلغاً موجباً'
                                  : null;
                            },
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextFormField(
                            controller: _taxAmountController,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'مبلغ الضريبة',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (val) => _calculateGross(),
                            validator: (v) {
                              final value = double.tryParse(v ?? '');
                              return value == null || value < 0
                                  ? 'أدخل ضريبة صحيحة'
                                  : null;
                            },
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextFormField(
                            controller: _grossAmountController,
                            decoration: const InputDecoration(
                              labelText: 'الإجمالي (مع الضريبة)',
                              border: OutlineInputBorder(),
                            ),
                            readOnly: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isProcessing
                                ? null
                                : () => _processInvoice(saveAsPdf: false),
                            icon: const Icon(Icons.print),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.all(16),
                            ),
                            label: const Text('إصدار وترحيل وطباعة'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isProcessing
                                ? null
                                : () => _processInvoice(saveAsPdf: true),
                            icon: const Icon(Icons.picture_as_pdf),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.all(16),
                            ),
                            label: const Text('إصدار وحفظ PDF'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
