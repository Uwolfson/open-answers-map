# Собирает map/out/map.html: template.html + map/out/data.json (map/02_export.R)
from pathlib import Path
here = Path(__file__).parent
page = (here / "template.html").read_text(encoding="utf8")
page = page.replace("/*DATA3*/null", (here / "out" / "data.json").read_text(encoding="utf8"))
(here / "out" / "map.html").write_text(page, encoding="utf8")
print("ok", here / "out" / "map.html")
