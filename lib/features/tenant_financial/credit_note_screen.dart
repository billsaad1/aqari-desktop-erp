import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';

import '../../core/internal_tax.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';
import '../../core/print_utils.dart';
import '../../database/database_helper.dart';
import '../../providers/accounting_provider.dart';

class CreditNoteScreen extends StatefulWidget {
  const CreditNoteScreen({super.key});

  @override
  State<CreditNoteScreen> createState() => _CreditNoteScreenState();
}

class _CreditNoteScreenState extends State<CreditNoteScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _reasonController = TextEditingController();
  final _dateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );

  List<Map<String, dynamic>> _candidates = [];
  List<Map<String, dynamic>> _notes = [];
  int? _selectedInvoiceId;
  bool _loading = true;
  bool _processing = false;
  String? _error;

  Map<String, dynamic>? get _selectedInvoice {
    for (final row in _candidates) {
      if ((row['invoice_id'] as num?)?.toInt() == _selectedInvoiceId) {
        return row;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _reasonController.dispose();
    _dateController.dispose();
    super.dispose();
  }

  String _amount(dynamic value) => NumberFormat('#,##0.00').format(
    value is num ? value.toDouble() : 0.0,
  );

  bool _hasCentPrecision(double value) {
    final scaled = value * 100;
    return (scaled - scaled.round()).abs() < 0.0000001;
  }

  String _statusLabel(Object? status) => switch (status?.toString()) {
    'draft' => 'مسودة — غير مرحّلة',
    'posted' => 'مرحّل',
    'reversed' => 'معكوس بقيد',
    'legacy_review' => 'سجل تاريخي — يتطلب مراجعة',
    _ => 'حالة غير معروفة',
  };

  Future<void> _reload() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        DatabaseHelper.instance.getCreditNoteInvoiceCandidates(),
        DatabaseHelper.instance.getCreditNotes(),
      ]);
      if (!mounted) return;
      final candidates = results[0];
      final selectedStillExists = candidates.any(
        (row) => (row['invoice_id'] as num).toInt() == _selectedInvoiceId,
      );
      setState(() {
        _candidates = candidates;
        _notes = results[1];
        if (!selectedStillExists) {
          _selectedInvoiceId = candidates.isEmpty
              ? null
              : (candidates.first['invoice_id'] as num).toInt();
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _candidates = [];
        _notes = [];
        _loading = false;
        _error = 'تعذر تحميل الإشعارات والفواتير المؤهلة: $error';
      });
    }
  }

  Future<void> _pickDate() async {
    final initial = DateTime.tryParse(_dateController.text) ?? DateTime.now();
    final chosen = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (chosen != null && mounted) {
      setState(() => _dateController.text = DateFormat('yyyy-MM-dd').format(chosen));
    }
  }

  Future<void> _createDraft() async {
    if (_processing || !_formKey.currentState!.validate()) return;
    final invoice = _selectedInvoice;
    final parsed = double.tryParse(_amountController.text.trim());
    if (invoice == null ||
        parsed == null ||
        !parsed.isFinite ||
        parsed <= 0 ||
        !_hasCentPrecision(parsed)) {
      return;
    }
    final totalMinor = InternalTax.toMinorUnits(parsed);
    final availableMinor = (invoice['available_credit_minor'] as num).toInt();
    if (totalMinor > availableMinor) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('المبلغ يتجاوز الرصيد غير المعكوس من الفاتورة الأصلية')),
      );
      return;
    }
    setState(() => _processing = true);
    try {
      final id = await DatabaseHelper.instance.createCreditNoteDraft(
        invoiceId: _selectedInvoiceId!,
        noteDate: _dateController.text,
        totalAmountMinor: totalMinor,
        reason: _reasonController.text.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('حُفظ الإشعار الدائن رقم $id كمسودة دون أثر على الأستاذ')),
      );
      _reasonController.clear();
      await _reload();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ مسودة الإشعار: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _post(Map<String, dynamic> note) async {
    final id = (note['id'] as num).toInt();
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('ترحيل الإشعار الدائن رقم $id؟'),
        content: Text(
          'سيُنشأ قيد عكسي مرتبط بالفاتورة الأصلية بقيمة ${_amount((note['total_amount_minor'] as num).toInt() / 100.0)}. لن يرد هذا الإجراء النقد تلقائيًا، ولا يمكن حذف الإشعار بعد ترحيله.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('ترحيل القيد'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() => _processing = true);
    try {
      await DatabaseHelper.instance.postCreditNote(id);
      await Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم ترحيل الإشعار الدائن رقم $id وربطه بقيده')),
      );
      await _reload();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر ترحيل الإشعار الدائن: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _reverse(Map<String, dynamic> note) async {
    final id = (note['id'] as num).toInt();
    final reasonController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('عكس الإشعار الدائن رقم $id'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('سيُنشأ قيد عكسي مستقل. لا يُسمح بالعكس بعد رد نقدي مرتبط بالإشعار.'),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                maxLength: 500,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'سبب العكس (إلزامي)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              final reason = reasonController.text.trim();
              if (reason.isNotEmpty) Navigator.pop(dialogContext, reason);
            },
            child: const Text('تأكيد العكس'),
          ),
        ],
      ),
    );
    reasonController.dispose();
    if (result == null || !mounted) return;
    setState(() => _processing = true);
    try {
      await DatabaseHelper.instance.reverseCreditNote(
        id,
        reversalDate: DateFormat('yyyy-MM-dd').format(DateTime.now()),
        reason: result,
      );
      await Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم عكس الإشعار $id بقيد مستقل')),
      );
      await _reload();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر عكس الإشعار: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _preview(Map<String, dynamic> note, {required bool saveAsPdf}) async {
    try {
      await _buildPreview(note, saveAsPdf: saveAsPdf);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تجهيز معاينة الإشعار الدائن: $error')),
      );
    }
  }

  Future<void> _buildPreview(
    Map<String, dynamic> note, {
    required bool saveAsPdf,
  }) async {
    PermissionRuntime.require('tenant_financial', AppPermissionAction.print);
    final company = await DatabaseHelper.instance.getCompanyInfo();
    final currency = PrintUtils.currencyInArabic(company?['default_currency']);
    final noteId = (note['id'] as num).toInt();
    final totalMinor = (note['total_amount_minor'] as num?)?.toInt() ?? 0;
    final netMinor = (note['net_amount_minor'] as num?)?.toInt() ?? 0;
    final taxMinor = (note['tax_amount_minor'] as num?)?.toInt() ?? 0;
    final status = note['status']?.toString();
    final pdf = pw.Document();
    final theme = await PrintUtils.loadArabicTheme();
    pdf.addPage(
      pw.MultiPage(
        pageTheme: PrintUtils.pageTheme(
          theme: theme,
          companyInfo: company,
          margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 34),
        ),
        header: (_) => PrintUtils.buildHeader(company, true),
        footer: (context) => PrintUtils.buildPageFooter(context, company),
        build: (_) => [
          pw.Center(
            child: pw.Text(
              'إشعار دائن داخلي',
              textDirection: pw.TextDirection.rtl,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: 18,
                fontWeight: pw.FontWeight.bold,
                color: PrintUtils.brandNavy,
              ),
            ),
          ),
          pw.SizedBox(height: 5),
          pw.Text(
            status == 'draft'
                ? 'مسودة غير مرحّلة — لا أثر لها على دفتر الأستاذ'
                : 'مستند داخلي؛ لا يمثل فاتورة إلكترونية معتمدة أو تكاملًا ضريبيًا رسميًا.',
            textDirection: pw.TextDirection.rtl,
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 12),
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
                PrintUtils.buildLabelValue('رقم الإشعار', '$noteId'),
                PrintUtils.buildLabelValue('تاريخ الإشعار', '${note['note_date'] ?? '—'}'),
                PrintUtils.buildLabelValue('الفاتورة الأصلية', '${note['invoice_id'] ?? 'غير مرتبطة'}'),
                PrintUtils.buildLabelValue('تاريخ الفاتورة', '${note['invoice_date'] ?? '—'}'),
                PrintUtils.buildLabelValue('المستأجر', '${note['tenant_name'] ?? 'غير محدد'}'),
                PrintUtils.buildLabelValue('سبب الإشعار', '${note['reason'] ?? 'غير متوفر'}'),
                PrintUtils.buildLabelValue('الحالة', _statusLabel(status)),
              ],
            ),
          ),
          pw.SizedBox(height: 12),
          pw.TableHelper.fromTextArray(
            headers: ['البيان', 'العملة', 'المبلغ'],
            data: [
              ['صافي الإشعار', currency, PrintUtils.formatPdfAmount(netMinor / 100.0)],
              ['ضريبة حسب لقطة الفاتورة', currency, PrintUtils.formatPdfAmount(taxMinor / 100.0)],
              ['إجمالي الإشعار', currency, PrintUtils.formatPdfAmount(totalMinor / 100.0)],
            ],
            headerStyle: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.white,
            ),
            headerDecoration: pw.BoxDecoration(color: PrintUtils.brandNavy),
            cellStyle: const pw.TextStyle(fontSize: 10, lineSpacing: 2),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 8),
            tableDirection: pw.TextDirection.rtl,
            headerDirection: pw.TextDirection.rtl,
            columnWidths: const {
              0: pw.FlexColumnWidth(2.5),
              1: pw.FlexColumnWidth(1.2),
              2: pw.FixedColumnWidth(100),
            },
            border: pw.TableBorder.all(color: PrintUtils.softBorder, width: 0.5),
            oddRowDecoration: pw.BoxDecoration(color: PrintUtils.softSurface),
          ),
          pw.SizedBox(height: 18),
          pw.Text(
            'إصدار الإشعار لا ينفذ ردًا نقديًا. أي رد نقدي يُسجل بسند مستقل مرتبط بمصدر القبض وبالإشعار عند انطباقه.',
            textDirection: pw.TextDirection.rtl,
            style: const pw.TextStyle(fontSize: 9),
          ),
        ],
      ),
    );
    final bytes = await pdf.save();
    if (!mounted) return;
    await PdfDocumentPreviewDialog.show(
      context: context,
      bytes: bytes,
      fileName: 'إشعار_دائن_$noteId',
      preferredIntent: saveAsPdf
          ? PdfPreviewIntent.save
          : PdfPreviewIntent.printDocument,
      permissionModule: 'tenant_financial',
    );
  }

  @override
  Widget build(BuildContext context) {
    final canAdd = PermissionRuntime.allows('tenant_financial', AppPermissionAction.add);
    final canPost = PermissionRuntime.allows('tenant_financial', AppPermissionAction.post);
    final canPrint = PermissionRuntime.allows('tenant_financial', AppPermissionAction.print);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  elevation: 1,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('إصدار إشعار دائن مرتبط بفاتورة', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          const Text('تُحفظ المسودة بلا قيد. عند الترحيل يُنشأ قيد عكسي متوازن بالاستناد إلى قيد الفاتورة الأصلية ولقطة صافيها وضريبتها. الإشعار لا يرد النقد تلقائيًا.'),
                          const SizedBox(height: 14),
                          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
                          if (_candidates.isEmpty)
                            const Text('لا توجد فاتورة ذات رصيد غير معكوس متاح. الفواتير التاريخية غير المرتبطة بقيد موثوق لا تُرحّل آليًا.'),
                          if (_candidates.isNotEmpty)
                            DropdownButtonFormField<int>(
                              value: _selectedInvoiceId,
                              isExpanded: true,
                              items: _candidates.map((row) {
                                final id = (row['invoice_id'] as num).toInt();
                                return DropdownMenuItem<int>(
                                  value: id,
                                  child: Text('فاتورة #$id — ${row['tenant_name']} — ${row['invoice_date']} — المتاح ${_amount((row['available_credit_minor'] as num).toInt() / 100.0)}'),
                                );
                              }).toList(),
                              onChanged: _processing ? null : (id) {
                                setState(() {
                                  _selectedInvoiceId = id;
                                  final selected = _selectedInvoice;
                                  _amountController.text = selected == null
                                      ? ''
                                      : ((selected['available_credit_minor'] as num).toInt() / 100.0).toStringAsFixed(2);
                                });
                              },
                              decoration: const InputDecoration(labelText: 'الفاتورة الأصلية', border: OutlineInputBorder()),
                              validator: (value) => value == null ? 'اختر فاتورة أصلية' : null,
                            ),
                          if (_candidates.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: _dateController,
                                    readOnly: true,
                                    onTap: _pickDate,
                                    decoration: const InputDecoration(labelText: 'تاريخ الإشعار', border: OutlineInputBorder()),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: TextFormField(
                                    controller: _amountController,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    decoration: InputDecoration(
                                      labelText: 'إجمالي الإشعار',
                                      helperText: _selectedInvoice == null ? null : 'المتبقي غير المعكوس ${_amount((_selectedInvoice!['available_credit_minor'] as num).toInt() / 100.0)}',
                                      border: const OutlineInputBorder(),
                                    ),
                                    validator: (value) {
                                      final amount = double.tryParse(value?.trim() ?? '');
                                      if (amount == null || !amount.isFinite || amount <= 0) return 'أدخل مبلغًا موجبًا';
                                      if (!_hasCentPrecision(amount)) return 'أدخل المبلغ حتى منزلتين عشريتين فقط';
                                      final available = (_selectedInvoice?['available_credit_minor'] as num?)?.toInt() ?? 0;
                                      if (InternalTax.toMinorUnits(amount) > available) return 'يتجاوز الرصيد المتاح من الفاتورة';
                                      return null;
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _reasonController,
                              minLines: 2,
                              maxLines: 4,
                              maxLength: 500,
                              decoration: const InputDecoration(labelText: 'سبب الإشعار الدائن', border: OutlineInputBorder()),
                              validator: (value) => value == null || value.trim().isEmpty ? 'سبب الإشعار مطلوب للتدقيق' : null,
                            ),
                            const SizedBox(height: 10),
                            Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: FilledButton.icon(
                                onPressed: !canAdd || _processing ? null : _createDraft,
                                icon: _processing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined),
                                label: const Text('حفظ كمسودة'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(child: Text('سجل الإشعارات الدائنة', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
                    IconButton(onPressed: _reload, tooltip: 'تحديث', icon: const Icon(Icons.refresh)),
                  ],
                ),
                Expanded(
                  child: _notes.isEmpty
                      ? const Center(child: Text('لا توجد إشعارات دائنة بعد.'))
                      : ListView.builder(
                          itemCount: _notes.length,
                          itemBuilder: (context, index) {
                            final note = _notes[index];
                            final id = (note['id'] as num).toInt();
                            final total = (note['total_amount_minor'] as num?)?.toInt() ?? 0;
                            final status = note['status']?.toString();
                            final isLegacy = status == 'legacy_review';
                            return Card(
                              child: ListTile(
                                leading: Icon(
                                  status == 'posted' ? Icons.verified_outlined : status == 'reversed' ? Icons.undo : Icons.request_quote_outlined,
                                  color: status == 'posted' ? Colors.green.shade700 : isLegacy ? Colors.deepOrange : null,
                                ),
                                title: Text('إشعار #$id — ${_amount(total / 100.0)} — ${_statusLabel(status)}'),
                                subtitle: Text('الفاتورة ${note['invoice_id'] ?? 'غير مرتبطة'} — ${note['tenant_name'] ?? 'غير محدد'} — ${note['note_date'] ?? '—'}\n${note['reason'] ?? 'سبب غير مسجل في السجل التاريخي'}'),
                                isThreeLine: true,
                                trailing: Wrap(
                                  spacing: 4,
                                  children: [
                                    if (canPrint)
                                      IconButton(
                                        tooltip: 'معاينة/طباعة أو حفظ PDF',
                                        onPressed: _processing ? null : () => _preview(note, saveAsPdf: false),
                                        icon: const Icon(Icons.picture_as_pdf_outlined),
                                      ),
                                    if (status == 'draft' && canPost)
                                      IconButton(
                                        tooltip: 'ترحيل',
                                        onPressed: _processing ? null : () => _post(note),
                                        icon: const Icon(Icons.post_add_outlined),
                                      ),
                                    if (status == 'posted' && canPost)
                                      IconButton(
                                        tooltip: 'عكس بقيد مستقل',
                                        onPressed: _processing ? null : () => _reverse(note),
                                        icon: const Icon(Icons.undo_outlined),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
