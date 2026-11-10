import 'package:flutter/material.dart';
import '../database/database_helper.dart';

class PropertyProvider with ChangeNotifier {
  List<Map<String, dynamic>> _owners = [];
  List<Map<String, dynamic>> _properties = [];
  List<Map<String, dynamic>> _cities = [];
  List<Map<String, dynamic>> _propertyTypes = [];
  List<Map<String, dynamic>> _unitTypes = [];
  List<Map<String, dynamic>> _costCenters = [];

  bool _isLoading = false;

  List<Map<String, dynamic>> get owners => _owners;
  List<Map<String, dynamic>> get properties => _properties;
  List<Map<String, dynamic>> get cities => _cities;
  List<Map<String, dynamic>> get propertyTypes => _propertyTypes;
  List<Map<String, dynamic>> get unitTypes => _unitTypes;
  List<Map<String, dynamic>> get costCenters => _costCenters;
  bool get isLoading => _isLoading;

  Future<void> loadInitialData() async {
    _isLoading = true;
    notifyListeners();

    _owners = await DatabaseHelper.instance.getAllOwners();
    _properties = await DatabaseHelper.instance.getProperties();
    _cities = await DatabaseHelper.instance.getLookupData('cities');
    _propertyTypes = await DatabaseHelper.instance.getLookupData(
      'property_types',
    );
    _unitTypes = await DatabaseHelper.instance.getLookupData('unit_types');
    _costCenters = await DatabaseHelper.instance.getLookupData('cost_centers');

    _isLoading = false;
    notifyListeners();
  }

  Future<void> addOwner(Map<String, dynamic> owner) async {
    await DatabaseHelper.instance.insertOwnerWithAccount(owner);
    await loadInitialData();
  }

  Future<void> updateOwner(Map<String, dynamic> owner) async {
    await DatabaseHelper.instance.updateOwner(owner);
    await loadInitialData();
  }

  Future<void> addProperty(Map<String, dynamic> property) async {
    await DatabaseHelper.instance.insertProperty(property);
    await loadInitialData();
  }

  Future<void> updateProperty(Map<String, dynamic> property) async {
    await DatabaseHelper.instance.updateProperty(property);
    await loadInitialData();
  }

  Future<void> updateUnit(Map<String, dynamic> unit) async {
    await DatabaseHelper.instance.updateUnit(unit);
  }
}
