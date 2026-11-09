1. **Update `company_info` table and model:**
   - Add `terms_conditions` TEXT column in `database_helper.dart` to `company_info` table.
   - Update `lib/models/company_info_model.dart` to include `termsConditions` field.
2. **Update `SystemSettingsScreen`:**
   - Add input fields for `logoPath` (String input for file path) and `termsConditions` (multiline text field) in `_CompanyInfoTabState`.
3. **Update `contracts_screen.dart` and add PDF generation:**
   - Import `pdf` and `printing` packages.
   - Add a Print button (`Icons.print`) to the "إدارة العقود الحالية" list.
   - Implement `_printContract(contract)` function that queries contract details, tenant info, property/unit info, generated installments, and `company_info`.
   - Generate a PDF using `pw.Document()` that displays the company logo (from `logoPath` if exists), terms and conditions, contract details, and installments table.
4. **Execute Pre-commit Instructions:** Run `flutter analyze` and `flutter test`. Skip playwright since it's a desktop app.
5. **Submit changes.**
