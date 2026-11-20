import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/permission_policy.dart';
import '../../database/database_helper.dart';
import '../../models/account_balance_reconciliation_report_model.dart';

class AccountBalanceReconciliationScreen extends StatefulWidget {
  const AccountBalanceReconciliationScreen({super.key, this.loader});

  final Future<AccountBalanceReconciliationReport> Function()? loader;

  @override
  State<AccountBalanceReconciliationScreen> createState() =>
      _AccountBalanceReconciliationScreenState();
}

class _AccountBalanceReconciliationScreenState
    extends State<AccountBalanceReconciliationScreen> {
  AccountBalanceReconciliationReport? _report;
  String? _error;
  bool _loading = false;
  bool _showMatched = false;
  int _generation = 0;
  int? _reportUserId;

  @override
  void initState() {
    super.initState();
    PermissionRuntime.authorizationRevision.addListener(
      _onAuthorizationChanged,
    );
  }

  void _onAuthorizationChanged() {
    _generation++;
    _report = null;
    _reportUserId = null;
    _error = null;
    _loading = false;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    PermissionRuntime.authorizationRevision.removeListener(
      _onAuthorizationChanged,
    );
    _generation++;
    super.dispose();
  }

  Future<void> _runCheck() async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) return;
    final generation = ++_generation;
    final userId = PermissionRuntime.userId;
    final role = PermissionRuntime.role;
    setState(() {
      _report = null;
      _reportUserId = null;
      _error = null;
      _loading = true;
    });

    try {
      final report = widget.loader == null
          ? await DatabaseHelper.instance.getAccountBalanceReconciliationReport()
          : await widget.loader!();
      if (!_isCurrentRequest(generation, userId, role)) return;
      setState(() {
        _report = report;
        _reportUserId = userId;
      });
    } catch (error) {
      if (!_isCurrentRequest(generation, userId, role)) return;
      setState(() => _error = 'تعذر فحص الأرصدة الداخلية: $error');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  bool _isCurrentRequest(int generation, int? userId, String? role) =>
      mounted &&
      generation == _generation &&
      PermissionRuntime.userId == userId &&
      PermissionRuntime.role == role &&
      PermissionRuntime.allows('reports', AppPermissionAction.view);

  String _amount(int minor) =>
      NumberFormat('#,##0.00;(#,##0.00)', 'en_US').format(minor / 100);

  String _accountTypeLabel(String type) => switch (type) {
    'Asset' => 'أصول',
    'Liability' => 'التزامات',
    'Equity' => 'حقوق ملكية',
    'Revenue' => 'إيرادات',
    'Expense' => 'مصروفات',
    _ => type.isEmpty ? 'غير محدد' : type,
  };

  @override
  Widget build(BuildContext context) {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
      return const Center(
        child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
      );
    }

    final report = _reportUserId == PermissionRuntime.userId ? _report : null;
    final visibleRows = report == null
        ? const <AccountBalanceReconciliationRow>[]
        : report.rows
              .where((row) => _showMatched || !row.isReconciled)
              .toList(growable: false);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'مطابقة أرصدة الحسابات الداخلية',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'فحص قراءة فقط يقارن الرصيد المخزن لكل حساب بصافي القيود المرحلة على الحساب وفروعه. لا يعدّل الأرصدة ولا يطابق كشوف البنك أو الأرصدة الفعلية؛ وقد يظهر رصيد افتتاحي تاريخي غير ممثل بقيد كفرق يحتاج مراجعة المحاسب.',
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: _loading ? null : _runCheck,
                        icon: _loading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.compare_arrows),
                        label: Text(
                          _loading ? 'جارٍ الفحص...' : 'فحص الأرصدة الآن',
                        ),
                      ),
                      if (report != null)
                        FilterChip(
                          label: const Text('إظهار الحسابات المطابقة'),
                          selected: _showMatched,
                          onSelected: (value) =>
                              setState(() => _showMatched = value),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _message(_error!, Colors.red.shade700),
          ],
          const SizedBox(height: 12),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (report == null && _error == null)
            const Expanded(
              child: Center(child: Text('اختر «فحص الأرصدة الآن» لبدء المطابقة.')),
            )
          else if (report != null) ...[
            _summary(report),
            const SizedBox(height: 10),
            if (report.reviewCount == 0 && !_showMatched)
              const Expanded(
                child: Center(
                  child: Text(
                    'لا توجد فروق داخلية مرصودة. هذا لا يثبت المطابقة مع كشوف خارجية أو أرصدة فعلية.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else if (visibleRows.isEmpty)
              const Expanded(
                child: Center(child: Text('لا توجد حسابات مطابقة للمرشح الحالي.')),
              )
            else
              Expanded(child: _table(visibleRows)),
          ] else
            const Expanded(child: Center(child: Text('تعذر إعداد الفحص.'))),
        ],
      ),
    );
  }

  Widget _summary(AccountBalanceReconciliationReport report) => Card(
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Wrap(
        spacing: 28,
        runSpacing: 12,
        children: [
          _summaryValue('عدد الحسابات', '${report.rows.length}'),
          _summaryValue('مطابق داخليًا', '${report.reconciledCount}'),
          _summaryValue('بحاجة لمراجعة', '${report.reviewCount}'),
        ],
      ),
    ),
  );

  Widget _summaryValue(String label, String value) => SizedBox(
    width: 200,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 3),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ),
  );

  Widget _table(List<AccountBalanceReconciliationRow> rows) => Card(
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStatePropertyAll(
            Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          columns: const [
            DataColumn(label: Text('الرمز')),
            DataColumn(label: Text('الحساب')),
            DataColumn(label: Text('النوع')),
            DataColumn(label: Text('الرصيد المخزن')),
            DataColumn(label: Text('صافي الدفتر')),
            DataColumn(label: Text('الفرق')),
            DataColumn(label: Text('الحالة')),
          ],
          rows: rows
              .map(
                (row) => DataRow(
                  cells: [
                    DataCell(Text(row.code)),
                    DataCell(
                      SizedBox(
                        width: 230,
                        child: Text(
                          row.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    DataCell(Text(_accountTypeLabel(row.accountType))),
                    DataCell(Text(_amount(row.storedBalanceMinor))),
                    DataCell(Text(_amount(row.ledgerBalanceMinor))),
                    DataCell(Text(_amount(row.differenceMinor))),
                    DataCell(
                      Text(
                        row.isReconciled
                            ? 'مطابق'
                            : row.isSupportedAccountType
                            ? 'يحتاج مراجعة'
                            : 'نوع الحساب غير مدعوم',
                        style: TextStyle(
                          color: row.isReconciled
                              ? Colors.green.shade700
                              : Colors.orange.shade800,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              )
              .toList(growable: false),
        ),
      ),
    ),
  );

  Widget _message(String text, Color color) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      border: Border.all(color: color.withValues(alpha: 0.35)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text, style: TextStyle(color: color)),
  );
}
