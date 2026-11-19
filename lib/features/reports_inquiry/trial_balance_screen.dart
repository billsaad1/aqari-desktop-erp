import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/permission_policy.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/print_utils.dart';
import '../../core/trial_balance_pdf.dart';
import '../../database/database_helper.dart';
import '../../models/trial_balance_report_model.dart';
import '../../providers/reports_provider.dart';

class TrialBalanceScreen extends StatefulWidget {
  const TrialBalanceScreen({super.key});

  @override
  State<TrialBalanceScreen> createState() => _TrialBalanceScreenState();
}

class _TrialBalanceScreenState extends State<TrialBalanceScreen> {
  final _startDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime.now().subtract(const Duration(days: 30))),
  );
  final _endDateController = TextEditingController(
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
      Provider.of<ReportsProvider>(context, listen: false).clearTrialBalance();
    }
    setState(() {});
  }

  @override
  void dispose() {
    PermissionRuntime.authorizationRevision.removeListener(
      _onAuthorizationChanged,
    );
    _startDateController.dispose();
    _endDateController.dispose();
    super.dispose();
  }

  Future<void> _selectDate(TextEditingController controller) async {
    final initialDate = DateTime.tryParse(controller.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected != null && mounted) {
      setState(() {
        controller.text = DateFormat('yyyy-MM-dd').format(selected);
      });
      Provider.of<ReportsProvider>(context, listen: false).clearTrialBalance();
    }
  }

  Future<void> _loadReport() async {
    final start = DateTime.tryParse(_startDateController.text);
    final end = DateTime.tryParse(_endDateController.text);
    if (start == null || end == null || start.isAfter(end)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تحقق من صحة فترة ميزان المراجعة')),
      );
      return;
    }
    await Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).loadTrialBalance(_startDateController.text, _endDateController.text);
  }

  Future<void> _preview(TrialBalanceReport report) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) return;
    try {
      final authorizationUserId = PermissionRuntime.userId;
      final authorizationRole = PermissionRuntime.role;
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      if (!mounted ||
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole ||
          !PermissionRuntime.allows('reports', AppPermissionAction.view)) {
        return;
      }
      final bytes = await TrialBalancePdf.build(
        report: report,
        companyInfo: companyInfo,
        currency: PrintUtils.currencyInArabic(report.currency),
      );
      if (!mounted ||
          PermissionRuntime.userId != authorizationUserId ||
          PermissionRuntime.role != authorizationRole ||
          !PermissionRuntime.allows('reports', AppPermissionAction.view)) {
        return;
      }
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName: 'ميزان_المراجعة_${report.startDate}_${report.endDate}',
        preferredIntent: PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تجهيز ميزان المراجعة: $error')),
        );
      }
    }
  }

  String _amount(int minor) =>
      NumberFormat('#,##0.00', 'en_US').format(minor / 100);

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, reports, child) {
        if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
          return const Center(
            child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
          );
        }
        final report = reports.trialBalanceReport;
        final start = report?.startDate == _startDateController.text;
        final end = report?.endDate == _endDateController.text;
        final isCurrentReport = report != null && start && end;

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
                        'ميزان المراجعة',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'يعرض صافي الأرصدة الافتتاحية، والحركات المرحلة خلال الفترة، والأرصدة الختامية للحسابات. لا تُحتسب القيود غير المرحلة.',
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _dateField('من تاريخ', _startDateController),
                          _dateField('إلى تاريخ', _endDateController),
                          FilledButton.icon(
                            onPressed: reports.isTrialBalanceLoading
                                ? null
                                : _loadReport,
                            icon: reports.isTrialBalanceLoading
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.assessment_outlined),
                            label: const Text('عرض الميزان'),
                          ),
                          OutlinedButton.icon(
                            onPressed: isCurrentReport
                                ? () => _preview(report)
                                : null,
                            icon: const Icon(Icons.picture_as_pdf_outlined),
                            label: const Text('معاينة التقرير'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (reports.trialBalanceErrorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _errorBox(reports.trialBalanceErrorMessage!),
                ),
              const SizedBox(height: 12),
              if (isCurrentReport) ...[
                _balanceStatus(report),
                const SizedBox(height: 10),
                _totalsCard(report),
                const SizedBox(height: 10),
                Expanded(child: _table(report)),
              ] else if (reports.isTrialBalanceLoading) ...[
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                ),
              ] else if (reports.trialBalanceErrorMessage != null) ...[
                const Expanded(
                  child: Center(
                    child: Text('تعذر إعداد التقرير؛ راجع الرسالة أعلاه.'),
                  ),
                ),
              ] else ...[
                const Expanded(
                  child: Center(
                    child: Text('حدد الفترة ثم اختر «عرض الميزان».'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _dateField(String label, TextEditingController controller) => SizedBox(
    width: 220,
    child: TextFormField(
      controller: controller,
      readOnly: true,
      onTap: () => _selectDate(controller),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.calendar_month_outlined),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        isDense: true,
      ),
    ),
  );

  Widget _balanceStatus(TrialBalanceReport report) {
    final isBalanced =
        report.openingIsBalanced &&
        report.periodIsBalanced &&
        report.closingIsBalanced;
    final color = isBalanced ? Colors.green.shade700 : Colors.red.shade700;
    final label = isBalanced
        ? 'إجمالي المدين والدائن متساويان في الافتتاح والحركة والإقفال'
        : 'الميزان غير متزن؛ راجع القيود المرحلة وتوزيعها على الحسابات';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            isBalanced ? Icons.verified_outlined : Icons.warning_amber,
            color: color,
          ),
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

  Widget _totalsCard(TrialBalanceReport report) => Card(
    elevation: 0.5,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        spacing: 24,
        runSpacing: 10,
        children: [
          _total('افتتاحي مدين', report.openingDebitMinor, report.currency),
          _total('افتتاحي دائن', report.openingCreditMinor, report.currency),
          _total('حركة مدين', report.periodDebitMinor, report.currency),
          _total('حركة دائن', report.periodCreditMinor, report.currency),
          _total('ختامي مدين', report.closingDebitMinor, report.currency),
          _total('ختامي دائن', report.closingCreditMinor, report.currency),
        ],
      ),
    ),
  );

  Widget _total(String label, int amount, String currency) => SizedBox(
    width: 150,
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

  Widget _table(TrialBalanceReport report) => Card(
    clipBehavior: Clip.antiAlias,
    elevation: 1,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    child: Scrollbar(
      thumbVisibility: true,
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(
              Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            columns: const [
              DataColumn(label: Text('رمز الحساب')),
              DataColumn(label: Text('اسم الحساب')),
              DataColumn(label: Text('افتتاحي مدين'), numeric: true),
              DataColumn(label: Text('افتتاحي دائن'), numeric: true),
              DataColumn(label: Text('حركة مدين'), numeric: true),
              DataColumn(label: Text('حركة دائن'), numeric: true),
              DataColumn(label: Text('ختامي مدين'), numeric: true),
              DataColumn(label: Text('ختامي دائن'), numeric: true),
            ],
            rows: [
              for (final row in report.rows)
                DataRow(
                  cells: [
                    DataCell(Text(row.accountCode)),
                    DataCell(Text(row.accountName)),
                    DataCell(Text(_amount(row.openingDebitMinor))),
                    DataCell(Text(_amount(row.openingCreditMinor))),
                    DataCell(Text(_amount(row.periodDebitMinor))),
                    DataCell(Text(_amount(row.periodCreditMinor))),
                    DataCell(Text(_amount(row.closingDebitMinor))),
                    DataCell(Text(_amount(row.closingCreditMinor))),
                  ],
                ),
              DataRow(
                color: WidgetStatePropertyAll(
                  Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                cells: [
                  const DataCell(Text('')),
                  const DataCell(Text('الإجمالي')),
                  DataCell(Text(_amount(report.openingDebitMinor))),
                  DataCell(Text(_amount(report.openingCreditMinor))),
                  DataCell(Text(_amount(report.periodDebitMinor))),
                  DataCell(Text(_amount(report.periodCreditMinor))),
                  DataCell(Text(_amount(report.closingDebitMinor))),
                  DataCell(Text(_amount(report.closingCreditMinor))),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );

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
