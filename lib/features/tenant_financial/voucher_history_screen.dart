import 'package:flutter/material.dart';
import '../../core/erp_data_table.dart';
import 'package:intl/intl.dart';

import '../../core/print_utils.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';
import '../../database/database_helper.dart';

class VoucherHistoryScreen extends StatefulWidget {
  const VoucherHistoryScreen({super.key});

  @override
  State<VoucherHistoryScreen> createState() => _VoucherHistoryScreenState();
}

class _VoucherHistoryScreenState extends State<VoucherHistoryScreen> {
  static const _types = [
    'الكل',
    'قبض عام',
    'صرف عام',
    'قبض مستأجر',
    'صرف مستأجر',
    'صرف مستحقات مالك',
  ];

  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _vouchers = [];
  String _selectedType = 'الكل';
  String _currency = 'ريال يمني';
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadVouchers();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadVouchers() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await DatabaseHelper.instance.getVoucherHistory(
        voucherType: _selectedType == 'الكل' ? null : _selectedType,
      );
      if (!mounted) return;
      setState(() {
        _vouchers = results;
        _isLoading = false;
      });
      try {
        final company = await DatabaseHelper.instance.getCompanyInfo();
        if (!mounted) return;
        setState(
          () => _currency = PrintUtils.currencyInArabic(
            company?['default_currency'],
          ),
        );
      } catch (_) {
        // Keep the default display currency; the voucher records are loaded.
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'تعذر تحميل سجل السندات: $e';
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredVouchers {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _vouchers;
    return _vouchers.where((voucher) {
      final searchable = [
        voucher['id'],
        voucher['voucher_type'],
        voucher['voucher_date'],
        voucher['party_name'],
        voucher['description'],
        voucher['amount'],
      ].join(' ').toLowerCase();
      return searchable.contains(query);
    }).toList();
  }

  Future<void> _openDetails(Map<String, dynamic> voucher) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _VoucherDetailsDialog(voucherId: (voucher['id'] as num).toInt()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vouchers = _filteredVouchers;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long, size: 30),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'سجل السندات',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: 'تحديث السجل',
                onPressed: _isLoading ? null : _loadVouchers,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'بحث برقم السند أو الطرف أو البيان أو التاريخ',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedType,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'نوع السند',
                    border: OutlineInputBorder(),
                  ),
                  items: _types
                      .map(
                        (type) => DropdownMenuItem(
                          value: type,
                          child: Text(
                            type == 'صرف مستحقات مالك' ? 'سداد المالك' : type,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (type) {
                    if (type == null) return;
                    setState(() => _selectedType = type);
                    _loadVouchers();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _isLoading
                ? 'جارٍ تحميل السندات...'
                : 'عدد السندات المعروضة: ${vouchers.length}',
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _loadVouchers,
                          icon: const Icon(Icons.refresh),
                          label: const Text('إعادة المحاولة'),
                        ),
                      ],
                    ),
                  )
                : vouchers.isEmpty
                ? const Center(
                    child: Text(
                      'لا توجد سندات محفوظة مطابقة للبحث.',
                      style: TextStyle(fontSize: 16, color: Colors.black54),
                    ),
                  )
                : ListView.separated(
                    itemCount: vouchers.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, index) {
                      final voucher = vouchers[index];
                      final isReceipt = (voucher['voucher_type'] as String)
                          .contains('قبض');
                      final amount = (voucher['amount'] as num).toDouble();
                      final party = (voucher['party_name'] as String?)?.trim();
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isReceipt
                                ? Colors.green.shade100
                                : Colors.red.shade100,
                            child: Icon(
                              isReceipt ? Icons.call_received : Icons.call_made,
                              color: isReceipt ? Colors.green : Colors.red,
                            ),
                          ),
                          title: Text(
                            'سند ${voucher['voucher_type']} رقم ${voucher['id']}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            '${voucher['voucher_date']}  •  ${party?.isNotEmpty == true ? party : (voucher['description'] ?? '—')}  •  ${NumberFormat('#,##0.00').format(amount)} $_currency',
                          ),
                          trailing: IconButton(
                            tooltip: 'عرض التفاصيل',
                            onPressed: () => _openDetails(voucher),
                            icon: const Icon(Icons.visibility_outlined),
                          ),
                          onTap: () => _openDetails(voucher),
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

class _VoucherDetailsDialog extends StatefulWidget {
  final int voucherId;

  const _VoucherDetailsDialog({required this.voucherId});

  @override
  State<_VoucherDetailsDialog> createState() => _VoucherDetailsDialogState();
}

class _VoucherDetailsDialogState extends State<_VoucherDetailsDialog> {
  Map<String, dynamic>? _data;
  String _currency = 'ريال يمني';
  bool _isLoading = true;
  bool _isWorking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    try {
      final data = await DatabaseHelper.instance.getVoucherDetails(
        widget.voucherId,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = data == null
            ? 'لم يعد هذا السند موجودًا في قاعدة البيانات.'
            : null;
        _isLoading = false;
      });
      try {
        final company = await DatabaseHelper.instance.getCompanyInfo();
        if (!mounted) return;
        setState(
          () => _currency = PrintUtils.currencyInArabic(
            company?['default_currency'],
          ),
        );
      } catch (_) {
        // Keep the default display currency if settings cannot be read.
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'تعذر قراءة تفاصيل السند: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _export({required bool saveAsPdf}) async {
    if (_isWorking || _data == null) return;
    setState(() => _isWorking = true);
    try {
      final voucher = Map<String, dynamic>.from(_data!['voucher'] as Map);
      final lines = List<Map<String, dynamic>>.from(
        (_data!['journal_lines'] as List).map(
          (line) => Map<String, dynamic>.from(line as Map),
        ),
      );
      final installments = List<Map<String, dynamic>>.from(
        (_data!['installments'] as List).map(
          (line) => Map<String, dynamic>.from(line as Map),
        ),
      );
      final invoices = List<Map<String, dynamic>>.from(
        (_data!['invoices'] as List).map(
          (invoice) => Map<String, dynamic>.from(invoice as Map),
        ),
      );
      final refunds = List<Map<String, dynamic>>.from(
        (_data!['refunds'] as List).map(
          (refund) => Map<String, dynamic>.from(refund as Map),
        ),
      );
      final voucherType = voucher['voucher_type']?.toString() ?? '';
      final isGeneralVoucher = voucherType.contains('عام');
      final partyName = voucher['party_name']?.toString().trim() ?? '';
      final periodFrom = voucher['period_from_date']?.toString().trim();
      final periodTo = voucher['period_to_date']?.toString().trim();
      final pdfBytes = await PrintUtils.buildVoucherPdf(
        voucherType: 'سند $voucherType',
        voucherNo: widget.voucherId,
        date: voucher['voucher_date'].toString(),
        targetName: isGeneralVoucher || partyName.isEmpty ? null : partyName,
        amount: (voucher['amount'] as num).toDouble(),
        paymentMethod: null,
        accountName: '',
        description: voucher['description']?.toString(),
        periodStartDate: periodFrom,
        periodEndDate: periodTo,
        journalLines: lines,
        installmentAllocations: installments,
        invoiceAllocations: invoices,
        refundAllocations: refunds,
      );
      if (mounted) {
        await PdfDocumentPreviewDialog.show(
          context: context,
          bytes: pdfBytes,
          fileName: 'سند_${voucher['voucher_type']}_${widget.voucherId}',
          preferredIntent: saveAsPdf
              ? PdfPreviewIntent.save
              : PdfPreviewIntent.printDocument,
          permissionModule: 'voucher_history',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر تجهيز السند للطباعة: $e')));
      }
    } finally {
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Widget _detailTile(String label, String value) => Container(
    constraints: const BoxConstraints(minWidth: 190, maxWidth: 320),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.grey.shade100,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.black54, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );

  String _formatInvoiceAmount(dynamic value) {
    final amount = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    return amount == null
        ? '—'
        : '${NumberFormat('#,##0.00').format(amount)} $_currency';
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: screenSize.width < 1060 ? screenSize.width * 0.92 : 980,
        height: screenSize.height < 800 ? screenSize.height * 0.84 : 680,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: [
                  const Icon(Icons.receipt_long),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'تفاصيل السند رقم ${widget.voucherId}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'إغلاق',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(child: Text(_error!))
                  : _buildDetails(),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed:
                        _isWorking ||
                            !PermissionRuntime.allows(
                              'voucher_history',
                              AppPermissionAction.print,
                            )
                        ? null
                        : () => _export(saveAsPdf: false),
                    icon: const Icon(Icons.print),
                    label: const Text('طباعة'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed:
                        _isWorking ||
                            !PermissionRuntime.allows(
                              'voucher_history',
                              AppPermissionAction.print,
                            )
                        ? null
                        : () => _export(saveAsPdf: true),
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('حفظ PDF'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetails() {
    final voucher = Map<String, dynamic>.from(_data!['voucher'] as Map);
    final lines = List<Map<String, dynamic>>.from(
      (_data!['journal_lines'] as List).map(
        (line) => Map<String, dynamic>.from(line as Map),
      ),
    );
    final installments = List<Map<String, dynamic>>.from(
      (_data!['installments'] as List).map(
        (line) => Map<String, dynamic>.from(line as Map),
      ),
    );
    final rawInvoices = _data!['invoices'];
    final invoices = rawInvoices is List
        ? rawInvoices
              .whereType<Map>()
              .map((invoice) => Map<String, dynamic>.from(invoice))
              .toList()
        : <Map<String, dynamic>>[];
    final rawRefunds = _data!['refunds'];
    final refunds = rawRefunds is List
        ? rawRefunds
              .whereType<Map>()
              .map((refund) => Map<String, dynamic>.from(refund))
              .toList()
        : <Map<String, dynamic>>[];
    final rawOwnerSettlement = _data!['owner_settlement'];
    final ownerSettlement = rawOwnerSettlement is Map
        ? Map<String, dynamic>.from(rawOwnerSettlement)
        : null;
    final invoicedInstallmentIds = invoices
        .map((invoice) => invoice['installment_id'])
        .whereType<num>()
        .map((id) => id.toInt())
        .toSet();
    final standaloneInstallments = installments.where((installment) {
      final id = installment['installment_id'];
      return id is! num || !invoicedInstallmentIds.contains(id.toInt());
    }).toList();
    final isReceipt =
        voucher['voucher_type']?.toString().contains('قبض') == true;
    final amount = (voucher['amount'] as num).toDouble();
    final detailTiles = <Widget>[
      _detailTile('نوع السند', 'سند ${voucher['voucher_type']}'),
      _detailTile('التاريخ', voucher['voucher_date'].toString()),
      _detailTile('الطرف / المستأجر', voucher['party_name']?.toString() ?? '—'),
      _detailTile(
        'المبلغ',
        '${NumberFormat('#,##0.00').format(amount)} $_currency',
      ),
      _detailTile(
        'رقم القيد المحاسبي',
        voucher['journal_entry_id']?.toString() ?? '—',
      ),
      _detailTile('البيان', voucher['description']?.toString() ?? '—'),
      if (ownerSettlement != null) ...[
        _detailTile(
          'رقم سجل سداد المالك',
          ownerSettlement['settlement_id']?.toString() ?? '—',
        ),
        _detailTile(
          'حساب التزامات المالك',
          '${ownerSettlement['owner_account_code'] ?? '—'} — ${ownerSettlement['owner_account_name'] ?? '—'}',
        ),
        _detailTile(
          'حساب الصندوق / البنك',
          '${ownerSettlement['cash_account_code'] ?? '—'} — ${ownerSettlement['cash_account_name'] ?? '—'}',
        ),
      ],
      if ((voucher['period_from_date']?.toString().trim().isNotEmpty ??
              false) ||
          (voucher['period_to_date']?.toString().trim().isNotEmpty ?? false))
        _detailTile(
          'الفترة',
          'من ${voucher['period_from_date']?.toString() ?? '—'} إلى ${voucher['period_to_date']?.toString() ?? '—'}',
        ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(spacing: 10, runSpacing: 10, children: detailTiles),
          const SizedBox(height: 22),
          const Text(
            'الحسابات والحركة المحاسبية',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (lines.isEmpty)
            const Text('لا توجد أسطر قيد مرتبطة بهذا السند.')
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ErpDataTable(
                columns: const [
                  DataColumn(label: Text('رمز الحساب')),
                  DataColumn(label: Text('الحساب')),
                  DataColumn(label: Text('مدين')),
                  DataColumn(label: Text('دائن')),
                  DataColumn(label: Text('مركز التكلفة')),
                ],
                rows: lines.map((line) {
                  final debit = (line['debit'] as num? ?? 0).toDouble();
                  final credit = (line['credit'] as num? ?? 0).toDouble();
                  return DataRow(
                    cells: [
                      DataCell(Text(line['account_code']?.toString() ?? '—')),
                      DataCell(Text(line['account_name']?.toString() ?? '—')),
                      DataCell(Text(debit.toStringAsFixed(2))),
                      DataCell(Text(credit.toStringAsFixed(2))),
                      DataCell(
                        Text(line['cost_center_name']?.toString() ?? '—'),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          if (standaloneInstallments.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text(
              'الأقساط التي سددها هذا السند',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...standaloneInstallments.map((installment) {
              final allocated = (installment['allocated_amount'] as num)
                  .toDouble();
              return Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.event_available,
                    color: Colors.green,
                  ),
                  title: Text(
                    'العقار ${installment['property_name']} — الوحدة ${installment['unit_number']} — تاريخ الاستحقاق ${installment['due_date']}',
                  ),
                  subtitle: Text(
                    'رقم العقد ${installment['contract_id']} | مبلغ القسط ${(installment['installment_amount'] as num).toDouble().toStringAsFixed(2)} | المسدد بعد السند ${(installment['paid_amount'] as num).toDouble().toStringAsFixed(2)} | الحالة: ${installment['status']}',
                  ),
                  trailing: Text(
                    NumberFormat('#,##0.00').format(allocated),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              );
            }),
          ],
          if (isReceipt && invoices.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text(
              'الفواتير المرتبطة بهذا السند',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...invoices.map((invoice) {
              final invoiceDate = invoice['invoice_date']?.toString() ?? '—';
              final rawInstallmentId = invoice['installment_id'];
              final installmentId = rawInstallmentId is num
                  ? rawInstallmentId.toInt()
                  : null;
              final rentAllocated = installmentId == null
                  ? 0.0
                  : installments
                        .where(
                          (item) =>
                              (item['installment_id'] as num?)?.toInt() ==
                              installmentId,
                        )
                        .fold<double>(
                          0,
                          (sum, item) =>
                              sum +
                              ((item['allocated_amount'] as num?)?.toDouble() ??
                                  0),
                        );
              final invoiceAllocated =
                  (invoice['allocated_amount'] as num?)?.toDouble() ?? 0.0;
              final taxAllocated = (invoiceAllocated - rentAllocated)
                  .clamp(0.0, invoiceAllocated)
                  .toDouble();
              final invoiceDetails = [
                'التاريخ: $invoiceDate',
                'القسط: ${installmentId?.toString() ?? '—'}',
                if (invoice['due_date'] != null)
                  'الاستحقاق: ${invoice['due_date']}',
                'إجمالي الفاتورة: ${_formatInvoiceAmount(invoice['total_amount'])}',
                if (invoice['net_amount'] != null)
                  'الصافي: ${_formatInvoiceAmount(invoice['net_amount'])}',
                if (invoice['tax_amount'] != null)
                  'الضريبة: ${_formatInvoiceAmount(invoice['tax_amount'])}',
                'من هذا السند للإيجار: ${_formatInvoiceAmount(rentAllocated)}',
                'من هذا السند للضريبة: ${_formatInvoiceAmount(taxAllocated)}',
              ];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.receipt, color: Colors.blueGrey),
                  title: Text('الفاتورة رقم ${invoice['invoice_id'] ?? '—'}'),
                  subtitle: Text(invoiceDetails.join(' • ')),
                  trailing: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Text('المبلغ المخصص'),
                      Text(
                        _formatInvoiceAmount(invoice['allocated_amount']),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
          if (voucher['voucher_type']?.toString().contains('صرف') == true &&
              refunds.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text(
              'مصدر الاسترداد',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ...refunds.map((refund) {
              final invoice = refund['invoice_id'];
              final installment = refund['installment_id'];
              return Card(
                child: ListTile(
                  leading: const Icon(
                    Icons.assignment_return,
                    color: Colors.deepOrange,
                  ),
                  title: Text(
                    'رد من سند القبض رقم ${refund['source_receipt_voucher_id'] ?? '—'}',
                  ),
                  subtitle: Text(
                    'تاريخ الأصل: ${refund['source_receipt_date'] ?? '—'}'
                    '${invoice == null ? '' : ' • الفاتورة: $invoice'}'
                    '${installment == null ? '' : ' • القسط: $installment'}'
                    ' • للإيجار: ${_formatInvoiceAmount(refund['rent_refund_amount'])}'
                    ' • للضريبة: ${_formatInvoiceAmount(refund['tax_refund_amount'])}',
                  ),
                  trailing: Text(
                    _formatInvoiceAmount(refund['allocated_amount']),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              );
            }),
          ],
          if (voucher['voucher_type'] == 'قبض مستأجر' &&
              installments.isEmpty &&
              invoices.isEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'هذا السند محفوظ، لكن تفاصيل توزيعه على الأقساط لم تكن تُسجل في الإصدارات السابقة من النظام.',
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ],
      ),
    );
  }
}
