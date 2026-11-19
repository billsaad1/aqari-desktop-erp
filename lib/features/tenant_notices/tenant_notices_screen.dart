import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/permission_policy.dart';
import '../../providers/tenant_notices_provider.dart';

class TenantNoticesScreen extends StatefulWidget {
  const TenantNoticesScreen({super.key});

  @override
  State<TenantNoticesScreen> createState() => _TenantNoticesScreenState();
}

class _TenantNoticesScreenState extends State<TenantNoticesScreen> {
  int? _selectedNoticeId;
  Map<String, dynamic>? _selectedNotice;
  Future<List<Map<String, dynamic>>>? _eventsFuture;
  late Future<Map<String, dynamic>?> _companyFuture;
  bool _isLoadingDetails = false;

  @override
  void initState() {
    super.initState();
    final provider = context.read<TenantNoticesProvider>();
    _companyFuture = provider.loadCompanyInfo();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload({int? selectNoticeId}) async {
    final provider = context.read<TenantNoticesProvider>();
    try {
      await provider.loadNotices();
      if (!mounted) return;
      final notices = provider.notices;
      final desiredId = selectNoticeId ?? _selectedNoticeId;
      final nextId = notices.any((item) => item['id'] == desiredId)
          ? desiredId
          : (notices.isEmpty ? null : notices.first['id'] as int?);
      if (nextId == null) {
        setState(() {
          _selectedNoticeId = null;
          _selectedNotice = null;
          _eventsFuture = null;
        });
      } else {
        await _selectNotice(nextId);
      }
    } catch (error) {
      if (mounted) _showMessage('تعذر تحميل الإشعارات: $error', isError: true);
    }
  }

  Future<void> _selectNotice(int id) async {
    setState(() {
      _selectedNoticeId = id;
      _selectedNotice = null;
      _isLoadingDetails = true;
      _eventsFuture = context.read<TenantNoticesProvider>().loadEvents(id);
    });
    try {
      final notice = await context.read<TenantNoticesProvider>().loadNotice(id);
      if (!mounted || _selectedNoticeId != id) return;
      setState(() {
        _selectedNotice = notice;
        _isLoadingDetails = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingDetails = false);
      _showMessage('تعذر تحميل تفاصيل الإشعار: $error', isError: true);
    }
  }

  Future<void> _createNotice() async {
    final id = await showDialog<int>(
      context: context,
      builder: (_) => _TenantNoticeEditorDialog(
        provider: context.read<TenantNoticesProvider>(),
      ),
    );
    if (!mounted || id == null) return;
    await _reload(selectNoticeId: id);
    _showMessage('حُفظت مسودة الإشعار. لم يُرسل أي SMS.');
  }

  Future<void> _editNotice(Map<String, dynamic> notice) async {
    final id = notice['id'] as int;
    final savedId = await showDialog<int>(
      context: context,
      builder: (_) => _TenantNoticeEditorDialog(
        provider: context.read<TenantNoticesProvider>(),
        initialNotice: notice,
      ),
    );
    if (!mounted || savedId == null) return;
    await _reload(selectNoticeId: id);
    _showMessage('تم تحديث المسودة.');
  }

  Future<void> _issueNotice(Map<String, dynamic> notice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إصدار الإشعار'),
        content: const Text(
          'سيُثبّت الإشعار في السجل ويصبح غير قابل للتعديل أو الحذف. الإصدار لا يرسل رسالة نصية ولا ينشئ أي حركة مالية.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('رجوع'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.verified_outlined),
            label: const Text('إصدار وتثبيت'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await context.read<TenantNoticesProvider>().issue(notice['id'] as int);
      await _reload(selectNoticeId: notice['id'] as int);
      if (mounted) _showMessage('تم إصدار الإشعار وتثبيته في السجل.');
    } catch (error) {
      if (mounted) _showMessage('تعذر إصدار الإشعار: $error', isError: true);
    }
  }

  Future<void> _saveWord(Map<String, dynamic> notice) async {
    final id = notice['id'] as int;
    final provider = context.read<TenantNoticesProvider>();
    late final String path;
    try {
      final bytes = await provider.buildWord(id);
      final location = await getSaveLocation(
        suggestedName: 'إشعار_مستأجر_$id.docx',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Word', extensions: ['docx']),
        ],
      );
      if (!mounted || location == null) return;
      path = p.extension(location.path).toLowerCase() == '.docx'
          ? location.path
          : '${location.path}.docx';
      await File(path).writeAsBytes(bytes, flush: true);
    } catch (error) {
      if (mounted) {
        _showMessage('تعذر إنشاء ملف Word أو حفظه: $error', isError: true);
      }
      return;
    }

    try {
      await provider.recordWordExport(noticeId: id, fileName: p.basename(path));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _eventsFuture = provider.loadEvents(id);
      });
      _showMessage(
        'تم حفظ الملف، لكن تعذر تسجيل التصدير في سجل التدقيق: $error',
        isError: true,
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _eventsFuture = provider.loadEvents(id);
    });
    _showMessage('تم حفظ ملف Word وتسجيل عملية التصدير.');
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canAdd = PermissionRuntime.allows('notices', AppPermissionAction.add);
    final canEdit = PermissionRuntime.allows(
      'notices',
      AppPermissionAction.edit,
    );
    final canIssue = PermissionRuntime.allows(
      'notices',
      AppPermissionAction.post,
    );
    final canPrint = PermissionRuntime.allows(
      'notices',
      AppPermissionAction.print,
    );

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.mark_email_unread_outlined,
                color: AppPalette.navy,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'إشعارات المستأجرين',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'إنشاء خطاب موثق ومعاينته قبل الإصدار أو التصدير إلى Word.',
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'تحديث',
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
              ),
              if (canAdd)
                FilledButton.icon(
                  onPressed: _createNotice,
                  icon: const Icon(Icons.add),
                  label: const Text('إشعار جديد'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Consumer<TenantNoticesProvider>(
              builder: (context, provider, _) {
                if (provider.isLoading && provider.notices.isEmpty) {
                  return const Center(child: CircularProgressIndicator());
                }
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final listPane = _noticeList(provider.notices);
                    final previewPane = _detailPane(
                      canEdit: canEdit,
                      canIssue: canIssue,
                      canPrint: canPrint,
                    );
                    if (constraints.maxWidth < 850) {
                      return Column(
                        children: [
                          SizedBox(height: 230, child: listPane),
                          const SizedBox(height: 12),
                          Expanded(child: previewPane),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 340, child: listPane),
                        const SizedBox(width: 16),
                        Expanded(child: previewPane),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _noticeList(List<Map<String, dynamic>> notices) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'سجل الإشعارات',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text('${notices.length}'),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: notices.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'لا توجد إشعارات بعد. أنشئ مسودة جديدة للبدء.',
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: notices.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 16, endIndent: 16),
                    itemBuilder: (context, index) {
                      final notice = notices[index];
                      final id = notice['id'] as int;
                      final selected = id == _selectedNoticeId;
                      final issued = notice['status'] == 'Issued';
                      return ListTile(
                        mouseCursor: SystemMouseCursors.click,
                        selected: selected,
                        selectedTileColor: AppPalette.navy.withValues(
                          alpha: 0.08,
                        ),
                        onTap: () => _selectNotice(id),
                        leading: CircleAvatar(
                          backgroundColor: issued
                              ? AppPalette.emerald.withValues(alpha: 0.16)
                              : Colors.amber.withValues(alpha: 0.2),
                          child: Icon(
                            issued
                                ? Icons.verified_outlined
                                : Icons.edit_note_outlined,
                            color: issued
                                ? AppPalette.emerald
                                : Colors.orange.shade800,
                          ),
                        ),
                        title: Text(
                          notice['subject']?.toString() ?? 'إشعار بلا موضوع',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${notice['recipient_name_snapshot'] ?? ''} • ${notice['notice_date'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text(issued ? 'صادر' : 'مسودة'),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _detailPane({
    required bool canEdit,
    required bool canIssue,
    required bool canPrint,
  }) {
    final notice = _selectedNotice;
    if (_isLoadingDetails) {
      return const Card(child: Center(child: CircularProgressIndicator()));
    }
    if (notice == null) {
      return const Card(
        child: Center(child: Text('اختر إشعارًا لعرض معاينته وسجل إجراءاته.')),
      );
    }
    final issued = notice['status'] == 'Issued';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'معاينة الإشعار رقم ${notice['id']}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (!issued && canEdit)
                  TextButton.icon(
                    onPressed: () => _editNotice(notice),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('تعديل'),
                  ),
                if (!issued && canIssue)
                  FilledButton.tonalIcon(
                    onPressed: () => _issueNotice(notice),
                    icon: const Icon(Icons.verified_outlined),
                    label: const Text('إصدار'),
                  ),
                if (issued && canPrint)
                  FilledButton.icon(
                    onPressed: () => _saveWord(notice),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('حفظ Word'),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 700),
                      child: _letterPreview(notice),
                    ),
                  ),
                  const SizedBox(height: 18),
                  _eventHistory(),
                ],
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsetsDirectional.fromSTEB(14, 0, 14, 12),
            child: Text(
              'الإصدار والتصدير لا يرسلان SMS ولا ينشئان أي قيد أو حركة مالية.',
              style: TextStyle(color: Colors.black54, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _letterPreview(Map<String, dynamic> notice) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: _companyFuture,
      builder: (context, snapshot) {
        final company = snapshot.data ?? const <String, dynamic>{};
        final name = company['name_ar']?.toString() ?? 'إدارة العقارات';
        final activity =
            company['activity_name_ar']?.toString() ??
            company['activity']?.toString() ??
            '';
        final address =
            company['address_ar']?.toString() ??
            company['address']?.toString() ??
            '';
        final phone =
            company['telephone']?.toString() ??
            company['mobile']?.toString() ??
            '';
        final logoPath = company['logo_path']?.toString() ?? '';
        final contract = _contractSnapshot(notice['contract_snapshot_json']);
        String sourceLabel(Object? source) =>
            source == 'contract_party_snapshot'
            ? 'لقطة العقد عند إنشائه'
            : 'السجل الحالي وقت إعداد الإشعار';
        final contractSourceNote = contract == null
            ? ''
            : '${contract['party_snapshot_source'] == 'partial_contract_party_snapshot' ? 'لقطة العقد جزئية. ' : ''}'
                  'مصدر اسم العقار: ${sourceLabel(contract['property_name_source'])}؛ '
                  'رقم الوحدة: ${sourceLabel(contract['unit_number_source'])}؛ '
                  'المستأجر: سجله وقت إعداد الإشعار؛ تواريخ/حالة العقد: سجله الحالي.';
        return Directionality(
          textDirection: TextDirection.rtl,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.blueGrey.shade200),
              borderRadius: BorderRadius.circular(8),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x12000000),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (logoPath.isNotEmpty && File(logoPath).existsSync()) ...[
                  Center(
                    child: Image.file(
                      File(logoPath),
                      height: 58,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                Text(
                  name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    color: AppPalette.navy,
                  ),
                ),
                if (activity.isNotEmpty)
                  Text(
                    activity,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13),
                  ),
                if (address.isNotEmpty || phone.isNotEmpty)
                  Text(
                    [
                      address,
                      if (phone.isNotEmpty) 'هاتف: $phone',
                    ].where((value) => value.isNotEmpty).join(' | '),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                const Divider(height: 24, thickness: 1.4),
                const Text(
                  'إشعار',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Text(
                  'رقم الإشعار: ${notice['id']}     التاريخ: ${notice['notice_date'] ?? ''}',
                ),
                const SizedBox(height: 8),
                Text(
                  'إلى: ${notice['recipient_name_snapshot'] ?? ''}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if ((notice['recipient_phone_snapshot']?.toString() ?? '')
                    .isNotEmpty)
                  Text('رقم التواصل: ${notice['recipient_phone_snapshot']}'),
                if (contract != null) ...[
                  Text(
                    contractSourceNote,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.blueGrey.shade700,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  if ((contract['property_name']?.toString() ?? '')
                          .isNotEmpty ||
                      (contract['unit_number']?.toString() ?? '').isNotEmpty)
                    Text(
                      'العقار/الوحدة: ${contract['property_name'] ?? ''}${(contract['unit_number']?.toString() ?? '').isEmpty ? '' : ' — الوحدة ${'\u2066${contract['unit_number']}\u2069'}'}',
                    ),
                  if ((contract['contract_id']?.toString() ?? '').isNotEmpty)
                    Text(
                      'العقد: ${contract['contract_id']}  (${contract['start_date'] ?? ''} - ${contract['end_date'] ?? ''})',
                    ),
                ],
                const SizedBox(height: 12),
                Text(
                  'الموضوع: ${notice['subject'] ?? ''}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  notice['body']?.toString() ?? '',
                  style: const TextStyle(height: 1.7),
                ),
                const SizedBox(height: 28),
                const Text('وتفضلوا بقبول فائق الاحترام،'),
                const SizedBox(height: 12),
                Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 22),
                const Text('التوقيع: ____________________'),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _eventHistory() {
    final future = _eventsFuture;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Text('جارٍ تحميل سجل الإجراء...'),
          );
        }
        if (snapshot.hasError) {
          final noticeId = _selectedNoticeId;
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(child: Text('تعذر تحميل سجل الإجراء.')),
                  TextButton.icon(
                    onPressed: noticeId == null
                        ? null
                        : () => setState(() {
                            _eventsFuture = context
                                .read<TenantNoticesProvider>()
                                .loadEvents(noticeId);
                          }),
                    icon: const Icon(Icons.refresh),
                    label: const Text('إعادة المحاولة'),
                  ),
                ],
              ),
            ),
          );
        }
        final events = snapshot.data ?? const <Map<String, dynamic>>[];
        if (events.isEmpty) return const SizedBox.shrink();
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'سجل الإجراء',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                for (final event in events)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.history, size: 18),
                    title: Text(
                      _eventLabel(event['event_type']?.toString() ?? ''),
                    ),
                    subtitle: Text(event['created_at']?.toString() ?? ''),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _eventLabel(String value) => switch (value) {
    'draft_created' => 'إنشاء مسودة',
    'draft_updated' => 'تعديل المسودة',
    'issued' => 'إصدار وتثبيت',
    'word_exported' => 'تصدير Word',
    _ => value,
  };

  Map<String, dynamic>? _contractSnapshot(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }
}

class _TenantNoticeEditorDialog extends StatefulWidget {
  const _TenantNoticeEditorDialog({required this.provider, this.initialNotice});

  final TenantNoticesProvider provider;
  final Map<String, dynamic>? initialNotice;

  @override
  State<_TenantNoticeEditorDialog> createState() =>
      _TenantNoticeEditorDialogState();
}

class _TenantNoticeEditorDialogState extends State<_TenantNoticeEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _subjectController;
  late final TextEditingController _bodyController;
  late final TextEditingController _dateController;
  List<Map<String, dynamic>> _recipients = [];
  List<Map<String, dynamic>> _contracts = [];
  int? _tenantId;
  int? _contractId;
  bool _isSaving = false;
  bool _isLoadingRecipients = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialNotice;
    _subjectController = TextEditingController(
      text: initial?['subject']?.toString() ?? '',
    );
    _bodyController = TextEditingController(
      text: initial?['body']?.toString() ?? '',
    );
    _dateController = TextEditingController(
      text:
          initial?['notice_date']?.toString() ??
          DateTime.now().toIso8601String().substring(0, 10),
    );
    _tenantId = initial?['tenant_id'] as int?;
    _contractId = initial?['contract_id'] as int?;
    _loadRecipients();
  }

  Future<void> _loadRecipients() async {
    try {
      final recipients = await widget.provider.loadRecipients();
      if (!mounted) return;
      setState(() {
        _recipients = recipients;
        _isLoadingRecipients = false;
      });
      if (_tenantId != null) await _loadContracts(_tenantId!);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingRecipients = false;
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _loadContracts(int tenantId) async {
    try {
      final contracts = await widget.provider.loadContracts(tenantId);
      if (!mounted || _tenantId != tenantId) return;
      setState(() => _contracts = contracts);
      if (_contractId != null &&
          !contracts.any((item) => item['contract_id'] == _contractId)) {
        setState(() => _contractId = null);
      }
    } catch (error) {
      if (mounted) setState(() => _errorMessage = error.toString());
    }
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _bodyController.dispose();
    _dateController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final current = DateTime.tryParse(_dateController.text) ?? DateTime.now();
    final chosen = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'اختر تاريخ الإشعار',
    );
    if (chosen == null) return;
    _dateController.text = chosen.toIso8601String().substring(0, 10);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final tenantId = _tenantId;
    if (tenantId == null) {
      setState(() => _errorMessage = 'اختر المستأجر أولاً');
      return;
    }
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });
    try {
      final initial = widget.initialNotice;
      final id = initial == null
          ? await widget.provider.createDraft(
              tenantId: tenantId,
              contractId: _contractId,
              subject: _subjectController.text,
              body: _bodyController.text,
              noticeDate: _dateController.text,
            )
          : initial['id'] as int;
      if (initial != null) {
        await widget.provider.updateDraft(
          noticeId: id,
          tenantId: tenantId,
          contractId: _contractId,
          subject: _subjectController.text,
          body: _bodyController.text,
          noticeDate: _dateController.text,
        );
      }
      if (mounted) Navigator.pop(context, id);
    } catch (error) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _errorMessage = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialNotice != null;
    return AlertDialog(
      title: Text(isEditing ? 'تعديل مسودة الإشعار' : 'إنشاء إشعار جديد'),
      content: SizedBox(
        width: 650,
        child: _isLoadingRecipients
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_errorMessage != null) ...[
                        Text(
                          _errorMessage!,
                          style: TextStyle(color: Colors.red.shade700),
                        ),
                        const SizedBox(height: 8),
                      ],
                      DropdownButtonFormField<int>(
                        initialValue: _tenantId,
                        decoration: const InputDecoration(
                          labelText: 'المستأجر *',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final tenant in _recipients)
                            DropdownMenuItem<int>(
                              value: tenant['id'] as int,
                              child: Text(
                                '${tenant['name']} — ${tenant['mobile'] ?? 'بدون رقم'}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          setState(() {
                            _tenantId = value;
                            _contractId = null;
                            _contracts = [];
                          });
                          if (value != null) _loadContracts(value);
                        },
                        validator: (value) =>
                            value == null ? 'اختر المستأجر' : null,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        key: ValueKey<int?>(_tenantId),
                        initialValue: _contractId ?? -1,
                        decoration: const InputDecoration(
                          labelText: 'العقد المرتبط (اختياري)',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<int>(
                            value: -1,
                            child: Text('بدون ربط بعقد'),
                          ),
                          for (final contract in _contracts)
                            DropdownMenuItem<int>(
                              value: contract['contract_id'] as int,
                              child: Text(
                                'عقد ${contract['contract_id']} — ${contract['property_name']} / ${contract['unit_number']} (${contract['contract_status']})',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) => setState(
                          () => _contractId = value == -1 ? null : value,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _dateController,
                        readOnly: true,
                        onTap: _pickDate,
                        decoration: const InputDecoration(
                          labelText: 'تاريخ الإشعار *',
                          suffixIcon: Icon(Icons.calendar_month_outlined),
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            DateTime.tryParse(value ?? '') == null
                            ? 'اختر تاريخًا صحيحًا'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _subjectController,
                        maxLength: 160,
                        decoration: const InputDecoration(
                          labelText: 'موضوع الإشعار *',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => (value?.trim().isEmpty ?? true)
                            ? 'الموضوع مطلوب'
                            : null,
                      ),
                      TextFormField(
                        controller: _bodyController,
                        minLines: 5,
                        maxLines: 10,
                        maxLength: 10000,
                        decoration: const InputDecoration(
                          labelText: 'نص الإشعار *',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => (value?.trim().isEmpty ?? true)
                            ? 'نص الإشعار مطلوب'
                            : null,
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'سيُحفظ المستأجر والعقد كلقطة وقت إنشاء المسودة. لا يؤدي الإشعار إلى تعديل الأقساط أو إرسال SMS.',
                        style: TextStyle(color: Colors.black54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton.icon(
          onPressed: _isSaving || _isLoadingRecipients ? null : _save,
          icon: _isSaving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined),
          label: Text(_isSaving ? 'جارٍ الحفظ' : 'حفظ كمسودة'),
        ),
      ],
    );
  }
}
