import 'package:flutter/material.dart';
import '../../database/database_helper.dart';
import '../../core/crypto_utils.dart';
import '../../models/company_info_model.dart';

class SystemSettingsScreen extends StatefulWidget {
  const SystemSettingsScreen({super.key});

  @override
  State<SystemSettingsScreen> createState() => _SystemSettingsScreenState();
}

class _SystemSettingsScreenState extends State<SystemSettingsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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
          tabs: const [
            Tab(text: 'بيانات المنشأة'),
            Tab(text: 'المستخدمين والصلاحيات'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [
              CompanyInfoTab(),
              UsersTab(),
            ],
          ),
        ),
      ],
    );
  }
}

class CompanyInfoTab extends StatefulWidget {
  const CompanyInfoTab({super.key});

  @override
  State<CompanyInfoTab> createState() => _CompanyInfoTabState();
}

class _CompanyInfoTabState extends State<CompanyInfoTab> {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = true;
  CompanyInfo? _companyInfo;

  final _nameArController = TextEditingController();
  final _nameEnController = TextEditingController();
  final _activityController = TextEditingController();
  final _addressController = TextEditingController();
  final _currencyController = TextEditingController();
  final _logoPathController = TextEditingController();
  final _termsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCompanyInfo();
  }

  Future<void> _loadCompanyInfo() async {
    final infoMap = await DatabaseHelper.instance.getCompanyInfo();
    if (infoMap != null) {
      _companyInfo = CompanyInfo.fromMap(infoMap);
      _nameArController.text = _companyInfo!.nameAr;
      _nameEnController.text = _companyInfo!.nameEn ?? '';
      _activityController.text = _companyInfo!.activity ?? '';
      _addressController.text = _companyInfo!.address ?? '';
      _currencyController.text = _companyInfo!.defaultCurrency ?? '';
      _logoPathController.text = _companyInfo!.logoPath ?? '';
      _termsController.text = _companyInfo!.termsConditions ?? '';
    }
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _saveCompanyInfo() async {
    if (_formKey.currentState!.validate()) {
      final updatedInfo = CompanyInfo(
        id: _companyInfo?.id ?? 1,
        nameAr: _nameArController.text,
        nameEn: _nameEnController.text,
        activity: _activityController.text,
        address: _addressController.text,
        defaultCurrency: _currencyController.text,
        logoPath: _logoPathController.text,
        termsConditions: _termsController.text,
      );

      await DatabaseHelper.instance.updateCompanyInfo(updatedInfo.toMap());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم الحفظ بنجاح')),
        );
      }
    }
  }

  @override
  void dispose() {
    _nameArController.dispose();
    _nameEnController.dispose();
    _activityController.dispose();
    _addressController.dispose();
    _currencyController.dispose();
    _logoPathController.dispose();
    _termsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Form(
        key: _formKey,
        child: ListView(
          children: [
            TextFormField(
              controller: _nameArController,
              decoration: const InputDecoration(labelText: 'اسم المنشأة (عربي)', border: OutlineInputBorder()),
              validator: (value) => value == null || value.isEmpty ? 'مطلوب' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nameEnController,
              decoration: const InputDecoration(labelText: 'اسم المنشأة (إنجليزي)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _activityController,
              decoration: const InputDecoration(labelText: 'النشاط', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _addressController,
              decoration: const InputDecoration(labelText: 'العنوان', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _currencyController,
              decoration: const InputDecoration(labelText: 'العملة الافتراضية', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _logoPathController,
              decoration: const InputDecoration(
                labelText: 'مسار الشعار (Logo Path - مثلاً C:\\images\\logo.png)',
                border: OutlineInputBorder(),
                hintText: 'مسار ملف الشعار في الجهاز'
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _termsController,
              decoration: const InputDecoration(
                labelText: 'الشروط والأحكام الافتراضية لعقد الإيجار',
                border: OutlineInputBorder()
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _saveCompanyInfo,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(16)),
              child: const Text('حفظ التعديلات', style: TextStyle(fontSize: 18)),
            ),
          ],
        ),
      ),
    );
  }
}

class UsersTab extends StatefulWidget {
  const UsersTab({super.key});

  @override
  State<UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<UsersTab> {
  List<Map<String, dynamic>> _users = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    final users = await DatabaseHelper.instance.getAllUsers();
    setState(() {
      _users = users;
      _isLoading = false;
    });
  }

  void _showAddUserDialog() {
    final formKey = GlobalKey<FormState>();
    final fullNameController = TextEditingController();
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final roleController = TextEditingController();
    roleController.text = 'User';

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('إضافة مستخدم جديد'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: fullNameController,
                  decoration: const InputDecoration(labelText: 'الاسم الكامل'),
                  validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                ),
                TextFormField(
                  controller: usernameController,
                  decoration: const InputDecoration(labelText: 'اسم المستخدم'),
                  validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                ),
                TextFormField(
                  controller: passwordController,
                  decoration: const InputDecoration(labelText: 'كلمة المرور'),
                  obscureText: true,
                  validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                ),
                TextFormField(
                  controller: roleController,
                  decoration: const InputDecoration(labelText: 'الدور (مثال: Admin, User)'),
                  validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                ),
              ],
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
                  final hashedPassword = CryptoUtils.hashPassword(passwordController.text);
                  await DatabaseHelper.instance.insertUser({
                    'full_name': fullNameController.text,
                    'username': usernameController.text,
                    'password_hash': hashedPassword,
                    'role': roleController.text,
                  });
                  if (context.mounted) {
                    Navigator.pop(context);
                    _loadUsers();
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

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('إدارة المستخدمين', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              ElevatedButton.icon(
                onPressed: _showAddUserDialog,
                icon: const Icon(Icons.add),
                label: const Text('إضافة مستخدم'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: SingleChildScrollView(
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('المعرف')),
                  DataColumn(label: Text('الاسم الكامل')),
                  DataColumn(label: Text('اسم المستخدم')),
                  DataColumn(label: Text('الدور')),
                ],
                rows: _users.map((user) {
                  return DataRow(cells: [
                    DataCell(Text(user['id'].toString())),
                    DataCell(Text(user['full_name'])),
                    DataCell(Text(user['username'])),
                    DataCell(Text(user['role'])),
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
