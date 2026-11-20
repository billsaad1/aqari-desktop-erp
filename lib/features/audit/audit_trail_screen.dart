import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/app_theme.dart';
import '../../core/erp_data_table.dart';
import '../../core/permission_policy.dart';
import '../../database/database_helper.dart';

/// Read-only viewer for the append-only financial audit trail.
///
/// The screen can never mutate the trail: the table is guarded by SQLite
/// triggers and the query layer only exposes SELECTs.
class AuditTrailScreen extends StatefulWidget {
  const AuditTrailScreen({super.key});

  static const _entityTypes = <String, String>{
    'journal_entry': 'قيد يومية',
    'voucher': 'سند',
    'tax_invoice': 'فاتورة ضريبية',
    'contract': 'عقد',
    'account': 'حساب',
    'user': 'مستخدم',
    'session': 'جلسة',
    'tenant_notice': 'إشعار مستأجر',
    'property_sale_review': 'مراجعة بيع عقار',
    'property_sale_execution': 'تنفيذ بيع عقار',
    'owner_settlement': 'سداد مستحقات مالك',
  };

  static const _actionLabels = <String, String>{
    'JOURNAL_ENTRY_POSTED': 'ترحيل قيد يومية',
    'GENERAL_VOUCHER_POSTED': 'ترحيل سند عام',
    'OWNER_SETTLEMENT_POSTED': 'ترحيل سند سداد مالك',
    'TENANT_RECEIPT_POSTED': 'ترحيل سند قبض مستأجر',
    'TENANT_REFUND_POSTED': 'ترحيل استرداد مستأجر',
    'CREDIT_NOTE_DRAFT_CREATED': 'إنشاء مسودة إشعار دائن',
    'CREDIT_NOTE_POSTED': 'ترحيل إشعار دائن',
    'CREDIT_NOTE_REVERSED': 'عكس إشعار دائن بقيد',
    'TAX_INVOICE_ISSUED': 'إصدار فاتورة ضريبية',
    'CONTRACT_CREATED': 'إنشاء عقد',
    'CONTRACT_RENEWED': 'تجديد عقد',
    'contract_cancelled': 'إلغاء عقد',
    'ACCOUNT_CREATE': 'إنشاء حساب',
    'ACCOUNT_RENAME': 'تعديل اسم حساب',
    'ACCOUNT_DELETE': 'حذف حساب',
    'USER_CREATE': 'إنشاء مستخدم',
    'USER_UPDATE': 'تعديل مستخدم',
    'USER_PERMISSIONS_UPDATE': 'تعديل صلاحيات',
    'LOGIN': 'تسجيل دخول',
    'LOGOUT': 'تسجيل خروج',
    'PROPERTY_SALE_EXECUTED': 'تنفيذ بيع ونقل ملكية',
    'PROPERTY_SALE_accounting_approved': 'اعتماد التسوية المحاسبية للبيع',
    'PROPERTY_SALE_accounting_corrected': 'تصحيح موثق لتسوية البيع',
    'LEGACY_TENANT_PAYMENT_MARKED_UNRELATED': 'تصنيف سند قديم كغير متعلق',
    'LEGACY_TENANT_PAYMENT_RECONCILED_AS_REFUND': 'مطابقة سند قديم كاسترداد',
    'LEGACY_INVOICE_LINKED_TO_INSTALLMENT': 'ربط فاتورة قديمة بقسط',
    'LEGACY_INVOICE_MARKED_NON_BILLABLE': 'تصنيف فاتورة قديمة كغير مستحقة',
    'USER_ACTIVATE': 'تفعيل مستخدم',
    'USER_DEACTIVATE': 'إيقاف مستخدم',
    'ACCOUNTING_PERIOD_CREATED': 'إنشاء فترة محاسبية',
    'ACCOUNTING_PERIOD_LOCKED': 'قفل فترة محاسبية للترحيل',
    'ACCOUNTING_PERIOD_CLOSED': 'إقفال فترة محاسبية نهائيًا',
    'ACCOUNTING_PERIOD_REOPENED': 'إعادة فتح فترة محاسبية',
    'created': 'إنشاء الفترة',
    'locked': 'قفل الفترة للترحيل',
    'closed': 'الإقفال النهائي للفترة',
    'reopened': 'إعادة فتح الفترة',
  };

  /// Public so tests can assert every persisted action code stays labelled.
  static String actionLabel(String action) {
    final direct = _actionLabels[action];
    if (direct != null) return direct;
    if (action.startsWith('tenant_notice_')) {
      return 'إشعار مستأجر: ${action.substring('tenant_notice_'.length)}';
    }
    if (action.startsWith('property_sale_review_')) {
      return 'مراجعة بيع: ${action.substring('property_sale_review_'.length)}';
    }
    return action;
  }

  @override
  State<AuditTrailScreen> createState() => _AuditTrailScreenState();
}

class _AuditTrailScreenState extends State<AuditTrailScreen> {
  final _searchController = TextEditingController();
  final _fromController = TextEditingController();
  final _toController = TextEditingController();

  List<Map<String, dynamic>> _rows = const [];
  List<String> _actions = const [];
  String? _selectedAction;
  String? _selectedEntityType;
  bool _isLoading = true;
  String? _error;
  String _currency = 'ريال يمني';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  /// Rows requested per load. The query layer caps this; the UI must say so.
  static const _pageSize = 500;

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final rows = await DatabaseHelper.instance.getAuditTrail(
        fromDate: _fromController.text.trim().isEmpty
            ? null
            : _fromController.text.trim(),
        toDate: _toController.text.trim().isEmpty
            ? null
            : _toController.text.trim(),
        action: _selectedAction,
        entityType: _selectedEntityType,
        search: _searchController.text,
        limit: _pageSize,
      );
      final actions = await DatabaseHelper.instance.getAuditTrailActions();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _actions = actions;
        _isLoading = false;
      });
      await _loadCurrency();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is StateError
            ? error.message
            : 'تعذر تحميل سجل التدقيق؛ تحقق من صلاحيتك وبيانات الفترة';
        _isLoading = false;
      });
    }
  }

  Future<void> _loadCurrency() async {
    try {
      final company = await DatabaseHelper.instance.getCompanyInfo();
      final text = company?['default_currency']?.toString().trim() ?? '';
      if (!mounted || text.isEmpty) return;
      setState(() => _currency = text);
    } catch (_) {
      // Currency is cosmetic here; the audit rows remain authoritative.
    }
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(controller.text) ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null) return;
    controller.text = DateFormat('yyyy-MM-dd').format(picked);
    await _load();
  }

  String _formatMinor(Object? value) {
    if (value == null) return '—';
    final minor = (value as num).toInt();
    return '${NumberFormat('#,##0.00', 'en').format(minor / 100)} $_currency';
  }

  String _formatTimestamp(Object? value) {
    final text = value?.toString() ?? '';
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return text;
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(parsed);
  }

  String _formatDetails(Object? value) {
    final text = value?.toString() ?? '';
    if (text.isEmpty) return '—';
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return decoded.entries
            .map((entry) => '${entry.key}: ${entry.value}')
            .join(' • ');
      }
      return decoded.toString();
    } catch (_) {
      return text;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!PermissionRuntime.allows('audit_logs', AppPermissionAction.view)) {
      return const Center(
        child: Text('لا تملك صلاحية عرض سجل التدقيق المالي'),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'سجل التدقيق المالي',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: AppPalette.navy,
                  ),
                ),
              ),
              IconButton(
                onPressed: _isLoading ? null : _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'تحديث',
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'قراءة فقط. السجل يُضاف إليه ولا يُعدّل ولا يُحذف من داخل التطبيق؛ '
            'الحماية على مستوى التطبيق/SQLite ولا تحمي الملف ممن يملك وصولًا مباشرًا إليه.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    labelText: 'بحث في الحدث أو التفاصيل',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _load(),
                ),
              ),
              SizedBox(
                width: 160,
                child: TextField(
                  controller: _fromController,
                  readOnly: true,
                  onTap: () => _pickDate(_fromController),
                  decoration: const InputDecoration(
                    labelText: 'من تاريخ',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              SizedBox(
                width: 160,
                child: TextField(
                  controller: _toController,
                  readOnly: true,
                  onTap: () => _pickDate(_toController),
                  decoration: const InputDecoration(
                    labelText: 'إلى تاريخ',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String?>(
                  initialValue: _selectedAction,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'نوع الحدث',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('الكل'),
                    ),
                    for (final action in _actions)
                      DropdownMenuItem<String?>(
                        value: action,
                        child: Text(
                          AuditTrailScreen.actionLabel(action),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    setState(() => _selectedAction = value);
                    _load();
                  },
                ),
              ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String?>(
                  initialValue: _selectedEntityType,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'نوع الكيان',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('الكل'),
                    ),
                    for (final entry in AuditTrailScreen._entityTypes.entries)
                      DropdownMenuItem<String?>(
                        value: entry.key,
                        child: Text(
                          entry.value,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    setState(() => _selectedEntityType = value);
                    _load();
                  },
                ),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  _searchController.clear();
                  _fromController.clear();
                  _toController.clear();
                  setState(() {
                    _selectedAction = null;
                    _selectedEntityType = null;
                  });
                  _load();
                },
                icon: const Icon(Icons.filter_alt_off, size: 18),
                label: const Text('مسح المرشحات'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: _load, child: const Text('إعادة المحاولة')),
          ],
        ),
      );
    }
    if (_rows.isEmpty) {
      return const Center(child: Text('لا توجد أحداث مطابقة للمرشحات'));
    }
    final truncated = _rows.length >= _pageSize;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (truncated)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'تُعرض أحدث $_pageSize حادثة فقط؛ ضيّق الفترة الزمنية لعرض بقية السجل',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ErpDataTable(
            showCheckboxColumn: false,
        columns: const [
          DataColumn(label: Text('الوقت')),
          DataColumn(label: Text('الحدث')),
          DataColumn(label: Text('الكيان')),
          DataColumn(label: Text('المبلغ')),
          DataColumn(label: Text('المستخدم')),
          DataColumn(label: Text('التفاصيل')),
        ],
        rows: [
          for (final row in _rows)
            DataRow(
              cells: [
                DataCell(Text(_formatTimestamp(row['timestamp']))),
                DataCell(Text(AuditTrailScreen.actionLabel(row['action'] as String? ?? ''))),
                DataCell(
                  Text(
                    row['entity_type'] == null
                        ? '—'
                        : '${AuditTrailScreen._entityTypes[row['entity_type']] ?? row['entity_type']}'
                              '#${row['entity_id'] ?? ''}',
                  ),
                ),
                DataCell(Text(_formatMinor(row['amount_minor']))),
                DataCell(Text(row['user_name']?.toString() ?? 'غير محدد')),
                DataCell(
                  SizedBox(
                    width: 320,
                    child: Text(
                      _formatDetails(row['details']),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        ],
      ),
    );
  }
}
