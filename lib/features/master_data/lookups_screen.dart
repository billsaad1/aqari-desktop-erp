import 'package:flutter/material.dart';
import '../../database/database_helper.dart';

class LookupsScreen extends StatefulWidget {
  const LookupsScreen({super.key});

  @override
  State<LookupsScreen> createState() => _LookupsScreenState();
}

class _LookupsScreenState extends State<LookupsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final List<LookupConfig> lookupConfigs = [
    LookupConfig('المدن', 'cities', ['name']),
    LookupConfig('الجنسيات', 'nationalities', ['name']),
    LookupConfig('البنوك', 'banks', ['name', 'account_id']),
    LookupConfig('أنواع العقارات', 'property_types', ['name']),
    LookupConfig('أنواع العيون', 'unit_types', ['name']),
    LookupConfig('مراكز التكلفة', 'cost_centers', ['code', 'name']),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: lookupConfigs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          labelColor: Colors.blue,
          unselectedLabelColor: Colors.grey,
          isScrollable: true,
          tabs: lookupConfigs.map((config) => Tab(text: config.title)).toList(),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: lookupConfigs.map((config) => LookupTab(config: config)).toList(),
          ),
        ),
      ],
    );
  }
}

class LookupConfig {
  final String title;
  final String tableName;
  final List<String> fields;

  LookupConfig(this.title, this.tableName, this.fields);
}

class LookupTab extends StatefulWidget {
  final LookupConfig config;
  const LookupTab({super.key, required this.config});

  @override
  State<LookupTab> createState() => _LookupTabState();
}

class _LookupTabState extends State<LookupTab> {
  List<Map<String, dynamic>> _data = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final data = await DatabaseHelper.instance.getLookupData(widget.config.tableName);
    setState(() {
      _data = data;
      _isLoading = false;
    });
  }

  void _showAddEditDialog([Map<String, dynamic>? item]) {
    final formKey = GlobalKey<FormState>();
    final Map<String, TextEditingController> controllers = {};

    for (var field in widget.config.fields) {
      controllers[field] = TextEditingController(text: item != null ? item[field]?.toString() : '');
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(item == null ? 'إضافة ${widget.config.title}' : 'تعديل ${widget.config.title}'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: widget.config.fields.map((field) {
                return TextFormField(
                  controller: controllers[field],
                  decoration: InputDecoration(labelText: field),
                  validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (formKey.currentState!.validate()) {
                  final Map<String, dynamic> data = {};
                  for (var field in widget.config.fields) {
                    data[field] = controllers[field]!.text;
                  }

                  if (item == null) {
                    await DatabaseHelper.instance.insertLookupData(widget.config.tableName, data);
                  } else {
                    data['id'] = item['id'];
                    await DatabaseHelper.instance.updateLookupData(widget.config.tableName, data);
                  }

                  if (context.mounted) {
                    Navigator.pop(context);
                    _loadData();
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

  void _deleteItem(int id) async {
    await DatabaseHelper.instance.deleteLookupData(widget.config.tableName, id);
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton.icon(
              onPressed: () => _showAddEditDialog(),
              icon: const Icon(Icons.add),
              label: Text('إضافة ${widget.config.title}'),
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: SingleChildScrollView(
              child: DataTable(
                columns: [
                  const DataColumn(label: Text('المعرف')),
                  ...widget.config.fields.map((field) => DataColumn(label: Text(field))),
                  const DataColumn(label: Text('الإجراءات')),
                ],
                rows: _data.map((row) {
                  return DataRow(
                    cells: [
                      DataCell(Text(row['id'].toString())),
                      ...widget.config.fields.map((field) => DataCell(Text(row[field]?.toString() ?? ''))),
                      DataCell(Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit, color: Colors.blue),
                            onPressed: () => _showAddEditDialog(row),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _deleteItem(row['id']),
                          ),
                        ],
                      )),
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
