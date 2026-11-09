import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/accounting_provider.dart';
import 'package:intl/intl.dart';

class JournalEntryScreen extends StatefulWidget {
  const JournalEntryScreen({super.key});

  @override
  State<JournalEntryScreen> createState() => _JournalEntryScreenState();
}

class _JournalEntryScreenState extends State<JournalEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _dateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _descController = TextEditingController();

  List<JournalLine> lines = [];

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

  double get totalDebit => lines.fold(0, (sum, line) => sum + (line.debit ?? 0));
  double get totalCredit => lines.fold(0, (sum, line) => sum + (line.credit ?? 0));
  double get difference => totalDebit - totalCredit;
  bool get isValidEntry => totalDebit == totalCredit && totalDebit > 0 && _formKey.currentState?.validate() == true;

  void _addLine() {
    setState(() {
      lines.add(JournalLine());
    });
  }

  void _removeLine(int index) {
    if (lines.length > 2) {
      setState(() {
        lines.removeAt(index);
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('يجب أن يحتوي القيد على سطرين على الأقل')));
    }
  }

  void _saveEntry() async {
    if (isValidEntry) {
      // Validate all lines have accounts
      if (lines.any((l) => l.accountId == null)) {
         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الرجاء اختيار الحساب لجميع الأسطر')));
         return;
      }

      final header = {
        'entry_date': _dateController.text,
        'description': _descController.text,
        'is_posted': 1,
      };

      final linesData = lines.map((l) => {
        'account_id': l.accountId,
        'debit': l.debit ?? 0.0,
        'credit': l.credit ?? 0.0,
        'cost_center_id': l.costCenterId,
        'description': l.description,
      }).toList();

      try {
        await Provider.of<AccountingProvider>(context, listen: false).saveJournalEntry(header, linesData);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ القيد بنجاح')));
          setState(() {
            _descController.clear();
            lines = [JournalLine(), JournalLine()];
          });
        }
      } catch (e) {
         if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AccountingProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) return const Center(child: CircularProgressIndicator());

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('قيد يومية يدوي', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                // Header
                Row(
                  children: [
                    Expanded(
                      flex: 1,
                      child: TextFormField(
                        controller: _dateController,
                        decoration: const InputDecoration(labelText: 'التاريخ', border: OutlineInputBorder()),
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
                              _dateController.text = DateFormat('yyyy-MM-dd').format(date);
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
                        decoration: const InputDecoration(labelText: 'البيان العام', border: OutlineInputBorder()),
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
                        return _buildLineRow(index, provider.accounts, provider.costCenters);
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
                        _buildTotalBox('إجمالي المدين', totalDebit, Colors.blue),
                        const SizedBox(width: 16),
                        _buildTotalBox('إجمالي الدائن', totalCredit, Colors.green),
                        const SizedBox(width: 16),
                        _buildTotalBox('الفرق', difference, difference == 0 ? Colors.grey : Colors.red),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: isValidEntry ? _saveEntry : null,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                    backgroundColor: isValidEntry ? Colors.blue : Colors.grey,
                  ),
                  child: const Text('حفظ وترحيل القيد', style: TextStyle(fontSize: 18)),
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
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          Text(value.toStringAsFixed(2), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildLineRow(int index, List<Map<String, dynamic>> accounts, List<Map<String, dynamic>> costCenters) {
    final line = lines[index];
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<int>(
              value: line.accountId,
              items: accounts.map((a) => DropdownMenuItem<int>(
                value: a['id'],
                child: Text('${a['''code''']} - ${a['''name''']}'),
              )).toList(),
              onChanged: (val) {
                setState(() { line.accountId = val; });
              },
              decoration: const InputDecoration(labelText: 'الحساب', isDense: true, border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 1,
            child: TextFormField(
              initialValue: line.debit?.toString() ?? '',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'مدين', isDense: true, border: OutlineInputBorder()),
              onChanged: (val) {
                setState(() {
                  line.debit = double.tryParse(val);
                  if (line.debit != null && line.debit! > 0) line.credit = 0; // mutually exclusive logic can be applied if needed
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 1,
            child: TextFormField(
              initialValue: line.credit?.toString() ?? '',
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'دائن', isDense: true, border: OutlineInputBorder()),
              onChanged: (val) {
                setState(() {
                  line.credit = double.tryParse(val);
                  if (line.credit != null && line.credit! > 0) line.debit = 0;
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<int>(
              value: line.costCenterId,
              items: costCenters.map((c) => DropdownMenuItem<int>(
                value: c['id'],
                child: Text(c['name']),
              )).toList(),
              onChanged: (val) {
                setState(() { line.costCenterId = val; });
              },
              decoration: const InputDecoration(labelText: 'مركز التكلفة', isDense: true, border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextFormField(
              initialValue: line.description ?? '',
              decoration: const InputDecoration(labelText: 'بيان السطر', isDense: true, border: OutlineInputBorder()),
              onChanged: (val) {
                setState(() { line.description = val; });
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
  int? accountId;
  double? debit;
  double? credit;
  int? costCenterId;
  String? description;
}
