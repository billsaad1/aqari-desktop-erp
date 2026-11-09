1. **Fix Downloaded Font Assets**: Re-download the actual binary TTF fonts using correct URLs from Google Fonts (e.g. `https://fonts.gstatic.com/s/cairo/v28/SLXVc1nY6HkvalvT.ttf` for regular, etc.) or reliable raw github links, and replace the corrupted HTML files in `assets/fonts/`.
2. **Fix Database Migration**: Add the missing `ALTER TABLE company_info ADD COLUMN logo_path TEXT;` to the version 5 upgrade block in `lib/database/database_helper.dart`. Note that `logo_path` was added in a previous commit's `_createDB`, but existing DBs running older schemas (like version 4) need it added via migration.
3. **Execute Pre-commit instructions**: Run `flutter analyze` and `flutter test`. Ensure fonts are valid binaries.
4. **Submit changes**.
