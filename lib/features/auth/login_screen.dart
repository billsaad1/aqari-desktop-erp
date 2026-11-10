import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../main_shell/main_shell_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  void _login() async {
    if (_formKey.currentState!.validate()) {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final success = await authProvider.login(
        _usernameController.text,
        _passwordController.text,
      );

      if (success) {
        if (authProvider.currentUser?.mustChangePassword == true) {
          final changed = await _requirePasswordChange(authProvider);
          if (!changed) {
            await authProvider.logout();
            return;
          }
        }
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainShellScreen()),
        );
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(authProvider.errorMessage ?? 'خطأ في تسجيل الدخول'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<bool> _requirePasswordChange(AuthProvider authProvider) async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    try {
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          var errorText = '';
          return StatefulBuilder(
            builder: (context, setDialogState) {
              Future<void> submit() async {
                final password = passwordController.text;
                if (password.length < 12) {
                  setDialogState(
                    () => errorText = 'كلمة المرور يجب ألا تقل عن 12 حرفاً',
                  );
                  return;
                }
                if (password != confirmController.text) {
                  setDialogState(
                    () => errorText = 'كلمتا المرور غير متطابقتين',
                  );
                  return;
                }
                try {
                  await authProvider.changePassword(password);
                  if (dialogContext.mounted)
                    Navigator.of(dialogContext).pop(true);
                } catch (_) {
                  setDialogState(
                    () => errorText = 'تعذر حفظ كلمة المرور؛ حاول مرة أخرى',
                  );
                }
              }

              return PopScope(
                canPop: false,
                child: AlertDialog(
                  title: const Text('تعيين كلمة مرور جديدة'),
                  content: SizedBox(
                    width: 420,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'يجب تغيير كلمة المرور الأولية قبل استخدام النظام. اختر كلمة مرور لا تقل عن 12 حرفاً.',
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: passwordController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'كلمة المرور الجديدة',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: confirmController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'تأكيد كلمة المرور',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => submit(),
                        ),
                        if (errorText.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            errorText,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                      ],
                    ),
                  ),
                  actions: [
                    ElevatedButton.icon(
                      onPressed: submit,
                      icon: const Icon(Icons.lock_reset),
                      label: const Text('حفظ كلمة المرور'),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
      return result ?? false;
    } finally {
      passwordController.dispose();
      confirmController.dispose();
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);

    return Scaffold(
      body: Center(
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(32.0),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(color: Colors.black12, blurRadius: 10, spreadRadius: 5),
            ],
          ),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.business, size: 80, color: Colors.blue),
                const SizedBox(height: 16),
                const Text(
                  'تسجيل الدخول',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'اسم المستخدم',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'الرجاء إدخال اسم المستخدم';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock),
                  ),
                  obscureText: true,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'الرجاء إدخال كلمة المرور';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: authProvider.isLoading ? null : _login,
                    child: authProvider.isLoading
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Text('دخول', style: TextStyle(fontSize: 18)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
