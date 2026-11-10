import 'package:flutter/material.dart';
import '../database/database_helper.dart';

class AccountingProvider with ChangeNotifier {
  List<Map<String, dynamic>> _accounts = [];
  List<Map<String, dynamic>> _costCenters = [];
  bool _isLoading = false;
  String? _errorMessage;

  List<Map<String, dynamic>> get accounts => _accounts;
  List<Map<String, dynamic>> get costCenters => _costCenters;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  Future<void> loadAccounts() async {
    _isLoading = true;
    notifyListeners();

    try {
      _accounts = await DatabaseHelper.instance.getAllAccounts();
      _errorMessage = null;
    } catch (e) {
      _errorMessage = 'تعذر تحميل الحسابات: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
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
