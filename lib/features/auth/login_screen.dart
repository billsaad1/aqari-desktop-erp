import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/company_logo_mark.dart';
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
  String? _errorMessage;
  bool _showPassword = false;

  Future<void> _login() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _errorMessage = null);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final success = await authProvider.login(
      _usernameController.text.trim(),
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
    } else if (mounted) {
      setState(
        () => _errorMessage =
            authProvider.errorMessage ??
            'تعذر تسجيل الدخول. تحقق من البيانات وحاول مجددًا.',
      );
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
          var saving = false;
          return StatefulBuilder(
            builder: (context, setDialogState) {
              Future<void> submit() async {
                if (saving) return;
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
                setDialogState(() {
                  saving = true;
                  errorText = '';
                });
                try {
                  await authProvider.changePassword(password);
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop(true);
                  }
                } catch (_) {
                  if (dialogContext.mounted) {
                    setDialogState(() {
                      saving = false;
                      errorText = 'تعذر حفظ كلمة المرور؛ حاول مرة أخرى';
                    });
                  }
                }
              }

              return PopScope(
                canPop: false,
                child: AlertDialog(
                  title: const Text('تعيين كلمة مرور جديدة'),
                  content: SizedBox(
                    width: 440,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'يجب تغيير كلمة المرور الأولية قبل استخدام النظام. اختر كلمة مرور لا تقل عن 12 حرفاً.',
                          ),
                          const SizedBox(height: 18),
                          TextField(
                            controller: passwordController,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'كلمة المرور الجديدة',
                              prefixIcon: Icon(Icons.lock_outline_rounded),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: confirmController,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'تأكيد كلمة المرور',
                              prefixIcon: Icon(Icons.lock_reset_rounded),
                            ),
                            onSubmitted: (_) => submit(),
                          ),
                          if (errorText.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _InlineAlert(message: errorText),
                          ],
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    FilledButton.icon(
                      onPressed: saving ? null : submit,
                      icon: saving
                          ? const SizedBox(
                              width: 17,
                              height: 17,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.lock_reset_rounded),
                      label: Text(saving ? 'جارٍ الحفظ...' : 'حفظ كلمة المرور'),
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
    final authProvider = context.watch<AuthProvider>();
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 920 && constraints.maxHeight >= 620) {
            return Row(
              children: [
                const Expanded(flex: 5, child: _BrandPanel()),
                Expanded(
                  flex: 6,
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(40),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 500),
                        child: _buildLoginCard(authProvider),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          return Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [Color(0xFFF5F8FA), Color(0xFFEAF1F5)],
              ),
            ),
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: _buildLoginCard(authProvider),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoginCard(AuthProvider authProvider) {
    return Card(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(36, 34, 36, 32),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: CompanyLogoMark(
                  size: 66,
                  iconColor: AppPalette.navy,
                  backgroundColor: AppPalette.emerald.withValues(alpha: 0.10),
                  radius: 20,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'مرحبًا بعودتك',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: AppPalette.navy,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'سجّل الدخول إلى نظام إدارة العقارات',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: AppPalette.mutedText),
              ),
              const SizedBox(height: 28),
              TextFormField(
                controller: _usernameController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'اسم المستخدم',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'الرجاء إدخال اسم المستخدم'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                obscureText: !_showPassword,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) =>
                    authProvider.isLoading ? null : _login(),
                decoration: InputDecoration(
                  labelText: 'كلمة المرور',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    tooltip: _showPassword
                        ? 'إخفاء كلمة المرور'
                        : 'إظهار كلمة المرور',
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
                validator: (value) => value == null || value.isEmpty
                    ? 'الرجاء إدخال كلمة المرور'
                    : null,
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: _errorMessage == null
                    ? const SizedBox(height: 14)
                    : Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: _InlineAlert(message: _errorMessage!),
                      ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  onPressed: authProvider.isLoading ? null : _login,
                  icon: authProvider.isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login_rounded),
                  label: Text(
                    authProvider.isLoading
                        ? 'جارٍ التحقق...'
                        : 'دخول إلى النظام',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'دخول آمن لإدارة العقارات والحسابات',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: AppPalette.mutedText),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [AppPalette.navy, AppPalette.deepNavy],
        ),
      ),
      padding: const EdgeInsets.all(56),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(),
          CompanyLogoMark(
            size: 82,
            iconColor: Colors.white,
            backgroundColor: AppPalette.emerald.withValues(alpha: 0.18),
            radius: 24,
            padding: 12,
          ),
          const SizedBox(height: 30),
          Text(
            'مؤسسة عبدالله النقيب التجارية',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'منصة موحّدة لإدارة العقارات والعقود والتحصيل والحسابات.',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: const Color(0xFFD2DEE7),
              height: 1.7,
            ),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF69D2AE),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                'إدارة دقيقة، وقرارات أوضح',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFDAE5EC),
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            'نظام إداري ومحاسبي للعقارات',
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: const Color(0xFF9FB3C8)),
          ),
        ],
      ),
    );
  }
}

class _InlineAlert extends StatelessWidget {
  const _InlineAlert({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppPalette.danger.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.danger.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppPalette.danger,
            size: 19,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppPalette.danger,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
