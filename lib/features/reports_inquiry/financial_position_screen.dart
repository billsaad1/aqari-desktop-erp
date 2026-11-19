import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/financial_position_pdf.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/permission_policy.dart';
import '../../core/print_utils.dart';
import '../../database/database_helper.dart';
import '../../models/financial_position_report_model.dart';
import '../../providers/reports_provider.dart';

class FinancialPositionScreen extends StatefulWidget {
  const FinancialPositionScreen({super.key});

  @override
  State<FinancialPositionScreen> createState() =>
      _FinancialPositionScreenState();
}

class _FinancialPositionScreenState extends State<FinancialPositionScreen> {
  final _asOfDateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );

  @override
  void initState() {
    super.initState();
    PermissionRuntime.authorizationRevision.addListener(
      _onAuthorizationChanged,
    );
  }

  void _onAuthorizationChanged() {
    if (!mounted) return;
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).clearFinancialPositionReport();
    }
    setState(() {});
  }

  @override
  void dispose() {
    PermissionRuntime.authorizationRevision.removeListener(
      _onAuthorizationChanged,
    );
    _asOfDateController.dispose();
    super.dispose();
  }

  Future<void> _selectDate() async {
    final initialDate =
        DateTime.tryParse(_asOfDateController.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _asOfDateController.text = DateFormat('yyyy-MM-dd').format(selected);
    });
    Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).clearFinancialPositionReport();
  }

  Future<void> _loadReport() async {
    final value = _asOfDateController.text;
    final parsed = DateTime.tryParse(value);
    if (parsed == null || DateFormat('yyyy-MM-dd').format(parsed) != value) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تحقق من صحة تاريخ قائمة المركز المالي')),
      );
      return;
    }
    await Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).loadFinancialPositionReport(value);
  }

  Future<void> _preview(FinancialPositionReport report) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) return;
    final reports = Provider.of<ReportsProvider>(context, listen: false);
    final reportGeneration = reports.financialPositionReportGeneration;
    bool isCurrent() =>
        mounted &&
        reports.financialPositionReport == report &&
        reports.financialPositionReportGeneration == reportGeneration &&
        _asOfDateController.text == report.asOfDate &&
        PermissionRuntime.allows('reports', AppPermissionAction.view);

    try {
      final authorizationUserId = PermissionRuntime.userId;
      final authorizationRole = PermissionRuntime.role;
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      if (!isCurrent() ||
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole) {
        return;
      }
      final bytes = await FinancialPositionPdf.build(
        report: report,
        companyInfo: companyInfo,
        currency: PrintUtils.currencyInArabic(report.currency),
      );
      if (!isCurrent() ||
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole) {
        return;
      }
      if (!mounted) return;
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName: 'قائمة_المركز_المالي_${report.asOfDate}',
        preferredIntent: PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تجهيز قائمة المركز المالي: $error')),
        );
      }
    }
  }

  String _amount(int minor) =>
      NumberFormat('#,##0.00;(#,##0.00)', 'en_US').format(minor / 100);

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, reports, child) {
        if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
          return const Center(
            child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
          );
        }
        final report = reports.financialPositionReport;
        final isCurrentReport =
            report != null && report.asOfDate == _asOfDateController.text;

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
                        'قائمة المركز المالي الداخلية',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 5),
                      const Text(
                        'تُحتسب الأرصدة التراكمية حتى التاريخ المحدد من دفتر الأستاذ للقيود المرحلة فقط. تُعرض نتيجة الإيرادات والمصروفات غير المقفلة منفصلة؛ لا يُنشئ التقرير قيودًا ولا يضيف رصيدًا افتراضيًا لإجبار التوازن.',
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: 230,
                            child: TextFormField(
                              controller: _asOfDateController,
                              readOnly: true,
                              onTap: _selectDate,
                              decoration: InputDecoration(
                                labelText: 'حتى تاريخ',
                                prefixIcon: const Icon(
                                  Icons.calendar_month_outlined,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                isDense: true,
                              ),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: reports.isFinancialPositionReportLoading
                                ? null
                                : _loadReport,
                            icon: reports.isFinancialPositionReportLoading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.account_balance_outlined),
                            label: const Text('عرض القائمة'),
                          ),
                          OutlinedButton.icon(
                            onPressed: isCurrentReport
                                ? () => _preview(report)
                                : null,
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const Text('معاينة / حفظ PDF'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (reports.financialPositionReportErrorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _errorBox(
                    reports.financialPositionReportErrorMessage!,
                  ),
                ),
              const SizedBox(height: 12),
              if (isCurrentReport) ...[
                _balanceStatus(report),
                const SizedBox(height: 10),
                _totalsCard(report),
                const SizedBox(height: 10),
                Expanded(child: _reportTables(report)),
              ] else if (reports.isFinancialPositionReportLoading) ...[
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                ),
              ] else if (reports.financialPositionReportErrorMessage !=
                  null) ...[
                const Expanded(
                  child: Center(
                    child: Text('تعذر إعداد التقرير؛ راجع الرسالة أعلاه.'),
                  ),
                ),
              ] else ...[
                const Expanded(
                  child: Center(
                    child: Text('حدد التاريخ ثم اختر «عرض القائمة». '),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _balanceStatus(FinancialPositionReport report) {
    final Color color;
    final IconData icon;
    final String label;
    if (report.hasUnclassifiedAccounts) {
      color = Colors.orange.shade800;
      icon = Icons.warning_amber_rounded;
      label =
          'تحتاج القائمة إلى مراجعة: ${report.unclassifiedRows.length} حسابًا غير مصنف. لم يُضف رصيد موازن افتراضي.';
    } else if (report.isAccountingEquationBalanced) {
      color = Colors.green.shade700;
      icon = Icons.verified_outlined;
      label = 'المعادلة متوازنة وفق تصنيف الحسابات المسجل في دليل الحسابات.';
    } else {
      color = Colors.red.shade700;
      icon = Icons.error_outline;
      label =
          'المعادلة غير متوازنة؛ راجع القيود والأرصدة. الفرق: ${_amount(report.equationDifferenceMinor)} ${PrintUtils.currencyInArabic(report.currency)}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _totalsCard(FinancialPositionReport report) => Card(
    elevation: 0.5,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 22,
        runSpacing: 10,
        children: [
          _total('الأصول', report.assetsMinor, report.currency),
          _total('الخصوم', report.liabilitiesMinor, report.currency),
          _total(
            'حقوق الملكية المسجلة',
            report.equityAccountsMinor,
            report.currency,
          ),
          _total('الإيرادات', report.revenuesMinor, report.currency),
          _total('المصروفات', report.expensesMinor, report.currency),
          _total(
            'النتيجة غير المقفلة',
            report.unclosedEarningsMinor,
            report.currency,
          ),
          _total(
            'الخصوم وحقوق الملكية',
            report.liabilitiesAndEquityMinor,
            report.currency,
          ),
          _total(
            'فرق المعادلة',
            report.equationDifferenceMinor,
            report.currency,
          ),
        ],
      ),
    ),
  );

  Widget _total(String label, int amount, String currency) => SizedBox(
    width: 180,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(
          '${_amount(amount)} ${PrintUtils.currencyInArabic(currency)}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ],
    ),
  );

  Widget _reportTables(FinancialPositionReport report) => Card(
    clipBehavior: Clip.antiAlias,
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _accountSection('الأصول', report.assetRows),
            _accountSection('الخصوم', report.liabilityRows),
            _accountSection('حقوق الملكية المسجلة', report.equityRows),
            _accountSection(
              'الإيرادات غير المقفلة',
              report.revenueRows,
              note: 'تُعرض منفصلة ولا تُعامل كحساب حقوق ملكية مسجل.',
            ),
            _accountSection(
              'المصروفات غير المقفلة',
              report.expenseRows,
              note: 'تُعرض منفصلة ولا تُعامل كحساب حقوق ملكية مسجل.',
            ),
            _accountSection(
              'حسابات غير مصنفة',
              report.unclassifiedRows,
              note:
                  'لا تدخل هذه الحسابات في إجماليات الأصول أو الخصوم أو حقوق الملكية.',
            ),
            if (report.rows.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text('لا توجد أرصدة مرحلة حتى التاريخ المحدد.'),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _accountSection(
    String title,
    List<FinancialPositionAccountRow> rows, {
    String? note,
  }) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final subtotal = rows.fold<int>(
      0,
      (sum, row) => sum + row.normalBalanceMinor,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 3, bottom: 4),
              child: Text(note, style: Theme.of(context).textTheme.bodySmall),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: WidgetStatePropertyAll(
                Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              columns: const [
                DataColumn(label: Text('الرمز')),
                DataColumn(label: Text('الحساب')),
                DataColumn(label: Text('الرصيد الطبيعي'), numeric: true),
              ],
              rows: [
                for (final row in rows)
                  DataRow(
                    cells: [
                      DataCell(Text(row.accountCode)),
                      DataCell(Text(row.accountName)),
                      DataCell(Text(_amount(row.normalBalanceMinor))),
                    ],
                  ),
                DataRow(
                  color: WidgetStatePropertyAll(
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  cells: [
                    const DataCell(Text('')),
                    DataCell(Text('إجمالي $title')),
                    DataCell(Text(_amount(subtotal))),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBox(String message) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
    ),
  );
}
