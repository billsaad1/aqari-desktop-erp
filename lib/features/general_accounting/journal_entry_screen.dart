import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import 'package:provider/provider.dart';
import '../../providers/accounting_provider.dart';
import 'package:intl/intl.dart';
import '../../core/print_utils.dart';
import '../../core/pdf_preview_dialog.dart';

class JournalEntryScreen extends StatefulWidget {
  const JournalEntryScreen({super.key});

  @override
  State<JournalEntryScreen> createState() => _JournalEntryScreenState();
}

class _JournalEntryScreenState extends State<JournalEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _dateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  final _descController = TextEditingController();

  List<JournalLine> lines = [];
  Uint8List? _lastPdf;
  String? _lastPdfName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<AccountingProvider>(context, listen: false).loadAccounts();
      Provider.of<AccountingProvider>(context, listen: false).loadCostCenters();
    });
    // Add two initial lines
    lines.add(JournalLine());
    lines.add(JournalLine());
  }

  double get totalDebit =>
      lines.fold(0, (sum, line) => sum + (line.debit ?? 0));
  double get totalCredit =>
      lines.fold(0, (sum, line) => sum + (line.credit ?? 0));
  double get difference => totalDebit - totalCredit;
  bool get isValidEntry =>
      (totalDebit * 100).round() == (totalCredit * 100).round() &&
      totalDebit > 0 &&
      _formKey.currentState?.validate() == true;

  @override
  void dispose() {
    for (var line in lines) {
      line.debitController.dispose();
      line.creditController.dispose();
    }
    _dateController.dispose();
    _descController.dispose();
    super.dispose();
  }

  void _addLine() {
    setState(() {
      lines.add(JournalLine());
    });
  }

  void _removeLine(int index) {
    if (lines.length > 2) {
      setState(() {
        final removed = lines.removeAt(index);
        removed.debitController.dispose();
        removed.creditController.dispose();
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('يجب أن يحتوي القيد على سطرين على الأقل')),
      );
    }
  }

  void _saveEntry() async {
    if (isValidEntry) {
      // Validate all lines have accounts
      if (lines.any((l) => l.accountId == null)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء اختيار الحساب لجميع الأسطر')),
        );
        return;
      }

      final header = {
        'entry_date': _dateController.text,
        'description': _descController.text,
        'is_posted': 1,
      };

      final linesData = lines
          .map(
            (l) => {
              'account_id': l.accountId,
              'debit': l.debit ?? 0.0,
              'credit': l.credit ?? 0.0,
              'cost_center_id': l.costCenterId,
              'description': l.description,
            },
          )
          .toList();

      try {
        final journalId = await Provider.of<AccountingProvider>(
          context,
          listen: false,
        ).saveJournalEntry(header, linesData);
        if (mounted) {
          final accounts = Provider.of<AccountingProvider>(
            context,
            listen: false,
          ).accounts;
          final pdfLines = lines.map((line) {
            final account = accounts.firstWhere(
              (a) => a['id'] == line.accountId,
              orElse: () => <String, dynamic>{},
            );
            return {
              'account_name':
                  '${account['code'] ?? ''} ${account['name'] ?? ''}'.trim(),
              'description': line.description ?? _descController.text,
              'debit': line.debit ?? 0.0,
              'credit': line.credit ?? 0.0,
            };
          }).toList();
          try {
            final bytes = await PrintUtils.buildJournalEntryPdf(
              journalNo: journalId,
              date: _dateController.text,
              description: _descController.text,
              lines: pdfLines,
            );
            if (!mounted) return;
            setState(() {
              _lastPdf = bytes;
              _lastPdfName = 'قيد_يومية_$journalId';
            });
          } catch (e) {
            if (mounted)
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'حُفظ القيد رقم $journalId، لكن تعذر تجهيز PDF: $e',
                  ),
                ),
              );
          }
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('تم حفظ القيد رقم $journalId')),
            );
          for (final line in lines) {
            line.debitController.dispose();
            line.creditController.dispose();
          }
          setState(() {
            _descController.clear();
            lines = [JournalLine(), JournalLine()];
          });
        }
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('خطأ: $e')));
      }
    }
  }

  Future<void> _printLastPdf() async {
    final bytes = _lastPdf;
    final name = _lastPdfName;
    if (bytes == null || name == null) return;
    try {
      if (mounted) {
        await PdfDocumentPreviewDialog.show(
          context: context,
          bytes: bytes,
          fileName: name,
          preferredIntent: PdfPreviewIntent.printDocument,
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذرت الطباعة: $e')));
    }
  }

  Future<void> _saveLastPdf() async {
    final bytes = _lastPdf;
    final name = _lastPdfName;
    if (bytes == null || name == null) return;
    try {
      if (mounted) {
        await PdfDocumentPreviewDialog.show(
          context: context,
          bytes: bytes,
          fileName: name,
          preferredIntent: PdfPreviewIntent.save,
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر حفظ PDF: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AccountingProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading)
          return const Center(child: CircularProgressIndicator());

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'قيد يومية يدوي',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                // Header
                Row(
                  children: [
                    Expanded(
                      flex: 1,
                      child: TextFormField(
                        controller: _dateController,
                        decoration: const InputDecoration(
                          labelText: 'التاريخ',
                          border: OutlineInputBorder(),
                        ),
                        readOnly: true,
                        onTap: () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2100),
                          );
                          if (date != null) {
                            setState(() {
                              _dateController.text = DateFormat(
                                'yyyy-MM-dd',
                              ).format(date);
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: _descController,
                        decoration: const InputDecoration(
                          labelText: 'البيان العام',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Lines
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      itemCount: lines.length,
                      itemBuilder: (context, index) {
                        return _buildLineRow(
                          index,
                          provider.accounts,
                          provider.costCenters,
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Footer & Totals
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton.icon(
                      onPressed: _addLine,
                      icon: const Icon(Icons.add),
                      label: const Text('إضافة سطر'),
                    ),
                    Row(
                      children: [
                        _buildTotalBox(
                          'إجمالي المدين',
                          totalDebit,
                          AppPalette.navy,
                        ),
                        const SizedBox(width: 16),
                        _buildTotalBox(
                          'إجمالي الدائن',
                          totalCredit,
                          Colors.green,
                        ),
                        const SizedBox(width: 16),
                        _buildTotalBox(
                          'الفرق',
                          difference,
                          difference == 0 ? Colors.grey : Colors.red,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: isValidEntry ? _saveEntry : null,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.all(16),
                          backgroundColor: isValidEntry
                              ? AppPalette.navy
                              : Colors.grey,
                        ),
                        child: const Text(
                          'حفظ وترحيل القيد',
                          style: TextStyle(fontSize: 18),
                        ),
                      ),
                    ),
                    if (_lastPdf != null) ...[
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _printLastPdf,
                        icon: const Icon(Icons.print),
                        label: const Text('طباعة آخر قيد'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _saveLastPdf,
                        icon: const Icon(Icons.picture_as_pdf),
                        label: const Text('حفظ PDF'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTotalBox(String label, double value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
          ),
          Text(
            value.toStringAsFixed(2),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildLineRow(
    int index,
    List<Map<String, dynamic>> accounts,
    List<Map<String, dynamic>> costCenters,
  ) {
    final line = lines[index];
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<int>(
              value: line.accountId,
              items: accounts
                  .where((a) => a['parent_id'] != null)
                  .map(
                    (a) => DropdownMenuItem<int>(
                      value: a['id'],
                      child: Text('${a['code']} - ${a['name']}'),
                    ),
                  )
                  .toList(),
              onChanged: (val) {
                setState(() {
                  line.accountId = val;
                });
              },
              decoration: const InputDecoration(
                labelText: 'الحساب',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 1,
            child: TextFormField(
              controller: line.debitController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'مدين',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (val) {
                setState(() {
                  line.debit = double.tryParse(val);
                  if (line.debit != null && line.debit! > 0) {
                    line.credit = 0;
                    line.creditController.text = '';
                  }
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 1,
            child: TextFormField(
              controller: line.creditController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'دائن',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (val) {
                setState(() {
                  line.credit = double.tryParse(val);
                  if (line.credit != null && line.credit! > 0) {
                    line.debit = 0;
                    line.debitController.text = '';
                  }
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<int>(
              value: line.costCenterId,
              items: costCenters
                  .map(
                    (c) => DropdownMenuItem<int>(
                      value: c['id'],
                      child: Text(c['name']),
                    ),
                  )
                  .toList(),
              onChanged: (val) {
                setState(() {
                  line.costCenterId = val;
                });
              },
              decoration: const InputDecoration(
                labelText: 'مركز التكلفة',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextFormField(
              initialValue: line.description ?? '',
              decoration: const InputDecoration(
                labelText: 'بيان السطر',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (val) {
                setState(() {
                  line.description = val;
                });
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: () => _removeLine(index),
          ),
        ],
      ),
    );
  }
}

class JournalLine {
  final TextEditingController debitController = TextEditingController();
  final TextEditingController creditController = TextEditingController();
  int? accountId;
  double? debit;
  double? credit;
  int? costCenterId;
  String? description;
}
