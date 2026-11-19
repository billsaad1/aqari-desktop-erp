import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/permission_policy.dart';
import '../core/tenant_notice_docx.dart';
import '../core/tenant_notice_pdf.dart';
import '../database/database_helper.dart';

class TenantNoticesProvider with ChangeNotifier {
  List<Map<String, dynamic>> _notices = [];
  bool _isLoading = false;
  String? _errorMessage;
  int _loadGeneration = 0;
  int? _authorizedUserId;
  bool _hadNoticeView = false;

  List<Map<String, dynamic>> get notices => List.unmodifiable(_notices);
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  void syncAuthorization({required int? userId, required bool canViewNotices}) {
    if (_authorizedUserId != userId || (_hadNoticeView && !canViewNotices)) {
      clearSensitiveData(notify: false);
    }
    _authorizedUserId = userId;
    _hadNoticeView = canViewNotices;
  }

  Future<void> loadNotices() async {
    PermissionRuntime.require('notices', AppPermissionAction.view);
    final generation = ++_loadGeneration;
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final notices = await DatabaseHelper.instance.getTenantNotices();
      if (generation == _loadGeneration) _notices = notices;
    } catch (error) {
      if (generation == _loadGeneration) {
        _errorMessage = error.toString();
        rethrow;
      }
    } finally {
      if (generation == _loadGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<List<Map<String, dynamic>>> loadRecipients() =>
      DatabaseHelper.instance.getTenantNoticeRecipients();

  Future<List<Map<String, dynamic>>> loadContracts(int tenantId) =>
      DatabaseHelper.instance.getTenantNoticeContracts(tenantId);

  Future<Map<String, dynamic>?> loadNotice(int noticeId) =>
      DatabaseHelper.instance.getTenantNotice(noticeId);

  Future<List<Map<String, dynamic>>> loadEvents(int noticeId) =>
      DatabaseHelper.instance.getTenantNoticeEvents(noticeId);

  Future<int> createDraft({
    required int tenantId,
    int? contractId,
    required String subject,
    required String body,
    required String noticeDate,
  }) async {
    final id = await DatabaseHelper.instance.createTenantNoticeDraft(
      tenantId: tenantId,
      contractId: contractId,
      subject: subject,
      body: body,
      noticeDate: noticeDate,
    );
    await loadNotices();
    return id;
  }

  Future<void> updateDraft({
    required int noticeId,
    required int tenantId,
    int? contractId,
    required String subject,
    required String body,
    required String noticeDate,
  }) async {
    await DatabaseHelper.instance.updateTenantNoticeDraft(
      noticeId: noticeId,
      tenantId: tenantId,
      contractId: contractId,
      subject: subject,
      body: body,
      noticeDate: noticeDate,
    );
    await loadNotices();
  }

  Future<void> issue(int noticeId) async {
    await DatabaseHelper.instance.issueTenantNotice(noticeId);
    await loadNotices();
  }

  Future<Map<String, dynamic>?> loadCompanyInfo() =>
      DatabaseHelper.instance.getCompanyInfo();

  Future<Uint8List> buildPdf(int noticeId) async {
    PermissionRuntime.require('notices', AppPermissionAction.print);
    final userId = PermissionRuntime.userId;
    final role = PermissionRuntime.role;
    void requireCurrentPrintAuthorization() {
      if (PermissionRuntime.userId != userId ||
          PermissionRuntime.role != role) {
        throw StateError('تغيرت الجلسة قبل إكمال تصدير الإشعار');
      }
      PermissionRuntime.require('notices', AppPermissionAction.print);
    }

    final notice = await DatabaseHelper.instance.getTenantNotice(noticeId);
    requireCurrentPrintAuthorization();
    if (notice == null) throw StateError('الإشعار غير موجود');
    if (notice['status'] != 'Issued') {
      throw StateError('يجب إصدار الإشعار قبل تصديره إلى PDF');
    }

    final companyInfo = await DatabaseHelper.instance.getCompanyInfo();
    requireCurrentPrintAuthorization();
    final bytes = await TenantNoticePdfBuilder.build(
      notice: notice,
      companyInfo: companyInfo,
    );
    requireCurrentPrintAuthorization();
    return bytes;
  }

  Future<Uint8List> buildWord(int noticeId) async {
    PermissionRuntime.require('notices', AppPermissionAction.print);
    final notice = await DatabaseHelper.instance.getTenantNotice(noticeId);
    if (notice == null) throw StateError('الإشعار غير موجود');
    if (notice['status'] != 'Issued') {
      throw StateError('يجب إصدار الإشعار قبل تصديره إلى Word');
    }
    final companyInfo =
        await DatabaseHelper.instance.getCompanyInfo() ??
        <String, dynamic>{'name_ar': 'إدارة العقارات'};
    Uint8List? logoBytes;
    final logoPath = companyInfo['logo_path']?.toString().trim() ?? '';
    if (logoPath.isNotEmpty) {
      final logoFile = File(logoPath);
      try {
        if (await logoFile.exists()) logoBytes = await logoFile.readAsBytes();
      } on FileSystemException {
        logoBytes = null;
      }
    }
    return TenantNoticeDocxBuilder.build(
      notice: notice,
      companyInfo: companyInfo,
      logoBytes: logoBytes,
    );
  }

  Future<void> recordWordExport({
    required int noticeId,
    required String fileName,
  }) => DatabaseHelper.instance.recordTenantNoticeWordExport(
    noticeId: noticeId,
    fileName: fileName,
  );

  void clearSensitiveData({bool notify = true}) {
    _loadGeneration++;
    _notices = [];
    _isLoading = false;
    _errorMessage = null;
    if (notify) notifyListeners();
  }
}
