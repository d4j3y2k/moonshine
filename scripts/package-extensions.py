import json
import pathlib
import shutil

root = pathlib.Path(__file__).resolve().parent.parent
for browser in ["Chrome", "Safari"]:
    target = root / "build" / (browser + "Extension")
    target.mkdir(parents=True, exist_ok=True)
    for name in ["background.js", "context.js", "popup.js", "popup.html"]:
        shutil.copy2(root / "BrowserExtension" / name, target / name)
    manifest = json.loads((root / "BrowserExtension/manifest.json").read_text())
    if browser == "Safari":
        manifest["background"] = {"scripts": ["context.js", "background.js"], "persistent": False}
        manifest.pop("incognito", None)  # Safari private access is still rejected in code.
    (target / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
