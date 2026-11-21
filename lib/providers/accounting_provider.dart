import 'package:flutter/material.dart';
import '../database/database_helper.dart';

class AccountingProvider with ChangeNotifier {
  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _costCenters = [];
  bool _isLoading = false;
  String? _errorMessage;
  int _loadGeneration = 0;

  List<Map<String, dynamic>> get accounts => _accounts;
  List<Map<String, dynamic>> get detailAccounts {
    final parentIds = _accounts
        .map((account) => account['parent_id'])
        .whereType<int>()
        .toSet();
    return _accounts
        .where(
          (account) =>
              account['parent_id'] != null &&
              !parentIds.contains(account['id']),
        )
        .toList();
  }

  List<Map<String, dynamic>> get costCenters => _costCenters;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> loadAccounts() async {
    final generation = ++_loadGeneration;
    _accounts = [];
    _isLoading = true;
    notifyListeners();

    try {
      final accounts = await DatabaseHelper.instance.getAllAccounts();
      if (generation == _loadGeneration) {
        _accounts = accounts;
        _errorMessage = null;
      }
    } catch (e) {
      if (generation == _loadGeneration) {
        _accounts = [];
        _errorMessage = 'تعذر تحميل الحسابات: $e';
      }
    } finally {
      if (generation == _loadGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  void clearSensitiveData({bool notify = true}) {
    _loadGeneration++;
    _accounts = [];
    _isLoading = false;
    if (notify) notifyListeners();
  }

  Future<void> loadCostCenters() async {
    _costCenters = await DatabaseHelper.instance.getLookupData('cost_centers');
    notifyListeners();
  }

  Future<int> addAccount(Map<String, dynamic> account) async {
    final id = await DatabaseHelper.instance.insertAccount(account);
    await loadAccounts();
    return id;
  }

  Future<void> updateAccount(int accountId, String name) async {
    await DatabaseHelper.instance.updateAccount(accountId, name);
    await loadAccounts();
  }

  Future<void> deleteAccount(int accountId) async {
    await DatabaseHelper.instance.deleteAccount(accountId);
    await loadAccounts();
  }

  Future<int> saveJournalEntry(
    Map<String, dynamic> header,
    List<Map<String, dynamic>> lines,
  ) async {
    final journalId = await DatabaseHelper.instance.insertJournalEntryWithLines(
      header,
      lines,
    );
    await loadAccounts(); // Refresh balances
    return journalId;
  }

  Future<int> saveGeneralVoucher(
    Map<String, dynamic> voucher,
    int cashAccountId,
    int oppositeAccountId,
    int? costCenterId,
    String voucherType,
  ) async {
    final voucherId = await DatabaseHelper.instance.insertGeneralVoucher(
      voucher,
      cashAccountId,
      oppositeAccountId,
      costCenterId,
      voucherType,
    );
    await loadAccounts(); // Refresh balances
    return voucherId;
  }

  Future<int> saveGeneralVoucherWithLines(
    Map<String, dynamic> voucher,
    int cashAccountId,
    List<Map<String, dynamic>> counterpartLines,
    String voucherType,
  ) async {
    final voucherId = await DatabaseHelper.instance
        .insertGeneralVoucherWithLines(
          voucher,
          cashAccountId,
          counterpartLines,
          voucherType,
        );
    await loadAccounts();
    return voucherId;
  }
}
