import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/leasing_provider.dart';
import '../../providers/property_provider.dart';
import '../../database/database_helper.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:flutter/services.dart' show rootBundle;

class ContractsScreen extends StatefulWidget {
  const ContractsScreen({super.key});

  @override
  State<ContractsScreen> createState() => _ContractsScreenState();
}

class _ContractsScreenState extends State<ContractsScreen> {
  final _formKey = GlobalKey<FormState>();

  int? _selectedTenantId;
  int? _selectedUnitId;

  final _startDateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _endDateController = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now().add(const Duration(days: 365))));
  final _totalRentController = TextEditingController();

  String _paymentMethod = 'شهري';

  // Custom structure to hold manual edit controllers for each installment
  List<Map<String, dynamic>> _generatedInstallments = [];
  List<TextEditingController> _instAmountControllers = [];
  List<TextEditingController> _instDateControllers = [];

  void _disposeInstallmentControllers() {
    for (var c in _instAmountControllers) { c.dispose(); }
    for (var c in _instDateControllers) { c.dispose(); }
    _instAmountControllers.clear();
    _instDateControllers.clear();
  }

  @override
  void dispose() {
    _startDateController.dispose();
    _endDateController.dispose();
    _totalRentController.dispose();
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
      _instDateControllers.add(TextEditingController(text: _startDateController.text));
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

  void _generateInstallments() {
    if (_totalRentController.text.isEmpty) return;

    double totalRent = double.tryParse(_totalRentController.text) ?? 0.0;
    if (totalRent <= 0) return;

    DateTime startDate = DateFormat('yyyy-MM-dd').parse(_startDateController.text);
    DateTime endDate = DateFormat('yyyy-MM-dd').parse(_endDateController.text).add(const Duration(days: 1));

    int monthsDifference = (endDate.year - startDate.year) * 12 + endDate.month - startDate.month;
    if (monthsDifference <= 0) monthsDifference = 12; // fallback

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

    double amountPerInstallment = double.parse((totalRent / numInstallments).toStringAsFixed(2));

    // Adjust last installment to account for rounding issues
    double totalCalculated = amountPerInstallment * (numInstallments - 1);
    double lastInstallmentAmount = double.parse((totalRent - totalCalculated).toStringAsFixed(2));

    List<Map<String, dynamic>> newInstallments = [];
    _disposeInstallmentControllers(); // Clear old controllers

    for (int i = 0; i < numInstallments; i++) {
      DateTime dueDate = DateTime(startDate.year, startDate.month + (i * monthsPerInstallment), startDate.day);
      double currentAmount = (i == numInstallments - 1) ? lastInstallmentAmount : amountPerInstallment;

      String dateStr = DateFormat('yyyy-MM-dd').format(dueDate);

      newInstallments.add({
        'amount': currentAmount,
        'paid_amount': 0.0,
        'due_date': dateStr,
        'status': 'Unpaid',
      });

      _instAmountControllers.add(TextEditingController(text: currentAmount.toString()));
      _instDateControllers.add(TextEditingController(text: dateStr));
    }

    setState(() {
      _generatedInstallments = newInstallments;
    });
  }

  void _saveContract() async {
    if (_formKey.currentState!.validate() && _selectedTenantId != null && _selectedUnitId != null) {
      if (_generatedInstallments.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الرجاء توليد الأقساط أولاً')));
        return;
      }

      double totalRent = double.tryParse(_totalRentController.text) ?? 0.0;
      double sumInstallments = _generatedInstallments.fold(0.0, (sum, item) => sum + (item['amount'] as double));

      // Allow minor floating point rounding differences (e.g., 0.01)
      if ((totalRent - sumInstallments).abs() > 0.1) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('إجمالي مبلغ الأقساط (${sumInstallments.toStringAsFixed(2)}) لا يتطابق مع القيمة الإجمالية للعقد (${totalRent.toStringAsFixed(2)})')));
        return;
      }

      final contract = {
        'tenant_id': _selectedTenantId,
        'unit_id': _selectedUnitId,
        'start_date': _startDateController.text,
        'end_date': _endDateController.text,
        'rent_amount': double.tryParse(_totalRentController.text) ?? 0.0,
        'payment_method': _paymentMethod,
        'status': 'Active',
      };

      try {
        await Provider.of<LeasingProvider>(context, listen: false).addContract(contract, _generatedInstallments);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ العقد وتحديث حالة الوحدة بنجاح')));
          // Reset form
          setState(() {
            _selectedTenantId = null;
            _selectedUnitId = null;
            _totalRentController.clear();
            _generatedInstallments.clear();
          });
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ: $e')));
      }
    } else {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('الرجاء تعبئة جميع الحقول')));
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
                        const Text('إنشاء عقد جديد', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          value: _selectedTenantId,
                          items: leasingProv.tenants.map((t) => DropdownMenuItem<int>(
                            value: t['id'],
                            child: Text(t['name']),
                          )).toList(),
                          onChanged: (val) => setState(() => _selectedTenantId = val),
                          decoration: const InputDecoration(labelText: 'المستأجر', border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<int>(
                          value: _selectedUnitId,
                          items: leasingProv.vacantUnits.map((u) {
                            final propName = propProv.properties.firstWhere((p) => p['id'] == u['property_id'], orElse: () => {'name': ''})['name'];
                            return DropdownMenuItem<int>(
                              value: u['id'],
                              child: Text('عقار: $propName - وحدة: ${u['unit_number']}'),
                            );
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _selectedUnitId = val;
                              // Auto-fill rent if a unit is selected
                              final unit = leasingProv.vacantUnits.firstWhere((u) => u['id'] == val);
                              if (unit['default_rent'] != null) {
                                _totalRentController.text = unit['default_rent'].toString();
                              }
                            });
                          },
                          decoration: const InputDecoration(labelText: 'الوحدة الشاغرة', border: OutlineInputBorder()),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _startDateController,
                                decoration: const InputDecoration(labelText: 'بداية العقد', border: OutlineInputBorder()),
                                readOnly: true,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: TextFormField(
                                controller: _endDateController,
                                decoration: const InputDecoration(labelText: 'نهاية العقد', border: OutlineInputBorder()),
                                readOnly: true,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _totalRentController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'القيمة الإجمالية للعقد', border: OutlineInputBorder()),
                          validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                        ),
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          value: _paymentMethod,
                          items: ['شهري', 'ربع سنوي', 'نصف سنوي', 'سنوي', 'دفعة واحدة'].map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(m),
                          )).toList(),
                          onChanged: (val) => setState(() => _paymentMethod = val!),
                          decoration: const InputDecoration(labelText: 'طريقة الدفع', border: OutlineInputBorder()),
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
                        const Text('جدول الدفعات (الأقساط)', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                        if (_generatedInstallments.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.add_circle, color: Colors.blue),
                            tooltip: 'إضافة دفعة جديدة يدوياً',
                            onPressed: _addManualInstallment,
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300)),
                        child: _generatedInstallments.isEmpty
                            ? const Center(child: Text('لم يتم توليد الأقساط بعد'))
                            : ListView.builder(
                                itemCount: _generatedInstallments.length,
                                itemBuilder: (context, index) {
                                  return Card(
                                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    child: Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: Row(
                                        children: [
                                          CircleAvatar(child: Text('${index + 1}')),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: TextFormField(
                                              controller: _instDateControllers[index],
                                              decoration: const InputDecoration(labelText: 'تاريخ الاستحقاق', isDense: true),
                                              onChanged: (val) => _generatedInstallments[index]['due_date'] = val,
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Expanded(
                                            child: TextFormField(
                                              controller: _instAmountControllers[index],
                                              keyboardType: TextInputType.number,
                                              decoration: const InputDecoration(labelText: 'المبلغ', isDense: true),
                                              onChanged: (val) => _generatedInstallments[index]['amount'] = double.tryParse(val) ?? 0.0,
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.remove_circle, color: Colors.red),
                                            tooltip: 'حذف',
                                            onPressed: () => _removeManualInstallment(index),
                                          )
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
                      onPressed: _generatedInstallments.isNotEmpty ? _saveContract : null,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                        backgroundColor: Colors.green,
                      ),
                      child: const Text('حفظ العقد واعتماد الأقساط', style: TextStyle(fontSize: 18)),
                    ),
                    const SizedBox(height: 32),
                    const Divider(),
                    const Text('إدارة العقود الحالية', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.builder(
                        itemCount: leasingProv.contracts.length,
                        itemBuilder: (context, index) {
                          final contract = leasingProv.contracts[index];
                          final tenantName = leasingProv.tenants.firstWhere((t) => t['id'] == contract['tenant_id'], orElse: () => {'name': 'غير معروف'})['name'];
                          return Card(
                            child: InkWell(
                              onTap: () => _showContractDetailsDialog(contract, tenantName),
                              child: ListTile(
                                title: Text('عقد رقم: ${contract['id']} - المستأجر: $tenantName'),
                                subtitle: Text('الحالة: ${contract['status']} | الإجمالي: ${contract['rent_amount']}'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.print, color: Colors.blue),
                                      tooltip: 'طباعة العقد (PDF)',
                                      onPressed: () => _printContract(contract),
                                    ),
                                    if (contract['status'] == 'Active')
                                      IconButton(
                                        icon: const Icon(Icons.cancel, color: Colors.red),
                                        tooltip: 'إلغاء العقد',
                                        onPressed: () => _cancelContract(contract['id']),
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

  void _showContractDetailsDialog(Map<String, dynamic> contract, String tenantName) async {
    final db = await DatabaseHelper.instance.database;
    final installments = await db.query('contract_installments', where: 'contract_id = ?', whereArgs: [contract['id']]);

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
                Text('المستأجر: $tenantName', style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('المدة: من ${contract['start_date']} إلى ${contract['end_date']}'),
                Text('طريقة الدفع: ${contract['payment_method']}'),
                Text('الإجمالي: ${contract['rent_amount']} ريال'),
                const Divider(),
                const Text('الأقساط:', style: TextStyle(fontWeight: FontWeight.bold)),
                Expanded(
                  child: ListView.builder(
                    itemCount: installments.length,
                    itemBuilder: (context, idx) {
                      final inst = installments[idx];
                      return ListTile(
                        leading: CircleAvatar(child: Text('${idx+1}')),
                        title: Text('تاريخ: ${inst['due_date']}'),
                        subtitle: Text('الحالة: ${inst['status']} | المدفوع: ${inst['paid_amount']}'),
                        trailing: Text('${inst['amount']} ريال', style: const TextStyle(fontWeight: FontWeight.bold)),
                      );
                    }
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
                _printContract(contract);
              },
              icon: const Icon(Icons.print),
              label: const Text('طباعة العقد PDF'),
            )
          ],
        );
      },
    );
  }

  Future<void> _printContract(Map<String, dynamic> contract) async {
    // 1. Fetch Company Info
    final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
    final String companyName = companyInfo?['name_ar'] ?? 'مؤسسة عبدالله النقيب التجارية';
    final String companyAddress = companyInfo?['address'] ?? '';
    final String companyTax = companyInfo?['tax_number'] ?? '';
    final String termsConditions = companyInfo?['terms_conditions'] ?? '';
    final String? logoPath = companyInfo?['logo_path'];

    // 2. Fetch required details from providers
    final leasingProv = Provider.of<LeasingProvider>(context, listen: false);
    final propProv = Provider.of<PropertyProvider>(context, listen: false);

    final tenant = leasingProv.tenants.firstWhere((t) => t['id'] == contract['tenant_id'], orElse: () => {});
    final unitId = contract['unit_id'];

    // Find unit details directly from database to ensure we get it even if not vacant
    final db = await DatabaseHelper.instance.database;
    final unitList = await db.query('units', where: 'id = ?', whereArgs: [unitId]);
    final unit = unitList.isNotEmpty ? unitList.first : {};

    final property = propProv.properties.firstWhere((p) => p['id'] == unit['property_id'], orElse: () => {});

    // Fetch installments for this contract
    final installments = await db.query('contract_installments', where: 'contract_id = ?', whereArgs: [contract['id']]);

    // 3. Setup PDF Fonts (Arabic support)
    final fontData = await rootBundle.load("assets/fonts/Cairo-Regular.ttf").catchError((_) => ByteData.view(Uint8List(0).buffer));
    final ttf = fontData.lengthInBytes > 0 ? pw.Font.ttf(fontData) : pw.Font.helvetica();
    final fontBoldData = await rootBundle.load("assets/fonts/Cairo-Bold.ttf").catchError((_) => ByteData.view(Uint8List(0).buffer));
    final ttfBold = fontBoldData.lengthInBytes > 0 ? pw.Font.ttf(fontBoldData) : pw.Font.helveticaBold();

    // 4. Generate PDF
    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        theme: pw.ThemeData.withFont(base: ttf, bold: ttfBold),
        header: (pw.Context context) {
          return pw.Column(
            children: [
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(companyName, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                      pw.Text('العنوان: $companyAddress', style: const pw.TextStyle(fontSize: 12)),
                      if (companyTax.isNotEmpty) pw.Text('الرقم الضريبي: $companyTax', style: const pw.TextStyle(fontSize: 12)),
                    ],
                  ),
                  if (logoPath != null && logoPath.isNotEmpty && File(logoPath).existsSync())
                    pw.Image(
                      pw.MemoryImage(File(logoPath).readAsBytesSync()),
                      width: 80,
                      height: 80,
                    )
                  else
                    pw.Container(width: 80, height: 80, color: PdfColors.grey200, child: pw.Center(child: pw.Text('شعار'))),
                ],
              ),
              pw.Divider(thickness: 2),
              pw.SizedBox(height: 10),
            ],
          );
        },
        build: (pw.Context context) => [
          pw.Center(
            child: pw.Text('عقد إيجار عقار', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, decoration: pw.TextDecoration.underline)),
          ),
          pw.SizedBox(height: 20),

          pw.Text('تم إبرام هذا العقد بتاريخ ${DateFormat('yyyy-MM-dd').format(DateTime.now())} بين كل من:', style: const pw.TextStyle(fontSize: 14)),
          pw.SizedBox(height: 10),

          pw.Text('الطرف الأول (المؤجر): $companyName', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Text('الطرف الثاني (المستأجر): ${tenant['name'] ?? ''}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Text('الجنسية: ${tenant['nationality'] ?? ''} | رقم الهوية: ${tenant['id_number'] ?? ''}', style: const pw.TextStyle(fontSize: 12)),

          pw.SizedBox(height: 15),
          pw.Text('بيانات العين المؤجرة:', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Text('العقار: ${property['name'] ?? ''} - الوحدة: ${unit['unit_number'] ?? ''}', style: const pw.TextStyle(fontSize: 14)),

          pw.SizedBox(height: 15),
          pw.Text('تفاصيل العقد:', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.Text('تاريخ البداية: ${contract['start_date']}', style: const pw.TextStyle(fontSize: 14)),
          pw.Text('تاريخ النهاية: ${contract['end_date']}', style: const pw.TextStyle(fontSize: 14)),
          pw.Text('القيمة الإيجارية الإجمالية: ${contract['rent_amount']}', style: const pw.TextStyle(fontSize: 14)),
          pw.Text('طريقة الدفع: ${contract['payment_method']}', style: const pw.TextStyle(fontSize: 14)),

          pw.SizedBox(height: 20),
          pw.Text('جدول الدفعات (الأقساط):', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 5),
          pw.TableHelper.fromTextArray(
            headers: ['رقم القسط', 'تاريخ الاستحقاق', 'المبلغ'],
            data: installments.asMap().entries.map((e) => [
              (e.key + 1).toString(),
              e.value['due_date'].toString(),
              e.value['amount'].toString()
            ]).toList(),
            cellStyle: const pw.TextStyle(fontSize: 12),
            headerStyle: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey800),
            border: pw.TableBorder.all(color: PdfColors.grey),
          ),

          if (termsConditions.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            pw.Text('الشروط والأحكام:', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.Text(termsConditions, style: const pw.TextStyle(fontSize: 12)),
          ],

          pw.SizedBox(height: 40),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                children: [
                  pw.Text('توقيع الطرف الأول (المؤجر)', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 30),
                  pw.Text('_________________________'),
                ]
              ),
              pw.Column(
                children: [
                  pw.Text('الختم الرسمي', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 30),
                  pw.Text('_________________________'),
                ]
              ),
              pw.Column(
                children: [
                  pw.Text('توقيع الطرف الثاني (المستأجر)', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 30),
                  pw.Text('_________________________'),
                ]
              ),
            ]
          )
        ],
      )
    );

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdf.save(),
      name: 'Contract_${contract['id']}',
    );
  }

  void _cancelContract(int contractId) async {
    bool confirm = await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد الإلغاء'),
        content: const Text('هل أنت متأكد من إلغاء هذا العقد؟ إذا كان هناك دفعات مسددة سيرفض النظام الإلغاء.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('تراجع')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('نعم، إلغاء'),
          ),
        ],
      )
    ) ?? false;

    if (confirm) {
      try {
        await Provider.of<LeasingProvider>(context, listen: false).cancelContract(contractId);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم إلغاء العقد بنجاح')));
      } catch (e) {
        if (mounted) {
           showDialog(
             context: context,
             builder: (context) => AlertDialog(
               title: const Text('لا يمكن الإلغاء'),
               content: Text(e.toString()),
               actions: [
                 TextButton(onPressed: () => Navigator.pop(context), child: const Text('حسناً'))
               ]
             )
           );
        }
      }
    }
  }
}
