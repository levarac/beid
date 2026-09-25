# Bricolage Grotesque Display cuts

The five Display faces are static instances of the official Google Fonts
variable font at
`https://raw.githubusercontent.com/google/fonts/main/ofl/bricolagegrotesque/BricolageGrotesque%5Bopsz%2Cwdth%2Cwght%5D.ttf`.
The downloaded source has `head.fontRevision` 65602 (16.16 raw value) and
SHA-256 `413e7357809ddd12fd80a96a8a396de0e401638d4acd3cb3e37532f0472ac682`.
The bundled `OFL-BricolageGrotesque.txt` remains the license for every cut.

Regenerate with fontTools 4.60.0 (`python3 -m pip install fonttools==4.60.0`)
after saving that source as `/private/tmp/BricolageGrotesque-variable.ttf`:

```python
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

source = Path("/private/tmp/BricolageGrotesque-variable.ttf")
for size in (60, 52, 46, 40, 34):
    font = TTFont(source)
    instantiateVariableFont(
        font, {"wght": 800, "wdth": 100, "opsz": size}, inplace=True
    )
    family = f"Bricolage Grotesque Display {size}"
    postscript = f"BricolageGrotesque-Display{size}ExtraBold"
    names = {
        1: family, 2: "ExtraBold", 3: f"1.001;BEID;{postscript}",
        4: f"{family} ExtraBold", 6: postscript,
        16: family, 17: "ExtraBold",
    }
    for name_id, value in names.items():
        font["name"].setName(value, name_id, 3, 1, 0x409)
    font.save(Path(f"{postscript}.ttf"))
```

Run the snippet from this directory. Name IDs 1 and 16 give each optical
cut a distinct family, and ID 6 gives it a distinct PostScript name for
`Font.custom`. ID 3 is unique too. The original opsz-14 face is unused.
