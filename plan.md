1. **Fix SystemSettingsScreen UI**: The `MaintenanceTab` was implemented but not exposed in the UI. Update `SystemSettingsScreen` in `lib/features/system_settings/system_settings_screen.dart` to include the 3rd tab (increase TabController length to 3, add the tab label, and add `MaintenanceTab()` to `TabBarView`).
2. **Execute Pre-commit instructions**: Run `flutter analyze` and `flutter test`.
3. **Submit changes**.
