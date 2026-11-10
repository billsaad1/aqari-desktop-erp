import "../../core/print_utils.dart";
import '../../core/lease_contract_pdf.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/property_provider.dart';
import '../../database/database_helper.dart';

class ContractsScreen extends StatefulWidget {
  const ContractsScreen({super.key});

  @override
  State<ContractsScreen> createState() => _ContractsScreenState();
}

class _ContractsScreenState extends State<ContractsScreen> {
  final _formKey = GlobalKey<FormState>();

  int? _selectedTenantId;
  int? _selectedUnitId;
  bool _isSavingContract = false;

  final _startDateController = TextEditingController(
    text: DateFormat('yyyy-MM-dd').format(DateTime.now()),
  );
  final _endDateController = TextEditingController(
    text: DateFormat(
      'yyyy-MM-dd',
    ).format(DateTime.now().add(const Duration(days: 365))),
  );
  final _totalRentController = TextEditingController();
  final _purposeController = TextEditingController();
  final _electricityReadingController = TextEditingController();

  String _paymentMethod = 'شهري';

  // Custom structure to hold manual edit controllers for each installment
  List<Map<String, dynamic>> _generatedInstallments = [];
  List<TextEditingController> _instAmountControllers = [];
  List<TextEditingController> _instDateControllers = [];

  void _disposeInstallmentControllers() {
    for (var c in _instAmountControllers) {
      c.dispose();
    }
    for (var c in _instDateControllers) {
      c.dispose();
    }
    _instAmountControllers.clear();
    _instDateControllers.clear();
  }

  @override
  void dispose() {
    _startDateController.dispose();
    _endDateController.dispose();
    _totalRentController.dispose();
    _purposeController.dispose();
    _electricityReadingController.dispose();
    _disposeInstallmentControllers();
    super.dispose();
  }

  void _addManualInstallment() {
    setState(() {
      _generatedInstallments.add({
        'amount': 0.0,
        'paid_amount': 0.0,
        'due_date': _startDateController.text,
        'status': 'Unpaid',
      });
      _instAmountControllers.add(TextEditingController(text: '0.0'));
      _instDateControllers.add(
        TextEditingController(text: _startDateController.text),
      );
    });
  }

  void _removeManualInstallment(int index) {
    setState(() {
      _generatedInstallments.removeAt(index);
      _instAmountControllers[index].dispose();
      _instDateControllers[index].dispose();
      _instAmountControllers.removeAt(index);
      _instDateControllers.removeAt(index);
    });
  }

  Future<void> _pickContractDate(bool start) async {
    final controller = start ? _startDateController : _endDateController;
    final current = DateTime.tryParse(controller.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      controller.text = DateFormat('yyyy-MM-dd').format(picked);
      if (start) {
        final currentEnd = DateTime.tryParse(_endDateController.text);
        if (currentEnd == null || picked.isAfter(currentEnd))
          _endDateController.text = controller.text;
      }
    });
  }

  Future<void> _pickInstallmentDate(int index) async {
    final start =
        DateTime.tryParse(_startDateController.text) ?? DateTime(2000);
    final end = DateTime.tryParse(_endDateController.text) ?? DateTime(2100);
    final current =
        DateTime.tryParse(_instDateControllers[index].text) ?? start;
    final picked = await showDatePicker(
      context: context,
      initialDate: current.isBefore(start)
          ? start
          : current.isAfter(end)
          ? end
          : current,
      firstDate: start,
      lastDate: end.isBefore(start) ? start : end,
    );
    if (picked != null && mounted) {
      setState(() {
        final value = DateFormat('yyyy-MM-dd').format(picked);
        _instDateControllers[index].text = value;
        _generatedInstallments[index]['due_date'] = value;
      });
    }
  }

  void _generateInstallments() {
    if (_totalRentController.text.isEmpty) return;

    double totalRent = double.tryParse(_totalRentController.text) ?? 0.0;
    if (totalRent <= 0) return;

    final startDate = DateTime.tryParse(_startDateController.text);
    final endDate = DateTime.tryParse(_endDateController.text);
    if (startDate == null || endDate == null || startDate.isAfter(endDate)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تاريخ بداية أو نهاية العقد غير صحيح')),
      );
      return;
    }
    final monthsDifference =
        ((endDate.year - startDate.year) * 12 + endDate.month - startDate.month)
            .clamp(1, 600)
            .toInt();

    int numInstallments = 1;
    int monthsPerInstallment = 12;

    switch (_paymentMethod) {
      case 'شهري':
        numInstallments = monthsDifference;
        monthsPerInstallment = 1;
        break;
      case 'ربع سنوي':
        numInstallments = (monthsDifference / 3).ceil();
        if (numInstallments == 0) numInstallments = 1;
        monthsPerInstallment = 3;
        break;
      case 'نصف سنوي':
        numInstallments = (monthsDifference / 6).ceil();
        if (numInstallments == 0) numInstallments = 1;
        monthsPerInstallment = 6;
        break;
      case 'سنوي':
        numInstallments = (monthsDifference / 12).ceil();
        if (numInstallments == 0) numInstallments = 1;
        monthsPerInstallment = 12;
        break;
      case 'دفعة واحدة':
        numInstallments = 1;
        monthsPerInstallment = monthsDifference;
        break;
    }

    final amountPerInstallment = double.parse(
      (totalRent / numInstallments).toStringAsFixed(2),
    );

    // Adjust last installment to account for rounding issues
    final totalCalculated = amountPerInstallment * (numInstallments - 1);
    final lastInstallmentAmount = double.parse(
      (totalRent - totalCalculated).toStringAsFixed(2),
    );

    List<Map<String, dynamic>> newInstallments = [];
    _disposeInstallmentControllers(); // Clear old controllers

    for (int i = 0; i < numInstallments; i++) {
      final dueDate = _addMonthsClamped(startDate, i * monthsPerInstallment);
      double currentAmount = (i == numInstallments - 1)
          ? lastInstallmentAmount
          : amountPerInstallment;

      String dateStr = DateFormat('yyyy-MM-dd').format(dueDate);

      newInstallments.add({
        'amount': currentAmount,
        'paid_amount': 0.0,
        'due_date': dateStr,
        'status': 'Unpaid',
      });

      _instAmountControllers.add(
        TextEditingController(text: currentAmount.toString()),
      );
      _instDateControllers.add(TextEditingController(text: dateStr));
    }

    setState(() {
      _generatedInstallments = newInstallments;
    });
  }

  DateTime _addMonthsClamped(DateTime date, int months) {
    final firstOfMonth = DateTime(date.year, date.month + months, 1);
    final lastDay = DateTime(firstOfMonth.year, firstOfMonth.month + 1, 0).day;
    return DateTime(
      firstOfMonth.year,
      firstOfMonth.month,
      date.day > lastDay ? lastDay : date.day,
    );
  }

  void _saveContract() async {
    if (_isSavingContract) return;
    if (_formKey.currentState!.validate() &&
        _selectedTenantId != null &&
        _selectedUnitId != null) {
      if (_generatedInstallments.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء توليد الأقساط أولاً')),
        );
        return;
      }

      final totalRent = double.tryParse(_totalRentController.text) ?? 0.0;
      final startDate = DateTime.tryParse(_startDateController.text);
      final endDate = DateTime.tryParse(_endDateController.text);
      final sumInstallments = _generatedInstallments.fold<double>(
        0,
        (sum, item) => sum + ((item['amount'] as num?)?.toDouble() ?? 0),
      );
      final datesValid =
          startDate != null &&
          endDate != null &&
          !startDate.isAfter(endDate) &&
          _generatedInstallments.every((item) {
            final due = DateTime.tryParse(item['due_date']?.toString() ?? '');
            return (item['amount'] as num? ?? 0) > 0 &&
                due != null &&
                !due.isBefore(startDate) &&
                !due.isAfter(endDate);
          });

      if (!datesValid) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تحقق من تواريخ الأقساط والمبالغ')),
        );
        return;
      }
      if ((totalRent * 100).round() != (sumInstallments * 100).round()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'إجمالي مبلغ الأقساط (${sumInstallments.toStringAsFixed(2)}) لا يتطابق مع القيمة الإجمالية للعقد (${totalRent.toStringAsFixed(2)})',
            ),
          ),
        );
        return;
      }

      final contract = {
        'tenant_id': _selectedTenantId,
        'unit_id': _selectedUnitId,
        'start_date': _startDateController.text,
        'end_date': _endDateController.text,
        'rent_amount': double.tryParse(_totalRentController.text) ?? 0.0,
        'payment_method': _paymentMethod,
        'purpose': _purposeController.text.trim(),
        'electricity_reading': _electricityReadingController.text.trim(),
        'status': 'Active',
      };

      setState(() => _isSavingContract = true);
      try {
        final contractId = await Provider.of<LeasingProvider>(
          context,
          listen: false,
        ).addContract(contract, _generatedInstallments);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('تم حفظ العقد رقم $contractId وتحديث حالة الوحدة'),
            ),
          );
          // Reset form
          _disposeInstallmentControllers();
          setState(() {
            _selectedTenantId = null;
            _selectedUnitId = null;
            _totalRentController.clear();
            _purposeController.clear();
            _electricityReadingController.clear();
            _generatedInstallments.clear();
          });
        }
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('خطأ: $e')));
      } finally {
        if (mounted) setState(() => _isSavingContract = false);
      }
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('الرجاء تعبئة جميع الحقول')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<LeasingProvider, PropertyProvider>(
      builder: (context, leasingProv, propProv, child) {
        if (leasingProv.isLoading || propProv.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left side: Contract Form
              Expanded(
                flex: 1,
                child: SingleChildScrollView(
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'إنشاء عقد جديد',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          value: _selectedTenantId,
                          items: leasingProv.tenants
                              .map(
                                (t) => DropdownMenuItem<int>(
                                  value: t['id'],
                                  child: Text(t['name']),
                                ),
                              )
                              .toList(),
                          onChanged: (val) =>
                              setState(() => _selectedTenantId = val),
                          decoration: const InputDecoration(
                            labelText: 'المستأجر',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          value: _selectedUnitId,
                          items: leasingProv.vacantUnits.map((u) {
                            final propName = propProv.properties.firstWhere(
                              (p) => p['id'] == u['property_id'],
                              orElse: () => {'name': ''},
                            )['name'];
                            return DropdownMenuItem<int>(
                              value: u['id'],
                              child: Text(
                                'عقار: $propName - وحدة: ${u['unit_number']}',
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _selectedUnitId = val;
                              if (val == null) {
                                _totalRentController.clear();
                              } else {
                                final unit = leasingProv.vacantUnits.firstWhere(
                                  (u) => u['id'] == val,
                                );
                                if (unit['default_rent'] != null) {
                                  _totalRentController.text =
                                      unit['default_rent'].toString();
                                }
                              }
                            });
                          },
                          decoration: const InputDecoration(
                            labelText: 'الوحدة الشاغرة',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _startDateController,
                                decoration: const InputDecoration(
                                  labelText: 'بداية العقد',
                                  border: OutlineInputBorder(),
                                ),
                                readOnly: true,
                                onTap: () => _pickContractDate(true),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: TextFormField(
                                controller: _endDateController,
                                decoration: const InputDecoration(
                                  labelText: 'نهاية العقد',
                                  border: OutlineInputBorder(),
                                ),
                                readOnly: true,
                                onTap: () => _pickContractDate(false),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _totalRentController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'القيمة الإجمالية للعقد',
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) {
                            final value = double.tryParse(v ?? '');
                            return value == null || value <= 0
                                ? 'أدخل قيمة عقد موجبة'
                                : null;
                          },
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          value: _paymentMethod,
                          items:
                              [
                                    'شهري',
                                    'ربع سنوي',
                                    'نصف سنوي',
                                    'سنوي',
                                    'دفعة واحدة',
                                  ]
                                  .map(
                                    (m) => DropdownMenuItem(
                                      value: m,
                                      child: Text(m),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (val) =>
                              setState(() => _paymentMethod = val!),
                          decoration: const InputDecoration(
                            labelText: 'طريقة الدفع',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _purposeController,
                          decoration: const InputDecoration(
                            labelText: 'الغرض من الاستئجار (مثال: سكني)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _electricityReadingController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'قراءة عداد الكهرباء عند بدء الإيجار',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: _generateInstallments,
                          child: const Text('توليد جدول الأقساط'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              // Right side: Generated Installments & Save
              Expanded(
                flex: 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'جدول الدفعات (الأقساط)',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_generatedInstallments.isNotEmpty)
                          IconButton(
                            icon: const Icon(
                              Icons.add_circle,
                              color: Colors.blue,
                            ),
                            tooltip: 'إضافة دفعة جديدة يدوياً',
                            onPressed: _addManualInstallment,
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: _generatedInstallments.isEmpty
                            ? const Center(
                                child: Text('لم يتم توليد الأقساط بعد'),
                              )
                            : ListView.builder(
                                itemCount: _generatedInstallments.length,
                                itemBuilder: (context, index) {
                                  return Card(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            child: Text('${index + 1}'),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: TextFormField(
                                              controller:
                                                  _instDateControllers[index],
                                              decoration: const InputDecoration(
                                                labelText: 'تاريخ الاستحقاق',
                                                isDense: true,
                                              ),
                                              readOnly: true,
                                              onTap: () =>
                                                  _pickInstallmentDate(index),
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: TextFormField(
                                              controller:
                                                  _instAmountControllers[index],
                                              keyboardType:
                                                  TextInputType.number,
                                              decoration: const InputDecoration(
                                                labelText: 'المبلغ',
                                                isDense: true,
                                              ),
                                              onChanged: (val) =>
                                                  _generatedInstallments[index]['amount'] =
                                                      double.tryParse(val) ??
                                                      0.0,
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(
                                              Icons.remove_circle,
                                              color: Colors.red,
                                            ),
                                            tooltip: 'حذف',
                                            onPressed: () =>
                                                _removeManualInstallment(index),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed:
                          _generatedInstallments.isNotEmpty &&
                              !_isSavingContract
                          ? _saveContract
                          : null,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: Colors.green,
                      ),
                      child: const Text(
                        'حفظ العقد واعتماد الأقساط',
                        style: TextStyle(fontSize: 18),
                      ),
                    ),
                    const SizedBox(height: 32),
                    const Divider(),
                    const Text(
                      'إدارة العقود الحالية',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.builder(
                        itemCount: leasingProv.contracts.length,
                        itemBuilder: (context, index) {
                          final contract = leasingProv.contracts[index];
                          final tenantName = leasingProv.tenants.firstWhere(
                            (t) => t['id'] == contract['tenant_id'],
                            orElse: () => {'name': 'غير معروف'},
                          )['name'];
                          return Card(
                            child: InkWell(
                              onTap: () => _showContractDetailsDialog(
                                contract,
                                tenantName,
                              ),
                              child: ListTile(
                                title: Text(
                                  'عقد رقم: ${contract['id']} - المستأجر: $tenantName',
                                ),
                                subtitle: Text(
                                  'الحالة: ${contract['status']} | الإجمالي: ${contract['rent_amount']}',
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                        Icons.print,
                                        color: Colors.blue,
                                      ),
                                      tooltip: 'طباعة العقد (PDF)',
                                      onPressed: () => _printContract(
                                        contract,
                                        saveAsPdf: false,
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.picture_as_pdf,
                                        color: Colors.deepOrange,
                                      ),
                                      tooltip: 'حفظ العقد PDF',
                                      onPressed: () => _printContract(
                                        contract,
                                        saveAsPdf: true,
                                      ),
                                    ),
                                    if (contract['status'] == 'Active')
                                      IconButton(
                                        icon: const Icon(
                                          Icons.cancel,
                                          color: Colors.red,
                                        ),
                                        tooltip: 'إلغاء العقد',
                                        onPressed: () =>
                                            _cancelContract(contract['id']),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showContractDetailsDialog(
    Map<String, dynamic> contract,
    String tenantName,
  ) async {
    final db = await DatabaseHelper.instance.database;
    final installments = await db.query(
      'contract_installments',
      where: 'contract_id = ?',
      whereArgs: [contract['id']],
    );

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('تفاصيل العقد رقم: ${contract['id']}'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'المستأجر: $tenantName',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  'المدة: من ${contract['start_date']} إلى ${contract['end_date']}',
                ),
                Text('طريقة الدفع: ${contract['payment_method']}'),
                Text('الإجمالي: ${contract['rent_amount']} ريال'),
                const Divider(),
                const Text(
                  'الأقساط:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: installments.length,
                    itemBuilder: (context, idx) {
                      final inst = installments[idx];
                      return ListTile(
                        leading: CircleAvatar(child: Text('${idx + 1}')),
                        title: Text('تاريخ: ${inst['due_date']}'),
                        subtitle: Text(
                          'الحالة: ${inst['status']} | المدفوع: ${inst['paid_amount']}',
                        ),
                        trailing: Text(
                          '${inst['amount']} ريال',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إغلاق'),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _printContract(contract, saveAsPdf: false);
              },
              icon: const Icon(Icons.print),
              label: const Text('طباعة العقد PDF'),
            ),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                _printContract(contract, saveAsPdf: true);
              },
              icon: const Icon(Icons.save_alt),
              label: const Text('حفظ PDF'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _printContract(
    Map<String, dynamic> contract, {
    required bool saveAsPdf,
  }) async {
    try {
      final db = await DatabaseHelper.instance.database;
      final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
      final tenantRows = await db.query(
        'tenants',
        where: 'id = ?',
        whereArgs: [contract['tenant_id']],
        limit: 1,
      );
      if (tenantRows.isEmpty) throw StateError('بيانات المستأجر غير متاحة');
      final tenant = Map<String, dynamic>.from(tenantRows.first);
      if (tenant['nationality_id'] != null) {
        final nationalityRows = await db.query(
          'nationalities',
          columns: ['name'],
          where: 'id = ?',
          whereArgs: [tenant['nationality_id']],
          limit: 1,
        );
        tenant['nationality_name'] = nationalityRows.isEmpty
            ? ''
            : nationalityRows.first['name'];
      }

      final unitRows = await db.query(
        'units',
        where: 'id = ?',
        whereArgs: [contract['unit_id']],
        limit: 1,
      );
      if (unitRows.isEmpty) throw StateError('بيانات الوحدة غير متاحة');
      final unit = Map<String, dynamic>.from(unitRows.first);
      final propertyRows = await db.query(
        'properties',
        where: 'id = ?',
        whereArgs: [unit['property_id']],
        limit: 1,
      );
      if (propertyRows.isEmpty) throw StateError('بيانات العقار غير متاحة');
      final property = Map<String, dynamic>.from(propertyRows.first);

      var owner = <String, dynamic>{};
      final ownerRows = await db.query(
        'owners',
        where: 'id = ?',
        whereArgs: [property['owner_id']],
        limit: 1,
      );
      if (ownerRows.isNotEmpty)
        owner = Map<String, dynamic>.from(ownerRows.first);

      var unitTypeName = '';
      if (unit['unit_type_id'] != null) {
        final rows = await db.query(
          'unit_types',
          columns: ['name'],
          where: 'id = ?',
          whereArgs: [unit['unit_type_id']],
          limit: 1,
        );
        if (rows.isNotEmpty)
          unitTypeName = rows.first['name']?.toString() ?? '';
      }
      var propertyTypeName = '';
      if (property['property_type_id'] != null) {
        final rows = await db.query(
          'property_types',
          columns: ['name'],
          where: 'id = ?',
          whereArgs: [property['property_type_id']],
          limit: 1,
        );
        if (rows.isNotEmpty) {
          propertyTypeName = rows.first['name']?.toString() ?? '';
        }
      }
      var cityName = '';
      if (property['city_id'] != null) {
        final rows = await db.query(
          'cities',
          columns: ['name'],
          where: 'id = ?',
          whereArgs: [property['city_id']],
          limit: 1,
        );
        if (rows.isNotEmpty) cityName = rows.first['name']?.toString() ?? '';
      }

      final bytes = await LeaseContractPdf.build(
        companyInfo: companyInfo,
        contract: contract,
        owner: owner,
        tenant: tenant,
        property: property,
        unit: unit,
        cityName: cityName,
        unitTypeName: unitTypeName.isEmpty ? propertyTypeName : unitTypeName,
      );
      final name = 'عقد_إيجار_${contract['id']}';
      if (saveAsPdf) {
        final saved = await PrintUtils.savePdf(bytes, name);
        if (mounted && saved) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(PrintUtils.savedPdfMessage)));
        }
      } else {
        await PrintUtils.printPdf(bytes, name);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تجهيز/طباعة عقد الإيجار: $e')),
        );
      }
    }
  }

  void _cancelContract(int contractId) async {
    final leasingProvider = Provider.of<LeasingProvider>(
      context,
      listen: false,
    );
    bool confirm =
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('تأكيد الإلغاء'),
            content: const Text(
              'هل أنت متأكد من إلغاء هذا العقد؟ إذا كان هناك دفعات مسددة سيرفض النظام الإلغاء.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('تراجع'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('نعم، إلغاء'),
              ),
            ],
          ),
        ) ??
        false;

    if (!mounted || !confirm) return;
    try {
      await leasingProvider.cancelContract(contractId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('تم إلغاء العقد بنجاح')));
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('لا يمكن الإلغاء'),
            content: Text(e.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('حسناً'),
              ),
            ],
          ),
        );
      }
    }
  }
}
