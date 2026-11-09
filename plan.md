1. **Update `DatabaseHelper.insertLookupData`**: Add logic for automatically generating `cost_centers` codes. Query the `cost_centers` table for the highest `code` value, extract the numeric part, increment it, and generate the new `CCxxx` code. If there are no rows, start with `CC001`.
2. **Update `lookups_screen.dart`**: Modify the `LookupConfig` and the `_showAddEditDialog` to handle 'cost_centers' gracefully by either excluding `code` from the input fields or making it read-only.
3. **Execute Pre-commit instructions**: Verify changes with `flutter analyze`, `flutter test`, and run the app manually. Call `frontend_verification_instructions` if UI changed.
4. **Submit changes**.
