import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/app_theme.dart';
import '../../core/erp_data_table.dart';
import '../../core/rent_period.dart';
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
  final _propertySearchController = TextEditingController();

  @override
  void dispose() {
    _propertySearchController.dispose();
    super.dispose();
  }

  Future<void> _showEditPropertyDialog(
    BuildContext parentContext,
    PropertyProvider provider,
    Map<String, dynamic> property,
  ) async {
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController(
      text: property['name']?.toString() ?? '',
    );
    final addressController = TextEditingController(
      text: property['address']?.toString() ?? '',
    );
    final deedController = TextEditingController(
      text: property['deed_number']?.toString() ?? '',
    );
    try {
      await showDialog<void>(
        context: parentContext,
        builder: (dialogContext) => AlertDialog(
          title: const Text('تعديل بيانات العقار'),
          content: SizedBox(
            width: math.min(520, MediaQuery.sizeOf(dialogContext).width * 0.82),
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'اسم العقار'),
                    validator: (value) => value?.trim().isEmpty ?? true
                        ? 'اسم العقار مطلوب'
                        : null,
                  ),
                  TextFormField(
                    controller: addressController,
                    decoration: const InputDecoration(labelText: 'العنوان'),
                  ),
                  TextFormField(
                    controller: deedController,
                    decoration: const InputDecoration(labelText: 'رقم الصك'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'المالك: ${provider.owners.firstWhere((owner) => owner['id'] == property['owner_id'], orElse: () => {'name': 'غير معروف'})['name']} — تغيير الملكية يحتاج إجراء نقل ملكية منفصلًا لحماية تاريخ العقود.',
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إلغاء'),
            ),
            FilledButton.icon(
              onPressed: () async {
                if (!(formKey.currentState?.validate() ?? false)) return;
                try {
                  await provider.updateProperty({
                    ...property,
                    'name': nameController.text.trim(),
                    'address': addressController.text.trim(),
                    'deed_number': deedController.text.trim(),
                  });
                  if (!dialogContext.mounted) return;
                  Navigator.pop(dialogContext);
                  if (parentContext.mounted) {
                    ScaffoldMessenger.of(parentContext).showSnackBar(
                      const SnackBar(content: Text('تم تحديث بيانات العقار.')),
                    );
                  }
                } catch (error) {
                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(content: Text('تعذر تحديث العقار: $error')),
                    );
                  }
                }
              },
              icon: const Icon(Icons.save_outlined),
              label: const Text('حفظ التعديلات'),
            ),
          ],
        ),
      );
    } finally {
      nameController.dispose();
      addressController.dispose();
      deedController.dispose();
    }
  }

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
                    initialValue: selectedOwnerId,
                    items: provider.owners
                        .map(
                          (o) => DropdownMenuItem<int>(
                            value: o['id'],
                            child: Text(o['name']),
                          ),
                        )
                        .toList(),
                    onChanged: (val) => selectedOwnerId = val,
                    decoration: const InputDecoration(labelText: 'المالك'),
                    validator: (v) => v == null ? 'مطلوب' : null,
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: selectedCityId,
                    items: provider.cities
                        .map(
                          (c) => DropdownMenuItem<int>(
                            value: c['id'],
                            child: Text(c['name']),
                          ),
                        )
                        .toList(),
                    onChanged: (val) => selectedCityId = val,
                    decoration: const InputDecoration(labelText: 'المدينة'),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: selectedPropertyTypeId,
                    items: provider.propertyTypes
                        .map(
                          (pt) => DropdownMenuItem<int>(
                            value: pt['id'],
                            child: Text(pt['name']),
                          ),
                        )
                        .toList(),
                    onChanged: (val) => selectedPropertyTypeId = val,
                    decoration: const InputDecoration(labelText: 'نوع العقار'),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: selectedCostCenterId,
                    items: provider.costCenters
                        .map(
                          (c) => DropdownMenuItem<int>(
                            value: c['id'],
                            child: Text(c['name']),
                          ),
                        )
                        .toList(),
                    onChanged: (val) => selectedCostCenterId = val,
                    decoration: const InputDecoration(
                      labelText: 'مركز التكلفة',
                    ),
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
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (!(formKey.currentState?.validate() ?? false)) return;
                try {
                  await provider.addProperty({
                    'name': nameController.text.trim(),
                    'owner_id': selectedOwnerId,
                    'city_id': selectedCityId,
                    'property_type_id': selectedPropertyTypeId,
                    'cost_center_id': selectedCostCenterId,
                    'address': addressController.text.trim(),
                    'deed_number': deedController.text.trim(),
                  });
                  if (context.mounted) Navigator.pop(context);
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('تعذر حفظ العقار: $error')),
                    );
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
    return Consumer<PropertyProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        final query = _propertySearchController.text.trim().toLowerCase();
        final visibleProperties = provider.properties.where((property) {
          if (query.isEmpty) return true;
          final ownerName = provider.owners.firstWhere(
            (owner) => owner['id'] == property['owner_id'],
            orElse: () => {'name': ''},
          )['name'];
          return [
            property['name'],
            property['address'],
            property['deed_number'],
            ownerName,
            property['id'],
          ].join(' ').toLowerCase().contains(query);
        }).toList();

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
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          FilledButton.icon(
                            onPressed: () =>
                                _showAddPropertyDialog(context, provider),
                            icon: const Icon(Icons.add),
                            label: const Text('إضافة عقار'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(double.infinity, 48),
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _propertySearchController,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: 'بحث عن عقار أو مالك',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: query.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'مسح البحث',
                                      onPressed: () {
                                        _propertySearchController.clear();
                                        setState(() {});
                                      },
                                      icon: const Icon(Icons.close),
                                    ),
                              isDense: true,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: visibleProperties.isEmpty
                          ? Center(
                              child: Text(
                                query.isEmpty
                                    ? 'لا توجد عقارات مسجلة.'
                                    : 'لا توجد نتائج مطابقة.',
                              ),
                            )
                          : ListView.builder(
                              itemCount: visibleProperties.length,
                              itemBuilder: (context, index) {
                                final prop = visibleProperties[index];
                                final isSelected =
                                    _selectedPropertyId == prop['id'];
                                return ListTile(
                                  title: Text(prop['name']?.toString() ?? ''),
                                  subtitle: Text(
                                    'المالك: ${provider.owners.firstWhere((o) => o['id'] == prop['owner_id'], orElse: () => {'name': 'غير معروف'})['name']}',
                                  ),
                                  selected: isSelected,
                                  selectedTileColor: AppPalette.navy.withValues(
                                    alpha: 0.1,
                                  ),
                                  trailing: IconButton(
                                    tooltip: 'تعديل بيانات العقار',
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: () => _showEditPropertyDialog(
                                      context,
                                      provider,
                                      prop,
                                    ),
                                  ),
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
                  ? const Center(
                      child: Text('الرجاء اختيار عقار لعرض تفاصيله ووحداته'),
                    )
                  : UnitsDetailPane(
                      propertyId: _selectedPropertyId!,
                      provider: provider,
                    ),
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

  const UnitsDetailPane({
    super.key,
    required this.propertyId,
    required this.provider,
  });

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
    try {
      final units = await DatabaseHelper.instance.getUnitsForProperty(
        widget.propertyId,
      );
      if (!mounted) return;
      setState(() {
        _units = units;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل وحدات العقار: $error')),
      );
    }
  }

  Future<void> _showEditUnitDialog(Map<String, dynamic> unit) async {
    final formKey = GlobalKey<FormState>();
    final numberController = TextEditingController(
      text: unit['unit_number']?.toString() ?? '',
    );
    final rentController = TextEditingController(
      text: unit['default_rent']?.toString() ?? '',
    );
    final floorController = TextEditingController(
      text: unit['floor']?.toString() ?? '',
    );
    final electricityController = TextEditingController(
      text: unit['elec_meter']?.toString() ?? '',
    );
    final waterController = TextEditingController(
      text: unit['water_meter']?.toString() ?? '',
    );
    final initialTypeId = unit['unit_type_id'];
    int? selectedTypeId = initialTypeId is num ? initialTypeId.toInt() : null;
    String? selectedRentPeriod = unit['default_rent_period']?.toString();
    var saving = false;

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('تعديل بيانات الوحدة'),
            content: SizedBox(
              width: 440,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: numberController,
                        decoration: const InputDecoration(
                          labelText: 'رقم الوحدة/الشقة',
                        ),
                        validator: (value) => value?.trim().isEmpty ?? true
                            ? 'رقم الوحدة مطلوب'
                            : null,
                      ),
                      DropdownButtonFormField<int>(
                        initialValue:
                            widget.provider.unitTypes.any(
                              (type) => type['id'] == selectedTypeId,
                            )
                            ? selectedTypeId
                            : null,
                        items: widget.provider.unitTypes
                            .map(
                              (type) => DropdownMenuItem<int>(
                                value: type['id'] as int,
                                child: Text(type['name'].toString()),
                              ),
                            )
                            .toList(),
                        onChanged: saving
                            ? null
                            : (value) =>
                                  setDialogState(() => selectedTypeId = value),
                        decoration: const InputDecoration(
                          labelText: 'نوع الوحدة',
                        ),
                      ),
                      TextFormField(
                        controller: floorController,
                        decoration: const InputDecoration(labelText: 'الدور'),
                      ),
                      TextFormField(
                        controller: electricityController,
                        decoration: const InputDecoration(
                          labelText: 'رقم عداد الكهرباء',
                        ),
                      ),
                      TextFormField(
                        controller: waterController,
                        decoration: const InputDecoration(
                          labelText: 'رقم عداد الماء',
                        ),
                      ),
                      TextFormField(
                        controller: rentController,
                        decoration: const InputDecoration(
                          labelText: 'سعر الإيجار الافتراضي للوحدة',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        validator: (value) {
                          if ((value ?? '').trim().isEmpty) return null;
                          final rent = double.tryParse(value!.trim());
                          if (rent == null || !rent.isFinite || rent < 0) {
                            return 'أدخل مبلغًا صحيحًا أو اتركه فارغًا';
                          }
                          return null;
                        },
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: RentPeriod.isValid(selectedRentPeriod)
                            ? selectedRentPeriod
                            : null,
                        items: [
                          DropdownMenuItem(
                            value: RentPeriod.monthly,
                            child: Text(RentPeriod.label(RentPeriod.monthly)!),
                          ),
                          DropdownMenuItem(
                            value: RentPeriod.annual,
                            child: Text(RentPeriod.label(RentPeriod.annual)!),
                          ),
                        ],
                        onChanged: saving
                            ? null
                            : (value) => setDialogState(
                                () => selectedRentPeriod = value,
                              ),
                        validator: (value) => !RentPeriod.isValid(value)
                            ? 'حدد دورية الإيجار'
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'دورية سعر الوحدة',
                        ),
                      ),
                      if (!RentPeriod.isValid(selectedRentPeriod))
                        const Align(
                          alignment: Alignment.centerRight,
                          child: Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text(
                              'هذه وحدة قديمة بلا دورية محفوظة؛ اخترها قبل إنشاء عقد جديد.',
                              style: TextStyle(color: Colors.deepOrange),
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        'حالة الوحدة تُحدّث عبر دورة العقد فقط.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                child: const Text('إلغاء'),
              ),
              FilledButton.icon(
                onPressed: saving
                    ? null
                    : () async {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        setDialogState(() => saving = true);
                        try {
                          await widget.provider.updateUnit({
                            'id': unit['id'],
                            'unit_number': numberController.text.trim(),
                            'unit_type_id': selectedTypeId,
                            'floor': floorController.text.trim(),
                            'elec_meter': electricityController.text.trim(),
                            'water_meter': waterController.text.trim(),
                            'default_rent': rentController.text.trim().isEmpty
                                ? null
                                : double.parse(rentController.text.trim()),
                            'default_rent_period': selectedRentPeriod,
                          });
                          await _loadUnits();
                          if (!dialogContext.mounted) return;
                          Navigator.pop(dialogContext);
                          if (mounted) {
                            ScaffoldMessenger.of(this.context).showSnackBar(
                              const SnackBar(
                                content: Text('تم تحديث بيانات الوحدة.'),
                              ),
                            );
                          }
                        } catch (error) {
                          if (!dialogContext.mounted) return;
                          setDialogState(() => saving = false);
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            SnackBar(
                              content: Text('تعذر تحديث الوحدة: $error'),
                            ),
                          );
                        }
                      },
                icon: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(saving ? 'جارٍ الحفظ...' : 'حفظ التعديلات'),
              ),
            ],
          ),
        ),
      );
    } finally {
      numberController.dispose();
      rentController.dispose();
      floorController.dispose();
      electricityController.dispose();
      waterController.dispose();
    }
  }

  Future<void> _showAddUnitDialog() async {
    final formKey = GlobalKey<FormState>();
    final numController = TextEditingController();
    final rentController = TextEditingController();
    final floorController = TextEditingController();
    final elecController = TextEditingController();
    final waterController = TextEditingController();
    int? selectedUnitTypeId;
    String? selectedRentPeriod;
    var saving = false;

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('إضافة وحدة/عين جديدة'),
            content: SizedBox(
              width: 440,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: numController,
                        decoration: const InputDecoration(
                          labelText: 'رقم الوحدة/الشقة',
                        ),
                        validator: (value) => value?.trim().isEmpty ?? true
                            ? 'رقم الوحدة مطلوب'
                            : null,
                      ),
                      DropdownButtonFormField<int>(
                        initialValue: selectedUnitTypeId,
                        items: widget.provider.unitTypes
                            .map(
                              (type) => DropdownMenuItem<int>(
                                value: type['id'] as int,
                                child: Text(type['name'].toString()),
                              ),
                            )
                            .toList(),
                        onChanged: saving
                            ? null
                            : (value) => setDialogState(
                                () => selectedUnitTypeId = value,
                              ),
                        decoration: const InputDecoration(
                          labelText: 'نوع الوحدة',
                        ),
                      ),
                      TextFormField(
                        controller: floorController,
                        decoration: const InputDecoration(labelText: 'الدور'),
                      ),
                      TextFormField(
                        controller: elecController,
                        decoration: const InputDecoration(
                          labelText: 'رقم عداد الكهرباء',
                        ),
                      ),
                      TextFormField(
                        controller: waterController,
                        decoration: const InputDecoration(
                          labelText: 'رقم عداد الماء',
                        ),
                      ),
                      TextFormField(
                        controller: rentController,
                        decoration: const InputDecoration(
                          labelText: 'سعر الإيجار الافتراضي للوحدة',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        validator: (value) {
                          if ((value ?? '').trim().isEmpty) return null;
                          final rent = double.tryParse(value!.trim());
                          if (rent == null ||
                              !rent.isFinite ||
                              rent < 0 ||
                              ((rent * 100) - (rent * 100).round()).abs() >
                                  0.000001) {
                            return 'أدخل مبلغاً صحيحاً بمنزلتين عشريتين أو اتركه فارغاً';
                          }
                          return null;
                        },
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: selectedRentPeriod,
                        items: [
                          DropdownMenuItem(
                            value: RentPeriod.monthly,
                            child: Text(RentPeriod.label(RentPeriod.monthly)!),
                          ),
                          DropdownMenuItem(
                            value: RentPeriod.annual,
                            child: Text(RentPeriod.label(RentPeriod.annual)!),
                          ),
                        ],
                        onChanged: saving
                            ? null
                            : (value) => setDialogState(
                                () => selectedRentPeriod = value,
                              ),
                        validator: (value) => !RentPeriod.isValid(value)
                            ? 'حدد دورية الإيجار'
                            : null,
                        decoration: const InputDecoration(
                          labelText: 'دورية سعر الوحدة',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(dialogContext),
                child: const Text('إلغاء'),
              ),
              FilledButton.icon(
                onPressed: saving
                    ? null
                    : () async {
                        if (!(formKey.currentState?.validate() ?? false)) {
                          return;
                        }
                        setDialogState(() => saving = true);
                        try {
                          await DatabaseHelper.instance.insertUnit({
                            'property_id': widget.propertyId,
                            'unit_number': numController.text.trim(),
                            'unit_type_id': selectedUnitTypeId,
                            'floor': floorController.text.trim(),
                            'elec_meter': elecController.text.trim(),
                            'water_meter': waterController.text.trim(),
                            'default_rent': rentController.text.trim().isEmpty
                                ? null
                                : double.parse(rentController.text.trim()),
                            'default_rent_period': selectedRentPeriod,
                            'status': 'شاغرة',
                          });
                          if (!dialogContext.mounted) return;
                          Navigator.pop(dialogContext);
                          await _loadUnits();
                        } catch (error) {
                          if (!dialogContext.mounted) return;
                          setDialogState(() => saving = false);
                          ScaffoldMessenger.of(dialogContext).showSnackBar(
                            SnackBar(content: Text('تعذر حفظ الوحدة: $error')),
                          );
                        }
                      },
                icon: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(saving ? 'جارٍ الحفظ...' : 'حفظ الوحدة'),
              ),
            ],
          ),
        ),
      );
    } finally {
      numController.dispose();
      rentController.dispose();
      floorController.dispose();
      elecController.dispose();
      waterController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    final property = widget.provider.properties.firstWhere(
      (p) => p['id'] == widget.propertyId,
    );

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'وحدات العقار: ${property['name']}',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
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
              child: ErpDataTable(
                columns: const [
                  DataColumn(label: Text('رقم الوحدة')),
                  DataColumn(label: Text('النوع')),
                  DataColumn(label: Text('الحالة')),
                  DataColumn(label: Text('الإيجار')),
                  DataColumn(label: Text('إجراءات')),
                ],
                rows: _units.map((unit) {
                  final typeName = widget.provider.unitTypes.firstWhere(
                    (t) => t['id'] == unit['unit_type_id'],
                    orElse: () => {'name': ''},
                  )['name'];
                  return DataRow(
                    cells: [
                      DataCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(unit['unit_number'] ?? ''),
                            if (unit['has_duplicate_number'] == 1)
                              const Tooltip(
                                message:
                                    'رقم الوحدة مكرر في بيانات قديمة. راجع العقد وعدّل الرقم إلى رقم فريد.',
                                child: Padding(
                                  padding: EdgeInsets.only(right: 6),
                                  child: Icon(
                                    Icons.warning_amber_rounded,
                                    color: Colors.deepOrange,
                                    size: 18,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        onTap: () => _showEditUnitDialog(unit),
                      ),
                      DataCell(Text(typeName)),
                      DataCell(
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: unit['status'] == 'شاغرة'
                                ? Colors.green.withValues(alpha: 0.1)
                                : Colors.orange.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            unit['status'] ?? '',
                            style: TextStyle(
                              color: unit['status'] == 'شاغرة'
                                  ? Colors.green
                                  : Colors.orange,
                            ),
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          RentPeriod.isValid(unit['default_rent_period'])
                              ? unit['default_rent'] == null
                                    ? 'غير محدد السعر — ${RentPeriod.label(unit['default_rent_period'])}'
                                    : '${unit['default_rent']} — ${RentPeriod.label(unit['default_rent_period'])}'
                              : 'يلزم تحديد الدورية',
                        ),
                      ),
                      DataCell(
                        IconButton(
                          tooltip: 'تعديل بيانات الوحدة',
                          onPressed: () => _showEditUnitDialog(unit),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
