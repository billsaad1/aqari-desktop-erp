import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/permission_policy.dart';
import '../../database/database_helper.dart';
import '../../models/accounting_period_model.dart';
import '../../models/financial_close_readiness_report_model.dart';
import '../../models/internal_subledger_reconciliation_report_model.dart';

class AccountingPeriodsScreen extends StatefulWidget {
  const AccountingPeriodsScreen({super.key});

  @override
  State<AccountingPeriodsScreen> createState() =>
      _AccountingPeriodsScreenState();
}

class _AccountingPeriodsScreenState extends State<AccountingPeriodsScreen> {
  final _startController = TextEditingController();
  final _endController = TextEditingController();
  List<AccountingPeriod> _periods = const [];
  String? _error;
  bool _loading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _startController.text = DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime(today.year, today.month, 1));
    _endController.text = DateFormat('yyyy-MM-dd').format(today);
    PermissionRuntime.authorizationRevision.addListener(
      _onAuthorizationChanged,
    );
    _loadPeriods();
  }

  @override
  void dispose() {
    PermissionRuntime.authorizationRevision.removeListener(
      _onAuthorizationChanged,
    );
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  void _onAuthorizationChanged() {
    if (!mounted) return;
    if (PermissionRuntime.allows(
      'accounting_periods',
      AppPermissionAction.view,
    )) {
      _loadPeriods();
    } else {
      setState(() {
        _periods = const [];
        _error = null;
      });
    }
  }

  Future<void> _loadPeriods() async {
    if (!PermissionRuntime.allows(
      'accounting_periods',
      AppPermissionAction.view,
    )) {
      if (mounted) setState(() => _periods = const []);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final periods = await DatabaseHelper.instance.getAccountingPeriods();
      if (!mounted ||
          !PermissionRuntime.allows(
            'accounting_periods',
            AppPermissionAction.view,
          )) {
        return;
      }
      setState(() => _periods = periods);
    } catch (error) {
      if (mounted) setState(() => _error = 'تعذر تحميل الفترات: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectDate(TextEditingController controller) async {
    final initial = DateTime.tryParse(controller.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
    );
    if (selected == null || !mounted) return;
    setState(() {
      controller.text = DateFormat('yyyy-MM-dd').format(selected);
    });
  }

  Future<void> _createPeriod() async {
    if (!PermissionRuntime.allows(
      'accounting_periods',
      AppPermissionAction.add,
    )) {
      return;
    }
    setState(() => _saving = true);
    try {
      await DatabaseHelper.instance.createAccountingPeriod(
        startDate: _startController.text,
        endDate: _endController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('أُنشئت الفترة مفتوحة')));
      await _loadPeriods();
    } catch (error) {
      if (mounted) _showMessage('تعذر إنشاء الفترة: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showReadiness(AccountingPeriod period) async {
    try {
      final readiness = await DatabaseHelper.instance
          .getAccountingPeriodReadiness(period.id);
      if (!mounted ||
          !PermissionRuntime.allows(
            'accounting_periods',
            AppPermissionAction.view,
          )) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('جاهزية ${period.startDate} — ${period.endDate}'),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: _readinessContent(readiness.report),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إغلاق'),
            ),
            if (period.status == 'open' &&
                readiness.report.isReadyForManualReview &&
                PermissionRuntime.allows(
                  'accounting_periods',
                  AppPermissionAction.lockPeriod,
                ))
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _confirmAndLock(period, readiness.report);
                },
                icon: const Icon(Icons.lock_outline),
                label: const Text('تأكيد القفل'),
              ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) _showMessage('تعذر فحص جاهزية الفترة: $error');
    }
  }

  Widget _readinessContent(FinancialCloseReadinessReport report) {
    final isReady = report.isReadyForManualReview;
    final color = !isReady
        ? Colors.orange.shade800
        : report.requiresManualReviewAcknowledgement
        ? Colors.amber.shade900
        : Colors.green.shade700;
    final issues = [
      ...report.unpostedEntries,
      ...report.unbalancedPostedEntries,
    ];
    final reconciliationRows = report.internalReconciliation.rows
        .where((row) => !row.isLedgerMatched)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            border: Border.all(color: color.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            !isReady
                ? 'توجد استثناءات محاسبية أو مطابقة داخلية تمنع القفل؛ عالجها يدويًا ثم أعد الفحص.'
                : report.requiresManualReviewAcknowledgement
                ? 'اجتازت الفحوص المانعة، لكن توجد حركات تحتاج قرار مراجعة يدويًا. يلزم تسجيل ملخص القرار عند القفل؛ لا يستنتج النظام روابط غير مثبتة.'
                : 'اجتازت الفترة فحوص التوازن والمطابقة الداخلية الأساسية وتنتظر اعتماد القفل.',
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 10),
        Text('قيود غير مرحلة: ${report.unpostedEntries.length}'),
        Text('قيود مرحلة غير متوازنة: ${report.unbalancedPostedEntries.length}'),
        Text('استثناءات المطابقة الداخلية المانعة: ${report.blockingReconciliationCount}'),
        Text('استثناءات تتطلب إقرار مراجعة: ${report.manualReviewAcknowledgementCount}'),
        Text('بنود تاريخية للمراجعة والإقرار: ${report.legacyReviewCount}'),
        const SizedBox(height: 8),
        const Text(
          'يشمل الفحص اتساق المستندات الفرعية مع الأستاذ. لا ينشئ النظام قيود تصحيح أو قيد إقفال أرباح وخسائر، ولا يستنتج روابط تاريخية مفقودة.',
        ),
        if (issues.isNotEmpty) ...[
          const Divider(),
          for (final issue in issues)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${issue.statusLabel} — #${issue.journalEntryId}'),
              subtitle: Text(
                '${issue.entryDate} • ${issue.description.isEmpty ? 'بلا بيان' : issue.description}\nمدين ${_money(issue.debitMinor)} | دائن ${_money(issue.creditMinor)}',
              ),
          ),
        ],
        if (reconciliationRows.isNotEmpty) ...[
          const Divider(),
          for (final row in reconciliationRows)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${row.source.label} — #${row.sourceId} • ${row.state.label}',
              ),
              subtitle: Text(
                '${row.sourceDate} • ${row.partyName}\n${row.issueSummary}',
              ),
              trailing: Text(_money(row.amountMinor)),
            ),
        ],
      ],
    );
  }

  Future<void> _confirmAndLock(
    AccountingPeriod period,
    FinancialCloseReadinessReport report,
  ) async {
    var reason = '';
    if (report.requiresManualReviewAcknowledgement) {
      final reviewReason = await _askReason(
        title: 'إقرار مراجعة الاستثناءات الداخلية',
        label: 'ملخص المراجعة أو الاعتماد (إلزامي)',
        requiredReason: true,
      );
      if (reviewReason == null || !mounted) return;
      reason = reviewReason;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('قفل الفترة للترحيل؟'),
        content: Text(
          'سيمنع النظام إضافة أو تعديل أو حذف القيود بتاريخ ${period.startDate} إلى ${period.endDate}. سيُعاد فحص الجاهزية داخل معاملة القفل نفسها.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('قفل الفترة'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _performPeriodAction(
      () => DatabaseHelper.instance.lockAccountingPeriod(
        period.id,
        reason: reason,
      ),
      'قُفلت الفترة؛ لن تُرحّل قيود جديدة ضمن نطاقها.',
    );
  }

  Future<void> _confirmAndClose(AccountingPeriod period) async {
    final reason = await _askReason(
      title: 'الإقفال النهائي',
      label: 'ملاحظة الإقفال (اختيارية)',
      requiredReason: false,
    );
    if (reason == null || !mounted) return;
    final confirmed = await _confirm(
      title: 'اعتماد إقفال الفترة؟',
      message:
          'سيُسجل اعتماد الإقفال النهائي للفترة ${period.startDate} إلى ${period.endDate}. لا ينشئ هذا الإجراء قيد إقفال للأرباح والخسائر.',
      actionLabel: 'اعتماد الإقفال',
    );
    if (!confirmed || !mounted) return;
    await _performPeriodAction(
      () => DatabaseHelper.instance.closeAccountingPeriod(
        period.id,
        reason: reason,
      ),
      'اعتُمد الإقفال النهائي للفترة.',
    );
  }

  Future<void> _confirmAndReopen(AccountingPeriod period) async {
    final reason = await _askReason(
      title: 'إعادة فتح الفترة',
      label: 'سبب إعادة الفتح (إلزامي)',
      requiredReason: true,
    );
    if (reason == null || !mounted) return;
    final confirmed = await _confirm(
      title: 'إعادة فتح الفترة؟',
      message:
          'سيُسمح مجددًا بالترحيل ضمن الفترة ${period.startDate} إلى ${period.endDate}. سيُحفظ السبب واسم المستخدم ووقت العملية في سجل غير قابل للتعديل من التطبيق.',
      actionLabel: 'إعادة الفتح',
    );
    if (!confirmed || !mounted) return;
    await _performPeriodAction(
      () => DatabaseHelper.instance.reopenAccountingPeriod(
        period.id,
        reason: reason,
      ),
      'أُعيد فتح الفترة مع تسجيل السبب والتدقيق.',
    );
  }

  Future<String?> _askReason({
    required String title,
    required String label,
    required bool requiredReason,
  }) async {
    final controller = TextEditingController();
    var missingReason = false;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 500,
            maxLines: 3,
            onChanged: (value) {
              if (value.trim().isNotEmpty && missingReason) {
                setDialogState(() => missingReason = false);
              }
            },
            decoration: InputDecoration(
              labelText: label,
              errorText: missingReason ? 'هذا الحقل مطلوب' : null,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (requiredReason && value.isEmpty) {
                  setDialogState(() => missingReason = true);
                  return;
                }
                Navigator.pop(dialogContext, value);
              },
              child: const Text('متابعة'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String actionLabel,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(actionLabel),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _performPeriodAction(
    Future<void> Function() action,
    String successMessage,
  ) async {
    setState(() => _saving = true);
    try {
      await action();
      if (!mounted) return;
      _showMessage(successMessage);
      await _loadPeriods();
    } catch (error) {
      if (mounted) _showMessage('تعذر تنفيذ العملية: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _showEvents(AccountingPeriod period) async {
    try {
      final events = await DatabaseHelper.instance.getAccountingPeriodEvents(
        period.id,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('سجل أحداث الفترة'),
          content: SizedBox(
            width: 500,
            child: events.isEmpty
                ? const Text('لا توجد أحداث مسجلة.')
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: events.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final event = events[index];
                      return ListTile(
                        title: Text(event.actionLabel),
                        subtitle: Text(
                          '${event.createdAt}\n${event.actorName}${event.reason == null ? '' : '\nالسبب: ${event.reason}'}',
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) _showMessage('تعذر تحميل سجل الفترة: $error');
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String _money(int minor) =>
      NumberFormat('#,##0.00;(#,##0.00)', 'en_US').format(minor / 100);

  Color _statusColor(String status) => switch (status) {
    'open' => Colors.blue.shade700,
    'locked' => Colors.orange.shade800,
    'closed' => Colors.green.shade700,
    _ => Colors.grey,
  };

  Widget _dateButton(String label, TextEditingController controller) =>
      OutlinedButton.icon(
        onPressed: _saving ? null : () => _selectDate(controller),
        icon: const Icon(Icons.calendar_month_outlined),
        label: Text('$label: ${controller.text}'),
      );

  Widget _periodCard(AccountingPeriod period) {
    final statusColor = _statusColor(period.status);
    final canLock = period.status == 'open' &&
        PermissionRuntime.allows(
          'accounting_periods',
          AppPermissionAction.lockPeriod,
        );
    final canClose = period.status == 'locked' &&
        PermissionRuntime.allows(
          'accounting_periods',
          AppPermissionAction.closePeriod,
        );
    final canReopen = period.status != 'open' &&
        PermissionRuntime.allows(
          'accounting_periods',
          AppPermissionAction.reopenPeriod,
        );
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${period.startDate} — ${period.endDate}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Chip(
                  label: Text(period.statusLabel),
                  side: BorderSide(color: statusColor.withValues(alpha: 0.3)),
                  labelStyle: TextStyle(color: statusColor),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (canLock)
                  FilledButton.tonalIcon(
                    onPressed: _saving ? null : () => _showReadiness(period),
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('فحص الجاهزية والقفل'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _saving ? null : () => _showReadiness(period),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('فحص الجاهزية'),
                  ),
                if (canClose)
                  FilledButton.icon(
                    onPressed: _saving ? null : () => _confirmAndClose(period),
                    icon: const Icon(Icons.task_alt),
                    label: const Text('إقفال نهائي'),
                  ),
                if (canReopen)
                  OutlinedButton.icon(
                    onPressed: _saving ? null : () => _confirmAndReopen(period),
                    icon: const Icon(Icons.lock_open_outlined),
                    label: const Text('إعادة فتح'),
                  ),
                TextButton.icon(
                  onPressed: _saving ? null : () => _showEvents(period),
                  icon: const Icon(Icons.history),
                  label: const Text('سجل الأحداث'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!PermissionRuntime.allows(
      'accounting_periods',
      AppPermissionAction.view,
    )) {
      return const Center(
        child: Text('لا تملك صلاحية عرض وإدارة الفترات المحاسبية.'),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - 36),
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
                        'جاهزية الفترات وقفلها',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'تُفحص الجاهزية أولًا، ثم يُقفل الترحيل للفترة، ثم يعتمد الإقفال النهائي. كل انتقال يُسجل بمستخدمه ووقته. إعادة الفتح تتطلب صلاحية مستقلة وسببًا. لا ينشئ الإقفال قيد أرباح وخسائر.',
                      ),
                      const SizedBox(height: 12),
                      if (PermissionRuntime.allows(
                        'accounting_periods',
                        AppPermissionAction.add,
                      ))
                        Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _dateButton('من', _startController),
                            _dateButton('إلى', _endController),
                            FilledButton.icon(
                              onPressed: _saving ? null : _createPeriod,
                              icon: const Icon(Icons.add),
                              label: const Text('إنشاء فترة مفتوحة'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                _messageBox(_error!, Colors.red.shade700),
              ],
              const SizedBox(height: 10),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_periods.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('لا توجد فترات محاسبية مسجلة.')),
                )
              else
                for (final period in _periods) _periodCard(period),
            ],
          ),
        ),
      ),
    );
  }

  Widget _messageBox(String text, Color color) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      border: Border.all(color: color.withValues(alpha: 0.25)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text, style: TextStyle(color: color)),
  );
}
