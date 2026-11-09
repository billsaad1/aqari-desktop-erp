import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/property_provider.dart';
import '../../database/database_helper.dart';

class PropertiesScreen extends StatefulWidget {
  const PropertiesScreen({super.key});

  @override
  State<PropertiesScreen> createState() => _PropertiesScreenState();
}

class _PropertiesScreenState extends State<PropertiesScreen> {
  int? _selectedPropertyId;

  void _showAddPropertyDialog(BuildContext context, PropertyProvider provider) {
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController();
    final addressController = TextEditingController();
    final deedController = TextEditingController();

    int? selectedOwnerId;
    int? selectedCityId;
    int? selectedCostCenterId;
    int? selectedPropertyTypeId;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('إضافة عقار جديد'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'اسم العقار'),
                    validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                  ),
                  DropdownButtonFormField<int>(
                    value: selectedOwnerId,
                    items: provider.owners.map((o) => DropdownMenuItem<int>(
                      value: o['id'],
                      child: Text(o['name']),
                    )).toList(),
                    onChanged: (val) => selectedOwnerId = val,
                    decoration: const InputDecoration(labelText: 'المالك'),
                    validator: (v) => v == null ? 'مطلوب' : null,
                  ),
                  DropdownButtonFormField<int>(
                    value: selectedCityId,
                    items: provider.cities.map((c) => DropdownMenuItem<int>(
                      value: c['id'],
                      child: Text(c['name']),
                    )).toList(),
                    onChanged: (val) => selectedCityId = val,
                    decoration: const InputDecoration(labelText: 'المدينة'),
                  ),
                  DropdownButtonFormField<int>(
                    value: selectedPropertyTypeId,
                    items: provider.propertyTypes.map((pt) => DropdownMenuItem<int>(
                      value: pt['id'],
                      child: Text(pt['name']),
                    )).toList(),
                    onChanged: (val) => selectedPropertyTypeId = val,
                    decoration: const InputDecoration(labelText: 'نوع العقار'),
                  ),
                  DropdownButtonFormField<int>(
                    value: selectedCostCenterId,
                    items: provider.costCenters.map((c) => DropdownMenuItem<int>(
                      value: c['id'],
                      child: Text(c['name']),
                    )).toList(),
                    onChanged: (val) => selectedCostCenterId = val,
                    decoration: const InputDecoration(labelText: 'مركز التكلفة'),
                  ),
                  TextFormField(
                    controller: addressController,
                    decoration: const InputDecoration(labelText: 'العنوان'),
                  ),
                  TextFormField(
                    controller: deedController,
                    decoration: const InputDecoration(labelText: 'رقم الصك'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () async {
                if (formKey.currentState!.validate()) {
                  await provider.addProperty({
                    'name': nameController.text,
                    'owner_id': selectedOwnerId,
                    'city_id': selectedCityId,
                    'property_type_id': selectedPropertyTypeId,
                    'cost_center_id': selectedCostCenterId,
                    'address': addressController.text,
                    'deed_number': deedController.text,
                  });
                  if (context.mounted) Navigator.pop(context);
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PropertyProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) return const Center(child: CircularProgressIndicator());

        return Row(
          children: [
            // Master Pane (Properties List)
            Expanded(
              flex: 1,
              child: Container(
                decoration: BoxDecoration(
                  border: Border(left: BorderSide(color: Colors.grey.shade300)),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: ElevatedButton.icon(
                        onPressed: () => _showAddPropertyDialog(context, provider),
                        icon: const Icon(Icons.add),
                        label: const Text('إضافة عقار'),
                        style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        itemCount: provider.properties.length,
                        itemBuilder: (context, index) {
                          final prop = provider.properties[index];
                          final isSelected = _selectedPropertyId == prop['id'];
                          return ListTile(
                            title: Text(prop['name']),
                            subtitle: Text('المالك: ${provider.owners.firstWhere((o) => o['id'] == prop['owner_id'], orElse: () => {'name': 'غير معروف'})['name']}'),
                            selected: isSelected,
                            selectedTileColor: Colors.blue.withOpacity(0.1),
                            onTap: () {
                              setState(() {
                                _selectedPropertyId = prop['id'];
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Detail Pane (Units List for selected property)
            Expanded(
              flex: 2,
              child: _selectedPropertyId == null
                  ? const Center(child: Text('الرجاء اختيار عقار لعرض تفاصيله ووحداته'))
                  : UnitsDetailPane(propertyId: _selectedPropertyId!, provider: provider),
            ),
          ],
        );
      },
    );
  }
}

class UnitsDetailPane extends StatefulWidget {
  final int propertyId;
  final PropertyProvider provider;

  const UnitsDetailPane({super.key, required this.propertyId, required this.provider});

  @override
  State<UnitsDetailPane> createState() => _UnitsDetailPaneState();
}

class _UnitsDetailPaneState extends State<UnitsDetailPane> {
  List<Map<String, dynamic>> _units = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadUnits();
  }

  @override
  void didUpdateWidget(covariant UnitsDetailPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.propertyId != widget.propertyId) {
      _loadUnits();
    }
  }

  Future<void> _loadUnits() async {
    setState(() => _isLoading = true);
    _units = await DatabaseHelper.instance.getUnitsForProperty(widget.propertyId);
    setState(() => _isLoading = false);
  }

  void _showAddUnitDialog() {
    final formKey = GlobalKey<FormState>();
    final numController = TextEditingController();
    final rentController = TextEditingController();
    final floorController = TextEditingController();
    final elecController = TextEditingController();
    final waterController = TextEditingController();
    int? selectedUnitTypeId;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('إضافة وحدة/عين جديدة'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: numController,
                  decoration: const InputDecoration(labelText: 'رقم الوحدة/الشقة'),
                  validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                ),
                DropdownButtonFormField<int>(
                  value: selectedUnitTypeId,
                  items: widget.provider.unitTypes.map((t) => DropdownMenuItem<int>(
                    value: t['id'],
                    child: Text(t['name']),
                  )).toList(),
                  onChanged: (val) => selectedUnitTypeId = val,
                  decoration: const InputDecoration(labelText: 'نوع الوحدة'),
                ),
                TextFormField(
                  controller: floorController,
                  decoration: const InputDecoration(labelText: 'الدور'),
                ),
                TextFormField(
                  controller: elecController,
                  decoration: const InputDecoration(labelText: 'رقم عداد الكهرباء'),
                ),
                TextFormField(
                  controller: waterController,
                  decoration: const InputDecoration(labelText: 'رقم عداد الماء'),
                ),
                TextFormField(
                  controller: rentController,
                  decoration: const InputDecoration(labelText: 'الإيجار الافتراضي'),
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('إلغاء')),
            ElevatedButton(
              onPressed: () async {
                if (formKey.currentState!.validate()) {
                  await DatabaseHelper.instance.insertUnit({
                    'property_id': widget.propertyId,
                    'unit_number': numController.text,
                    'unit_type_id': selectedUnitTypeId,
                    'floor': floorController.text,
                    'elec_meter': elecController.text,
                    'water_meter': waterController.text,
                    'default_rent': double.tryParse(rentController.text) ?? 0.0,
                    'status': 'شاغرة', // Default status
                  });
                  if (context.mounted) {
                    Navigator.pop(context);
                    _loadUnits();
                  }
                }
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    final property = widget.provider.properties.firstWhere((p) => p['id'] == widget.propertyId);

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('وحدات العقار: ${property['name']}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton.icon(
              onPressed: _showAddUnitDialog,
              icon: const Icon(Icons.add),
              label: const Text('إضافة وحدة'),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('رقم الوحدة')),
                  DataColumn(label: Text('النوع')),
                  DataColumn(label: Text('الحالة')),
                  DataColumn(label: Text('الإيجار')),
                ],
                rows: _units.map((unit) {
                  final typeName = widget.provider.unitTypes.firstWhere((t) => t['id'] == unit['unit_type_id'], orElse: () => {'name': ''})['name'];
                  return DataRow(cells: [
                    DataCell(Text(unit['unit_number'] ?? '')),
                    DataCell(Text(typeName)),
                    DataCell(
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: unit['status'] == 'شاغرة' ? Colors.green.withOpacity(0.1) : Colors.orange.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(unit['status'] ?? '', style: TextStyle(color: unit['status'] == 'شاغرة' ? Colors.green : Colors.orange)),
                      ),
                    ),
                    DataCell(Text(unit['default_rent']?.toString() ?? '')),
                  ]);
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
