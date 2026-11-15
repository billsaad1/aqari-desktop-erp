import 'package:flutter/material.dart';
import '../database/database_helper.dart';

class AccountingProvider with ChangeNotifier {
  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _costCenters = [];
  bool _isLoading = false;
  String? _errorMessage;
  int _loadGeneration = 0;

  List<Map<String, dynamic>> get accounts => _accounts;
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

  Future<void> addAccount(Map<String, dynamic> account) async {
    await DatabaseHelper.instance.insertAccount(account);
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
}
