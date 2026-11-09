1. **Fix Installment Math & Enable Manual Edit**:
   - In `contracts_screen.dart`, fix `_generateInstallments()` logic and add a "دفعة واحدة" (One-time payment) option to `_paymentMethod`.
   - Update `_generatedInstallments` objects in state to include `TextEditingController` for amount and due date to support manual editing. (Change the type of `_generatedInstallments` to manage these controllers, e.g., a custom class or storing controllers in parallel).
   - Add `+` and `-` buttons in the UI for manually adding/removing installments.
2. **Add Installment Total Validation**:
   - In `_saveContract()`, ensure the sum of `amount` from `_generatedInstallments` strictly equals the `totalRent`. Show a `SnackBar` if it does not match.
3. **Interactive Contract Cards**:
   - Wrap the `ListTile` in the "إدارة العقود الحالية" list with an `InkWell`.
   - On tap, show a `showDialog` with contract details, the print button (`_printContract`), and a table of its installments (fetched dynamically from DB or LeasingProvider).
4. **Execute Pre-commit instructions**: Run `flutter analyze` and `flutter test`.
5. **Submit changes**.
