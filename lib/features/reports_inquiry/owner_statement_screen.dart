import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/account_statement_pdf.dart';
import '../../core/permission_policy.dart';
import '../../core/pdf_preview_dialog.dart';
import '../../core/print_utils.dart';
import '../../database/database_helper.dart';
import '../../models/account_statement_report_model.dart';
import '../../models/owner_statement_account_model.dart';
import '../../providers/reports_provider.dart';

class OwnerStatementScreen extends StatefulWidget {
  const OwnerStatementScreen({super.key});

  @override
  State<OwnerStatementScreen> createState() => _OwnerStatementScreenState();
}

class _OwnerStatementScreenState extends State<OwnerStatementScreen> {
  final _startDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime.now().subtract(const Duration(days: 30))),
  );
  final _endDateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  int? _selectedOwnerId;

  @override
  void initState() {
    super.initState();
    PermissionRuntime.authorizationRevision.addListener(
      _onAuthorizationChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !PermissionRuntime.allows('reports', AppPermissionAction.view)) {
        return;
      }
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).loadOwnerStatementAccounts();
    });
  }

  void _onAuthorizationChanged() {
    if (!mounted) return;
    final reports = Provider.of<ReportsProvider>(context, listen: false);
    if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
      reports.clearOwnerStatement();
      setState(() => _selectedOwnerId = null);
      return;
    }
    if (!reports.ownerStatementAccountsLoaded &&
        !reports.isOwnerAccountsLoading) {
      reports.loadOwnerStatementAccounts();
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

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadStatement() async {
    final ownerId = _selectedOwnerId;
    final start = DateTime.tryParse(_startDateController.text);
    final end = DateTime.tryParse(_endDateController.text);
    if (ownerId == null) {
      _showMessage('اختر مالكًا أولًا');
      return;
    }
    if (start == null || end == null || start.isAfter(end)) {
      _showMessage('تحقق من صحة الفترة الزمنية');
      return;
    }
    await Provider.of<ReportsProvider>(
      context,
      listen: false,
    ).loadOwnerStatement(
      ownerId,
      _startDateController.text,
      _endDateController.text,
    );
  }

  Future<void> _selectDate(TextEditingController controller) async {
    final initial = DateTime.tryParse(controller.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => controller.text = DateFormat('yyyy-MM-dd').format(picked));
      Provider.of<ReportsProvider>(
        context,
        listen: false,
      ).clearOwnerStatementReport();
    }
  }

  Future<void> _printStatement(
    AccountStatementReport report,
    OwnerStatementAccount owner, {
    required bool saveAsPdf,
  }) async {
    if (!PermissionRuntime.allows('reports', AppPermissionAction.print)) {
      _showMessage('لا تملك صلاحية طباعة أو حفظ التقارير');
      return;
    }
    try {
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      final bytes = await AccountStatementPdf.build(
        report: report,
        companyInfo: companyInfo,
        currency: PrintUtils.currencyInArabic(report.currency),
        statementTitle: 'كشف حساب المالك',
        partyLabel: 'المالك',
        partyName: owner.ownerName,
        accountLabel: 'حساب الملاك الجاري',
      );
      if (!mounted) return;
      await PdfDocumentPreviewDialog.show(
        context: context,
        bytes: bytes,
        fileName:
            'كشف_حساب_المالك_${owner.ownerId}_${report.startDate}_${report.endDate}',
        preferredIntent: saveAsPdf
            ? PdfPreviewIntent.save
            : PdfPreviewIntent.printDocument,
        permissionModule: 'reports',
      );
    } catch (error) {
      if (mounted) _showMessage('تعذر تجهيز كشف المالك: $error');
    }
  }

  String _amount(double value) => NumberFormat('#,##0.00').format(value);

  @override
  Widget build(BuildContext context) {
    return Consumer<ReportsProvider>(
      builder: (context, reports, child) {
        if (!PermissionRuntime.allows('reports', AppPermissionAction.view)) {
          return const Center(
            child: Text('لا تملك صلاحية عرض التقارير والاستعلامات.'),
          );
        }

        final owners = reports.ownerStatementAccounts;
        OwnerStatementAccount? selectedOwner;
        for (final owner in owners) {
          if (owner.ownerId == _selectedOwnerId) {
            selectedOwner = owner;
            break;
          }
        }
        final report = reports.ownerStatementReport;
        final isCurrentReport =
            selectedOwner != null &&
            report != null &&
            report.accountId == selectedOwner.accountId &&
            report.startDate == _startDateController.text &&
            report.endDate == _endDateController.text;
        final visibleReport = isCurrentReport ? report : null;
        final reportForActions = visibleReport;
        final ownerForActions = selectedOwner;
        final canPrint = PermissionRuntime.allows(
          'reports',
          AppPermissionAction.print,
        );

        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'كشف حساب المالك',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'الرصيد الدائن موجب ويعبر عن مبلغ مستحق للمالك، بينما الرصيد المدين يعبر عن عكس ذلك. للسداد استخدم تبويب «سداد مستحقات المالك» في المحاسبة؛ يعتمد فقط الرصيد المرحّل ولا يقدّر الإيجار أو العمولة تلقائيًا.',
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 350,
                    child: DropdownButtonFormField<int>(
                      initialValue:
                          owners.any(
                            (owner) => owner.ownerId == _selectedOwnerId,
                          )
                          ? _selectedOwnerId
                          : null,
                      isExpanded: true,
                      items: owners
                          .map(
                            (owner) => DropdownMenuItem<int>(
                              value: owner.ownerId,
                              enabled: owner.isReportable,
                              child: Text(
                                owner.isReportable
                                    ? owner.ownerName
                                    : '${owner.ownerName} — لا يرتبط بحساب التزامات تفصيلي',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged:
                          reports.isOwnerAccountsLoading || owners.isEmpty
                          ? null
                          : (value) {
                              reports.clearOwnerStatementReport();
                              setState(() => _selectedOwnerId = value);
                            },
                      decoration: const InputDecoration(
                        labelText: 'اختر المالك',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 160,
                    child: TextFormField(
                      controller: _startDateController,
                      decoration: const InputDecoration(
                        labelText: 'من تاريخ',
                        border: OutlineInputBorder(),
                      ),
                      readOnly: true,
                      onTap: () => _selectDate(_startDateController),
                    ),
                  ),
                  SizedBox(
                    width: 160,
                    child: TextFormField(
                      controller: _endDateController,
                      decoration: const InputDecoration(
                        labelText: 'إلى تاريخ',
                        border: OutlineInputBorder(),
                      ),
                      readOnly: true,
                      onTap: () => _selectDate(_endDateController),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed:
                        reports.isOwnerAccountsLoading ||
                            reports.isOwnerStatementLoading
                        ? null
                        : _loadStatement,
                    icon: reports.isOwnerStatementLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: const Text('عرض الكشف'),
                  ),
                  ElevatedButton.icon(
                    onPressed:
                        reportForActions != null &&
                            ownerForActions != null &&
                            canPrint
                        ? () => _printStatement(
                            reportForActions,
                            ownerForActions,
                            saveAsPdf: false,
                          )
                        : null,
                    icon: const Icon(Icons.print),
                    label: const Text('طباعة'),
                  ),
                  OutlinedButton.icon(
                    onPressed:
                        reportForActions != null &&
                            ownerForActions != null &&
                            canPrint
                        ? () => _printStatement(
                            reportForActions,
                            ownerForActions,
                            saveAsPdf: true,
                          )
                        : null,
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('حفظ PDF'),
                  ),
                ],
              ),
              if (reports.isOwnerAccountsLoading)
                const LinearProgressIndicator(),
              if (reports.ownerAccountsErrorMessage != null)
                _errorPanel(
                  reports.ownerAccountsErrorMessage!,
                  () => reports.loadOwnerStatementAccounts(),
                ),
              if (reports.ownerStatementErrorMessage != null)
                _errorPanel(reports.ownerStatementErrorMessage!, null),
              if (visibleReport != null && selectedOwner != null) ...[
                const SizedBox(height: 16),
                _summary(visibleReport, selectedOwner),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: visibleReport == null || selectedOwner == null
                    ? Center(
                        child: reports.isOwnerStatementLoading
                            ? const CircularProgressIndicator()
                            : Text(
                                reports.ownerStatementAccountsLoaded
                                    ? 'اختر مالكًا وفترة ثم اضغط «عرض الكشف».'
                                    : 'جارٍ تحميل الملاك المرتبطين بحساباتهم...',
                                textAlign: TextAlign.center,
                              ),
                      )
                    : _movementTable(visibleReport),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _errorPanel(String message, VoidCallback? onRetry) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(message, style: const TextStyle(color: Colors.red)),
        ),
        if (onRetry != null)
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('إعادة المحاولة'),
          ),
      ],
    ),
  );

  Widget _summary(AccountStatementReport report, OwnerStatementAccount owner) {
    final currency = PrintUtils.currencyInArabic(report.currency);
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _summaryCard('المالك', owner.ownerName),
        _summaryCard(
          'حساب الملاك الجاري',
          '${owner.accountCode ?? ''} - ${owner.accountName ?? ''}',
        ),
        _summaryCard(
          'الرصيد الافتتاحي',
          '${_amount(report.openingBalance)} $currency',
        ),
        _summaryCard(
          'إجمالي المدين',
          '${_amount(report.totalDebit)} $currency',
        ),
        _summaryCard(
          'إجمالي الدائن',
          '${_amount(report.totalCredit)} $currency',
        ),
        _summaryCard(
          'الرصيد الختامي',
          '${_amount(report.closingBalance)} $currency',
        ),
      ],
    );
  }

  Widget _summaryCard(String label, String value) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    ),
  );

  Widget _movementTable(AccountStatementReport report) {
    if (report.lines.isEmpty) {
      return const Center(
        child: Text(
          'لا توجد حركات مرحلة في الفترة المحددة؛ الرصيد الافتتاحي والختامي معروضان أعلاه.',
          textAlign: TextAlign.center,
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('التاريخ')),
              DataColumn(label: Text('رقم القيد')),
              DataColumn(label: Text('البيان')),
              DataColumn(label: Text('مدين')),
              DataColumn(label: Text('دائن')),
              DataColumn(label: Text('الرصيد')),
            ],
            rows: report.lines
                .map(
                  (line) => DataRow(
                    cells: [
                      DataCell(Text(line.date)),
                      DataCell(Text(line.journalEntryId.toString())),
                      DataCell(
                        SizedBox(
                          width: 320,
                          child: Text(
                            line.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      DataCell(Text(_amount(line.debit))),
                      DataCell(Text(_amount(line.credit))),
                      DataCell(Text(_amount(line.runningBalance))),
                    ],
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ),
    );
  }
}
