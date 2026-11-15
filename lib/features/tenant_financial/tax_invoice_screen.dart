import "../../core/print_utils.dart";
import '../../core/pdf_preview_dialog.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import '../../providers/leasing_provider.dart';
import '../../providers/accounting_provider.dart';
import '../../database/database_helper.dart';
import '../../core/internal_tax.dart';
import '../../core/permission_policy.dart';

class TaxInvoiceScreen extends StatefulWidget {
  const TaxInvoiceScreen({super.key});

  @override
  State<TaxInvoiceScreen> createState() => _TaxInvoiceScreenState();
}

class _TaxInvoiceScreenState extends State<TaxInvoiceScreen> {
  final _formKey = GlobalKey<FormState>();

  int? _selectedContractId;
  int? _selectedInstallmentId;
  int? _selectedTenantId;
  List<Map<String, dynamic>> _unbilledInstallments = [];
  bool _installmentsLoading = false;
  String? _installmentsError;
  int? _revenueAccountId;
  int? _taxAccountId;
  bool _isProcessing = false;
  bool _taxSettingsLoading = true;
  double _taxRate = 0;
  String? _taxSettingsError;

  final _dateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  final _netAmountController = TextEditingController();
  final _taxAmountController = TextEditingController();
  final _grossAmountController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadTaxSettings();
  }

  Future<void> _loadTaxSettings() async {
    try {
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      final configuredRate = companyInfo?['tax_rate'];
      if (configuredRate is! num) {
        throw StateError('نسبة الضريبة غير مضبوطة');
      }
      final rate = configuredRate.toDouble();
      if (!InternalTax.isValidRate(rate)) {
        throw StateError('نسبة الضريبة المحفوظة خارج النطاق المسموح');
      }
      if (!mounted) return;
      setState(() {
        _taxRate = rate;
        _taxSettingsError = null;
        _taxSettingsLoading = false;
      });
      _calculateGross();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _taxSettingsError =
            'تعذر تحميل نسبة الضريبة من إعدادات المنشأة: $error';
        _taxSettingsLoading = false;
      });
    }
  }

  void _calculateGross() {
    final parsedNet = double.tryParse(_netAmountController.text);
    final net = parsedNet != null && parsedNet.isFinite && parsedNet >= 0
        ? parsedNet
        : 0.0;
    final tax = InternalTax.calculate(net, _taxRate);
    _taxAmountController.text = tax.toStringAsFixed(2);
    _grossAmountController.text = (net + tax).toStringAsFixed(2);
  }

  String _formatDueDate(dynamic value) {
    final parsed = DateTime.tryParse(value?.toString() ?? '');
    return parsed == null
        ? (value?.toString() ?? 'غير محدد')
        : DateFormat('yyyy-MM-dd').format(parsed);
  }

  Future<void> _loadInstallments(int contractId) async {
    setState(() {
      _installmentsLoading = true;
      _installmentsError = null;
    });
    try {
      final installments = await DatabaseHelper.instance
          .getUnbilledInstallmentsForContract(contractId);
      if (!mounted || _selectedContractId != contractId) return;
      setState(() {
        _unbilledInstallments = List<Map<String, dynamic>>.from(installments);
        _installmentsLoading = false;
      });
    } catch (error) {
      if (!mounted || _selectedContractId != contractId) return;
      setState(() {
        _unbilledInstallments = [];
        _installmentsLoading = false;
        _installmentsError = 'تعذر تحميل الأقساط غير المفوترة: $error';
      });
    }
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
    if (_taxSettingsLoading || _taxSettingsError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تحقق من إعداد نسبة الضريبة أولاً')),
      );
      return;
    }
    if (!InternalTax.isValidRate(_taxRate)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر التحقق من نسبة الضريبة المحملة')),
      );
      return;
    }
    if (_selectedInstallmentId == null ||
        !_unbilledInstallments.any(
          (installment) =>
              (installment['id'] as num?)?.toInt() == _selectedInstallmentId,
        )) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر قسطاً غير مفوتر قبل الحفظ')),
      );
      return;
    }
    if (!_formKey.currentState!.validate() ||
        _selectedContractId == null ||
        _selectedTenantId == null ||
        _revenueAccountId == null ||
        (_taxRate > 0 && _taxAccountId == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء تعبئة جميع الحقول المطلوبة')),
      );
      return;
    }
    final net = double.tryParse(_netAmountController.text) ?? 0.0;
    final tax = double.tryParse(_taxAmountController.text) ?? 0.0;
    if (!net.isFinite ||
        net <= 0 ||
        !tax.isFinite ||
        tax < 0 ||
        DateTime.tryParse(_dateController.text) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تحقق من مبلغ وتاريخ الفاتورة')),
      );
      return;
    }

    final contractId = _selectedContractId!;
    final installment = _unbilledInstallments.firstWhere(
      (item) => (item['id'] as num).toInt() == _selectedInstallmentId,
    );
    final installmentId = (installment['id'] as num).toInt();
    final installmentDueDate = _formatDueDate(installment['due_date']);
    final tenantId = _selectedTenantId!;
    final revenueAccountId = _revenueAccountId!;
    final int? taxAccountId = _taxRate > 0 ? _taxAccountId : null;
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
        installmentId: installmentId,
        tenantId: tenantId,
        invoiceDate: invoiceDate,
        netAmount: net,
        taxAmount: tax,
        revenueAccountId: revenueAccountId,
        taxAccountId: taxAccountId,
      );
    } catch (e) {
      if (e.toString().contains('نسبة المنشأة الحالية')) {
        await _loadTaxSettings();
      }
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
        installmentNo: installmentId,
        installmentDueDate: installmentDueDate,
        tenantName: tenantName,
        net: net,
        tax: tax,
        gross: net + tax,
        taxRate: _taxRate,
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
      setState(() {
        _selectedInstallmentId = null;
        _isProcessing = false;
      });
      _loadInstallments(contractId);
    }
  }

  Future<String?> _printInvoice({
    required int invoiceNo,
    required int contractNo,
    required int installmentNo,
    required String installmentDueDate,
    required String tenantName,
    required double net,
    required double tax,
    required double gross,
    required double taxRate,
    required String date,
    required bool saveAsPdf,
  }) async {
    final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
    final String companyTax = companyInfo?['tax_number'] ?? '';
    final String companyName = companyInfo?['name_ar'] ?? '';
    final currency = PrintUtils.currencyInArabic(
      companyInfo?['default_currency'],
    );

    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    pdf.addPage(
      pw.MultiPage(
        pageTheme: PrintUtils.pageTheme(
          theme: theme,
          companyInfo: companyInfo,
          margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 34),
        ),
        header: (_) => PrintUtils.buildHeader(companyInfo, true),
        footer: (context) => PrintUtils.buildPageFooter(context, companyInfo),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'فاتورة داخلية',
              textDirection: pw.TextDirection.rtl,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: 17,
                fontWeight: pw.FontWeight.bold,
                color: PrintUtils.brandNavy,
              ),
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'مستند داخلي للحساب والمتابعة؛ لا يمثل فاتورة إلكترونية معتمدة أو تكاملًا رسميًا.',
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 10),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: PrintUtils.softSurface,
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Row(
                  children: [
                    pw.Expanded(
                      child: _invoiceMeta('رقم الفاتورة', invoiceNo.toString()),
                    ),
                    pw.SizedBox(width: 10),
                    pw.Expanded(child: _invoiceMeta('التاريخ', date)),
                    pw.SizedBox(width: 10),
                    pw.Expanded(
                      child: _invoiceMeta('رقم العقد', contractNo.toString()),
                    ),
                  ],
                ),
                PrintUtils.buildLabelValue(
                  'اسم المستأجر',
                  tenantName,
                  labelWidth: 90,
                ),
                PrintUtils.buildLabelValue(
                  'رقم القسط',
                  installmentNo.toString(),
                  labelWidth: 90,
                ),
                PrintUtils.buildLabelValue(
                  'تاريخ استحقاق القسط',
                  installmentDueDate,
                  labelWidth: 120,
                ),
                PrintUtils.buildLabelValue(
                  'الرقم الضريبي للمنشأة',
                  companyTax.isEmpty ? 'غير مضبوط في الإعدادات' : companyTax,
                  valueDirection: pw.TextDirection.ltr,
                  labelWidth: 120,
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 12),
          pw.TableHelper.fromTextArray(
            headers: ['الوصف', 'العملة', 'المبلغ'],
            data: [
              [
                'قيمة الإيجار (الصافي)',
                currency,
                PrintUtils.formatPdfAmount(net),
              ],
              [
                'الضريبة (${taxRate.toStringAsFixed(2)}%)',
                currency,
                PrintUtils.formatPdfAmount(tax),
              ],
              ['الإجمالي المستحق', currency, PrintUtils.formatPdfAmount(gross)],
            ],
            headerStyle: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
            cellStyle: const pw.TextStyle(fontSize: 10, lineSpacing: 2),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 7,
              vertical: 8,
            ),
            tableDirection: pw.TextDirection.rtl,
            headerDirection: pw.TextDirection.rtl,
            columnWidths: const {
              0: pw.FlexColumnWidth(2.5),
              1: pw.FlexColumnWidth(1.2),
              2: pw.FixedColumnWidth(100),
            },
            border: pw.TableBorder.all(
              color: PrintUtils.softBorder,
              width: 0.5,
            ),
            oddRowDecoration: pw.BoxDecoration(color: PrintUtils.softSurface),
          ),
          pw.SizedBox(height: 18),
          pw.Container(
            padding: const pw.EdgeInsets.all(9),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PrintUtils.softBorder),
              borderRadius: pw.BorderRadius.circular(5),
            ),
            child: pw.Row(
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                    children: [
                      pw.Text(
                        'إجمالي المبلغ المستحق',
                        textDirection: pw.TextDirection.rtl,
                        textAlign: pw.TextAlign.right,
                        style: const pw.TextStyle(
                          fontSize: 9,
                          color: PdfColors.grey700,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        PrintUtils.formatPdfAmount(gross),
                        textDirection: pw.TextDirection.ltr,
                        textAlign: pw.TextAlign.right,
                        style: pw.TextStyle(
                          fontSize: 17,
                          fontWeight: pw.FontWeight.bold,
                          color: PrintUtils.brandNavy,
                        ),
                      ),
                      pw.Text(
                        currency,
                        textDirection: pw.TextDirection.rtl,
                        textAlign: pw.TextAlign.right,
                        style: pw.TextStyle(
                          fontSize: 10,
                          fontWeight: pw.FontWeight.bold,
                          color: PrintUtils.brandEmerald,
                        ),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(width: 12),
                pw.Column(
                  children: [
                    pw.Text(
                      'رمز بيانات داخلي',
                      textDirection: pw.TextDirection.rtl,
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                    pw.SizedBox(height: 4),
                    pw.BarcodeWidget(
                      barcode: pw.Barcode.qrCode(),
                      data:
                          'نوع المستند: داخلي\nرقم الفاتورة: $invoiceNo\nالمنشأة: $companyName\nالرقم الضريبي: $companyTax\nالمستأجر: $tenantName\nرقم القسط: $installmentNo\nاستحقاق القسط: $installmentDueDate\nالصافي: ${PrintUtils.formatPdfAmount(net)}\nالضريبة: ${PrintUtils.formatPdfAmount(tax)}\nالإجمالي: ${PrintUtils.formatPdfAmount(gross)}\nالعملة: $currency\nالتاريخ: $date',
                      width: 76,
                      height: 76,
                    ),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 20),
          pw.Row(
            children: [
              _invoiceSignature('توقيع المحاسب'),
              _invoiceSignature('توقيع المستلم'),
            ],
          ),
        ],
      ),
    );

    final bytes = await pdf.save();
    try {
      if (mounted) {
        await PdfDocumentPreviewDialog.show(
          context: context,
          bytes: bytes,
          fileName: 'فاتورة_داخلية_$invoiceNo',
          preferredIntent: saveAsPdf
              ? PdfPreviewIntent.save
              : PdfPreviewIntent.printDocument,
          permissionModule: 'tenant_financial',
        );
      }
      return null;
    } catch (e) {
      return 'تعذر تجهيز/طباعة المستند: $e';
    }
  }

  pw.Widget _invoiceMeta(String label, String value) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
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
        textDirection: pw.TextDirection.ltr,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: 10,
          fontWeight: pw.FontWeight.bold,
          color: PrintUtils.brandNavy,
        ),
      ),
    ],
  );

  pw.Widget _invoiceSignature(String title) => pw.Expanded(
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          title,
          textDirection: pw.TextDirection.rtl,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: 9,
            fontWeight: pw.FontWeight.bold,
            color: PrintUtils.brandNavy,
          ),
        ),
        pw.SizedBox(height: 23),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 35),
          child: pw.Container(height: 0.7, color: PdfColors.grey700),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Consumer2<LeasingProvider, AccountingProvider>(
      builder: (context, leasingProv, accProv, child) {
        if (leasingProv.isLoading || accProv.isLoading || _taxSettingsLoading)
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
                      'إصدار فاتورة داخلية',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_taxSettingsError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _taxSettingsError!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ] else ...[
                      const SizedBox(height: 8),
                      Text(
                        'نسبة الضريبة الداخلية المعتمدة: ${_taxRate.toStringAsFixed(2)}% — المستند داخلي وليس تكاملًا رسميًا',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                    const SizedBox(height: 32),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _selectedContractId,
                            items: leasingProv.contracts
                                .where((c) => c['status'] == 'Active')
                                .map(
                                  (c) => DropdownMenuItem<int>(
                                    value: c['id'],
                                    child: Text('عقد رقم: ${c['id']}'),
                                  ),
                                )
                                .toList(),
                            onChanged: _isProcessing
                                ? null
                                : (val) {
                                    setState(() {
                                      _selectedContractId = val;
                                      _selectedInstallmentId = null;
                                      _selectedTenantId = null;
                                      _unbilledInstallments = [];
                                      _installmentsLoading = false;
                                      _installmentsError = null;
                                      _netAmountController.clear();
                                      _calculateGross();
                                      // Auto select tenant
                                      if (val != null) {
                                        final contract = leasingProv.contracts
                                            .firstWhere((c) => c['id'] == val);
                                        _selectedTenantId =
                                            contract['tenant_id'];
                                      }
                                    });
                                    if (val != null) _loadInstallments(val);
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
                    DropdownButtonFormField<int>(
                      value: _selectedInstallmentId,
                      items: _unbilledInstallments.map((installment) {
                        final installmentId = (installment['id'] as num)
                            .toInt();
                        return DropdownMenuItem<int>(
                          value: installmentId,
                          child: Text(
                            'القسط رقم $installmentId — الاستحقاق ${_formatDueDate(installment['due_date'])}',
                          ),
                        );
                      }).toList(),
                      onChanged:
                          _isProcessing ||
                              _selectedContractId == null ||
                              _installmentsLoading
                          ? null
                          : (value) {
                              final selected = value == null
                                  ? null
                                  : _unbilledInstallments.firstWhere(
                                      (item) =>
                                          (item['id'] as num).toInt() == value,
                                    );
                              setState(() {
                                _selectedInstallmentId = value;
                                _netAmountController.text = selected == null
                                    ? ''
                                    : ((selected['amount'] as num).toDouble())
                                          .toStringAsFixed(2);
                                _calculateGross();
                              });
                            },
                      decoration: InputDecoration(
                        labelText: 'اختر القسط غير المفوتر',
                        border: const OutlineInputBorder(),
                        helperText: _installmentsLoading
                            ? 'جارٍ تحميل الأقساط...'
                            : _installmentsError ??
                                  (_selectedContractId != null &&
                                          _unbilledInstallments.isEmpty
                                      ? 'لا توجد أقساط غير مفوترة لهذا العقد'
                                      : null),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_selectedInstallmentId != null) ...[
                      Text(
                        'تاريخ استحقاق القسط: ${_formatDueDate(_unbilledInstallments.firstWhere((item) => (item['id'] as num).toInt() == _selectedInstallmentId)['due_date'])}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: _revenueAccountId,
                            items: accProv.detailAccounts
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
                            initialValue: _taxAccountId,
                            items: accProv.detailAccounts
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
                            onChanged: _taxRate > 0
                                ? (val) => setState(() => _taxAccountId = val)
                                : null,
                            decoration: InputDecoration(
                              labelText: _taxRate > 0
                                  ? 'حساب الضريبة (Credit)'
                                  : 'حساب الضريبة (غير مطلوب عند 0%)',
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
                        if (picked != null && mounted) {
                          setState(
                            () => _dateController.text = DateFormat(
                              'yyyy-MM-dd',
                            ).format(picked),
                          );
                        }
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
                              labelText: 'المبلغ الصافي للقسط',
                              border: OutlineInputBorder(),
                            ),
                            readOnly: true,
                            validator: (v) {
                              final value = double.tryParse(v ?? '');
                              return value == null ||
                                      !value.isFinite ||
                                      value <= 0
                                  ? 'أدخل مبلغاً موجباً'
                                  : null;
                            },
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: TextFormField(
                            controller: _taxAmountController,
                            readOnly: true,
                            decoration: InputDecoration(
                              labelText:
                                  'الضريبة (${_taxRate.toStringAsFixed(2)}%)',
                              border: OutlineInputBorder(),
                            ),
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
                            onPressed:
                                _isProcessing ||
                                    _taxSettingsError != null ||
                                    !PermissionRuntime.allows(
                                      'tenant_financial',
                                      AppPermissionAction.post,
                                    )
                                ? null
                                : () => _processInvoice(saveAsPdf: false),
                            icon: const Icon(Icons.print),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.all(16),
                            ),
                            label: Text(
                              PermissionRuntime.allows(
                                    'tenant_financial',
                                    AppPermissionAction.print,
                                  )
                                  ? 'إصدار وترحيل وطباعة'
                                  : 'إصدار وترحيل ومعاينة',
                            ),
                          ),
                        ),
                        if (PermissionRuntime.allows(
                          'tenant_financial',
                          AppPermissionAction.print,
                        )) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed:
                                  _isProcessing ||
                                      _taxSettingsError != null ||
                                      !PermissionRuntime.allows(
                                        'tenant_financial',
                                        AppPermissionAction.post,
                                      )
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
