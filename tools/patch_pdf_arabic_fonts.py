#!/usr/bin/env python3
"""Build PDF-specific font copies with the missing isolated yeh cmap alias.

Requires FontTools: python3 -m pip install fonttools
Run from the repository root: python3 tools/patch_pdf_arabic_fonts.py
The application build uses the checked-in TTF outputs and does not need Python.
"""

from pathlib import Path

from fontTools.ttLib import TTFont


ROOT = Path(__file__).resolve().parents[1]
FONT_DIR = ROOT / "assets" / "fonts"
FONTS = (
    ("Regular", "Cairo-Regular.ttf"),
    ("Bold", "Cairo-Bold.ttf"),
)


def set_name(record, value: str) -> None:
    try:
        record.string = value.encode(record.getEncoding())
    except (LookupError, UnicodeEncodeError):
        record.string = value.encode("utf-16-be")


def main() -> None:
    for weight, source_name in FONTS:
        font = TTFont(FONT_DIR / source_name, recalcTimestamp=False)
        cmap = font.getBestCmap()
        yeh_glyph = cmap.get(0x064A)
        if yeh_glyph is None:
            raise RuntimeError(f"Arabic yeh U+064A is missing from {source_name}")

        # pdf's Arabic shaper emits U+FEF1 for an isolated yeh. Alias it to
        # the existing yeh outline so the glyph has its normal advance width.
        for table in font["cmap"].tables:
            if table.isUnicode():
                table.cmap[0xFEF1] = yeh_glyph

        family = "Aqari PDF Arabic"
        postscript_name = f"AqariPDFArabic-{weight}"
        replacements = {
            1: family,
            2: weight,
            3: f"1.000; Aqari PDF Arabic {weight}; compatibility cmap alias",
            4: f"{family} {weight}",
            6: postscript_name,
            16: family,
            17: weight,
        }
        for record in font["name"].names:
            if record.nameID in replacements:
                set_name(record, replacements[record.nameID])

        # Avoid a save-time timestamp changing the binary output on each run.
        font["head"].modified = font["head"].created

        output = FONT_DIR / f"AqariPDFArabic-{weight}.ttf"
        font.save(output)

        check = TTFont(output, lazy=True).getBestCmap()
        if check.get(0xFEF1) != check.get(0x064A):
            raise RuntimeError(f"Failed to verify isolated-yeh alias in {output}")
        print(f"Wrote {output.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
