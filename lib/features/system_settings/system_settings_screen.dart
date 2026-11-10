import 'package:file_selector/file_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import '../../database/database_helper.dart';
import '../../core/crypto_utils.dart';
import '../../models/company_info_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/navigation_provider.dart';
import '../auth/login_screen.dart';

class SystemSettingsScreen extends StatefulWidget {
  const SystemSettingsScreen({super.key});

  @override
  State<SystemSettingsScreen> createState() => _SystemSettingsScreenState();
}

class _SystemSettingsScreenState extends State<SystemSettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
            Tab(text: 'الصيانة والنسخ الاحتياطي'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: const [CompanyInfoTab(), UsersTab(), MaintenanceTab()],
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

  final _activityArController = TextEditingController();
  final _activityEnController = TextEditingController();
  final _addressArController = TextEditingController();
  final _addressEnController = TextEditingController();
  final _taxNumberController = TextEditingController();
  final _commercialRegisterController = TextEditingController();
  final _poBoxController = TextEditingController();
  final _telephoneController = TextEditingController();
  final _faxController = TextEditingController();
  final _mobileController = TextEditingController();

  String? _selectedCurrency = 'ريال سعودي (SAR)';
  final _logoPathController = TextEditingController();
  final _termsController = TextEditingController();

  final List<String> _currencies = [
    'ريال يمني (YER)',
    'ريال سعودي (SAR)',
    'دولار أمريكي (USD)',
  ];

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
      _logoPathController.text = _companyInfo!.logoPath ?? '';
      _termsController.text = _companyInfo!.termsConditions ?? '';

      _activityArController.text = _companyInfo!.activityNameAr ?? '';
      _activityEnController.text = _companyInfo!.activityNameEn ?? '';
      _addressArController.text = _companyInfo!.addressAr ?? '';
      _addressEnController.text = _companyInfo!.addressEn ?? '';
      _taxNumberController.text = _companyInfo!.taxNumber ?? '';
      _commercialRegisterController.text =
          _companyInfo!.commercialRegister ?? '';
      _poBoxController.text = _companyInfo!.poBox ?? '';
      _telephoneController.text = _companyInfo!.telephone ?? '';
      _faxController.text = _companyInfo!.fax ?? '';
      _mobileController.text = _companyInfo!.mobile ?? '';

      if (_companyInfo!.defaultCurrency != null &&
          _companyInfo!.defaultCurrency!.isNotEmpty) {
        if (_currencies.contains(_companyInfo!.defaultCurrency)) {
          _selectedCurrency = _companyInfo!.defaultCurrency;
        }
      }
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
        defaultCurrency: _selectedCurrency,
        logoPath: _logoPathController.text,
        termsConditions: _termsController.text,
        activityNameAr: _activityArController.text,
        activityNameEn: _activityEnController.text,
        addressAr: _addressArController.text,
        addressEn: _addressEnController.text,
        taxNumber: _taxNumberController.text,
        commercialRegister: _commercialRegisterController.text,
        poBox: _poBoxController.text,
        telephone: _telephoneController.text,
        fax: _faxController.text,
        mobile: _mobileController.text,
      );

      await DatabaseHelper.instance.updateCompanyInfo(updatedInfo.toMap());
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم الحفظ بنجاح')));
      }
    }
  }

  @override
  void dispose() {
    _nameArController.dispose();
    _nameEnController.dispose();
    _activityController.dispose();
    _addressController.dispose();
    _logoPathController.dispose();
    _termsController.dispose();
    _activityArController.dispose();
    _activityEnController.dispose();
    _addressArController.dispose();
    _addressEnController.dispose();
    _taxNumberController.dispose();
    _commercialRegisterController.dispose();
    _poBoxController.dispose();
    _telephoneController.dispose();
    _faxController.dispose();
    _mobileController.dispose();
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
              decoration: const InputDecoration(
                labelText: 'اسم المنشأة (عربي)',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  value == null || value.isEmpty ? 'مطلوب' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nameEnController,
              decoration: const InputDecoration(
                labelText: 'اسم المنشأة (إنجليزي)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _activityArController,
                    decoration: const InputDecoration(
                      labelText: 'النشاط (عربي)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _activityEnController,
                    decoration: const InputDecoration(
                      labelText: 'النشاط (إنجليزي)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _commercialRegisterController,
                    decoration: const InputDecoration(
                      labelText: 'السجل التجاري (C.R)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _taxNumberController,
                    decoration: const InputDecoration(
                      labelText: 'الرقم الضريبي (VAT)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _addressArController,
                    decoration: const InputDecoration(
                      labelText: 'العنوان (عربي)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _addressEnController,
                    decoration: const InputDecoration(
                      labelText: 'العنوان (إنجليزي)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _poBoxController,
                    decoration: const InputDecoration(
                      labelText: 'ص.ب (P.O Box)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _telephoneController,
                    decoration: const InputDecoration(
                      labelText: 'هاتف (Telephone)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _faxController,
                    decoration: const InputDecoration(
                      labelText: 'فاكس (Fax)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _mobileController,
                    decoration: const InputDecoration(
                      labelText: 'جوال (Mobile)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedCurrency,
              decoration: const InputDecoration(
                labelText: 'العملة الافتراضية',
                border: OutlineInputBorder(),
              ),
              items: _currencies
                  .map(
                    (curr) => DropdownMenuItem(value: curr, child: Text(curr)),
                  )
                  .toList(),
              onChanged: (val) {
                setState(() {
                  _selectedCurrency = val;
                });
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _logoPathController,
              decoration: const InputDecoration(
                labelText:
                    'مسار الشعار (Logo Path - مثلاً C:\\images\\logo.png)',
                border: OutlineInputBorder(),
                hintText: 'مسار ملف الشعار في الجهاز',
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _termsController,
              decoration: const InputDecoration(
                labelText: 'الشروط والأحكام الافتراضية لعقد الإيجار',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _saveCompanyInfo,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
              child: const Text(
                'حفظ التعديلات',
                style: TextStyle(fontSize: 18),
              ),
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
    String selectedRole = 'DataEntry';

    final List<String> roles = [
      'SuperAdmin',
      'Admin',
      'Accountant',
      'DataEntry',
    ];
    final Map<String, String> roleLabels = {
      'SuperAdmin': 'SuperAdmin (مدير نظام)',
      'Admin': 'Admin (مدير)',
      'Accountant': 'Accountant (محاسب)',
      'DataEntry': 'DataEntry (مدخل بيانات)',
    };

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('إضافة مستخدم جديد'),
              content: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: fullNameController,
                      decoration: const InputDecoration(
                        labelText: 'الاسم الكامل',
                      ),
                      validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                    ),
                    TextFormField(
                      controller: usernameController,
                      decoration: const InputDecoration(
                        labelText: 'اسم المستخدم',
                      ),
                      validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                    ),
                    TextFormField(
                      controller: passwordController,
                      decoration: const InputDecoration(
                        labelText: 'كلمة المرور',
                      ),
                      obscureText: true,
                      validator: (v) => v!.isEmpty ? 'مطلوب' : null,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: selectedRole,
                      decoration: const InputDecoration(labelText: 'الدور'),
                      items: roles.map((role) {
                        return DropdownMenuItem<String>(
                          value: role,
                          child: Text(roleLabels[role]!),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        if (newValue != null) {
                          setDialogState(() {
                            selectedRole = newValue;
                          });
                        }
                      },
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
                      final hashedPassword = CryptoUtils.hashPassword(
                        passwordController.text,
                      );
                      await DatabaseHelper.instance.insertUser({
                        'full_name': fullNameController.text,
                        'username': usernameController.text,
                        'password_hash': hashedPassword,
                        'role': selectedRole,
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
              const Text(
                'إدارة المستخدمين',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
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
                  return DataRow(
                    cells: [
                      DataCell(Text(user['id'].toString())),
                      DataCell(Text(user['full_name'])),
                      DataCell(Text(user['username'])),
                      DataCell(Text(user['role'])),
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

class MaintenanceTab extends StatefulWidget {
  const MaintenanceTab({super.key});

  @override
  State<MaintenanceTab> createState() => _MaintenanceTabState();
}

class _MaintenanceTabState extends State<MaintenanceTab> {
  String _backupPath = '';
  final _backupPathController = TextEditingController();
  final _confirmController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadBackupPath();
  }

  Future<void> _loadBackupPath() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _backupPath = prefs.getString('backup_path') ?? '';
      _backupPathController.text = _backupPath;
    });
  }

  Future<void> _selectBackupFolder() async {
    String? selectedDirectory = await getDirectoryPath();
    if (selectedDirectory != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('backup_path', selectedDirectory);
      setState(() {
        _backupPath = selectedDirectory;
        _backupPathController.text = selectedDirectory;
      });
    }
  }

  Future<void> _performBackup() async {
    if (_backupPath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('الرجاء اختيار مجلد النسخ الاحتياطي أولاً'),
        ),
      );
      return;
    }

    try {
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .replaceAll('.', '');
      final backupFilePath = p.join(
        _backupPath,
        'aqari_erp_backup_$timestamp.db',
      );
      await DatabaseHelper.instance.backupToFile(backupFilePath);

      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تم النسخ الاحتياطي بنجاح إلى: $backupFilePath'),
          ),
        );
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('فشل النسخ الاحتياطي: $e')));
    }
  }

  void _showFactoryResetDialog() {
    _confirmController.clear();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text(
                'تحذير خطير: تهيئة النظام',
                style: TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'هذا الإجراء سيمسح جميع البيانات المدخلة في النظام (عقود، مستأجرين، سندات، الخ) وسيعيده كأنه جديد.',
                  ),
                  const SizedBox(height: 16),
                  const Text('لتأكيد الحذف، اكتب كلمة "تأكيد" في الحقل أدناه:'),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _confirmController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'تأكيد',
                    ),
                    onChanged: (val) => setStateDialog(() {}),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  onPressed: _confirmController.text == 'تأكيد'
                      ? () async {
                          Navigator.pop(context);
                          await _performFactoryReset();
                        }
                      : null,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text(
                    'مسح البيانات نهائياً',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _performFactoryReset() async {
    try {
      await Provider.of<AuthProvider>(context, listen: false).logout();
      await DatabaseHelper.instance.factoryReset();
      if (mounted) {
        Provider.of<NavigationProvider>(context, listen: false).reset();
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (_) => false,
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('فشل تهيئة النظام: $e')));
    }
  }

  @override
  void dispose() {
    _backupPathController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'نسخة احتياطية يدوية متحقق منها',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  decoration: const InputDecoration(
                    labelText: 'مسار مجلد النسخ الاحتياطي',
                    border: OutlineInputBorder(),
                  ),
                  controller: _backupPathController,
                  readOnly: true,
                ),
              ),
              const SizedBox(width: 16),
              ElevatedButton.icon(
                onPressed: _selectBackupFolder,
                icon: const Icon(Icons.folder),
                label: const Text('تحديد المجلد'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _performBackup,
            icon: const Icon(Icons.backup),
            label: const Text('نسخ احتياطي الآن'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.all(16),
              backgroundColor: Colors.green,
            ),
          ),
          const SizedBox(height: 48),
          const Divider(),
          const SizedBox(height: 24),
          const Text(
            'تهيئة وتصفير النظام (Factory Reset)',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.red,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'احذر: هذه العملية ستمسح جميع قواعد البيانات الخاصة بالمؤسسة.',
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _showFactoryResetDialog,
            icon: const Icon(Icons.warning, color: Colors.white),
            label: const Text(
              'تصفير النظام بالكامل',
              style: TextStyle(color: Colors.white),
            ),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.all(16),
              backgroundColor: Colors.red,
            ),
          ),
        ],
      ),
    );
  }
}
