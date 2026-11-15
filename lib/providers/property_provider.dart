import 'package:flutter/material.dart';
import '../database/database_helper.dart';

class PropertyDataSnapshot {
  const PropertyDataSnapshot({
    required this.owners,
    required this.properties,
    required this.cities,
    required this.propertyTypes,
    required this.unitTypes,
    required this.costCenters,
  });

  final List<Map<String, dynamic>> owners;
  final List<Map<String, dynamic>> properties;
  final List<Map<String, dynamic>> cities;
  final List<Map<String, dynamic>> propertyTypes;
  final List<Map<String, dynamic>> unitTypes;
  final List<Map<String, dynamic>> costCenters;
}

class PropertyProvider with ChangeNotifier {
  PropertyProvider({
    Future<PropertyDataSnapshot> Function()? fullDataLoader,
    Future<List<Map<String, dynamic>>> Function()? leasingDataLoader,
  }) : _fullDataLoader = fullDataLoader,
       _leasingDataLoader = leasingDataLoader;

  final Future<PropertyDataSnapshot> Function()? _fullDataLoader;
  final Future<List<Map<String, dynamic>>> Function()? _leasingDataLoader;

  List<Map<String, dynamic>> _owners = [];
  List<Map<String, dynamic>> _properties = [];
  List<Map<String, dynamic>> _cities = [];
  List<Map<String, dynamic>> _propertyTypes = [];
  List<Map<String, dynamic>> _unitTypes = [];
  List<Map<String, dynamic>> _costCenters = [];

  bool _isLoading = false;
  String? _errorMessage;
  int _loadGeneration = 0;
  int? _authorizedUserId;
  bool _hadFullPropertyAccess = false;
  bool _hadLeasingAccess = false;

  List<Map<String, dynamic>> get owners => _owners;
  List<Map<String, dynamic>> get properties => _properties;
  List<Map<String, dynamic>> get cities => _cities;
  List<Map<String, dynamic>> get propertyTypes => _propertyTypes;
  List<Map<String, dynamic>> get unitTypes => _unitTypes;
  List<Map<String, dynamic>> get costCenters => _costCenters;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  /// Called by the app-level auth proxy. Never retain full property data when
  /// the current session changes or loses properties.view.
  void syncAuthorization({
    required int? userId,
    required bool canViewProperties,
    required bool canViewLeasing,
  }) {
    if (_authorizedUserId != userId ||
        (_hadFullPropertyAccess && !canViewProperties) ||
        (_hadLeasingAccess && !canViewLeasing && !canViewProperties)) {
      clearSensitiveData(notify: false);
    }
    _authorizedUserId = userId;
    _hadFullPropertyAccess = canViewProperties;
    _hadLeasingAccess = canViewLeasing;
  }

  Future<PropertyDataSnapshot> _loadFullDataFromDatabase() async {
    final owners = await DatabaseHelper.instance.getAllOwners();
    final properties = await DatabaseHelper.instance.getProperties();
    final cities = await DatabaseHelper.instance.getLookupData('cities');
    final propertyTypes = await DatabaseHelper.instance.getLookupData(
      'property_types',
    );
    final unitTypes = await DatabaseHelper.instance.getLookupData('unit_types');
    final costCenters = await DatabaseHelper.instance.getLookupData(
      'cost_centers',
    );
    return PropertyDataSnapshot(
      owners: owners,
      properties: properties,
      cities: cities,
      propertyTypes: propertyTypes,
      unitTypes: unitTypes,
      costCenters: costCenters,
    );
  }

  Future<void> loadInitialData() async {
    final generation = ++_loadGeneration;
    _isLoading = true;
    _errorMessage = null;
    _clearData();
    notifyListeners();

    try {
      final snapshot = await (_fullDataLoader ?? _loadFullDataFromDatabase)();
      if (generation != _loadGeneration) return;
      _owners = snapshot.owners;
      _properties = snapshot.properties;
      _cities = snapshot.cities;
      _propertyTypes = snapshot.propertyTypes;
      _unitTypes = snapshot.unitTypes;
      _costCenters = snapshot.costCenters;
    } catch (error) {
      if (generation != _loadGeneration) return;
      _clearData();
      _errorMessage = 'تعذر تحميل بيانات العقارات: $error';
    } finally {
      if (generation == _loadGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadForLeasing() async {
    final generation = ++_loadGeneration;
    _isLoading = true;
    _errorMessage = null;
    _clearData();
    notifyListeners();

    try {
      final properties =
          await (_leasingDataLoader ??
              DatabaseHelper.instance.getPropertiesForLeasing)();
      if (generation != _loadGeneration) return;
      _properties = properties;
    } catch (error) {
      if (generation != _loadGeneration) return;
      _errorMessage = 'تعذر تحميل أسماء العقارات للتأجير: $error';
    } finally {
      if (generation == _loadGeneration) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  void clearSensitiveData({bool notify = true}) {
    _loadGeneration++;
    _clearData();
    _isLoading = false;
    _errorMessage = null;
    if (notify) notifyListeners();
  }

  void _clearData() {
    _owners = [];
    _properties = [];
    _cities = [];
    _propertyTypes = [];
    _unitTypes = [];
    _costCenters = [];
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
