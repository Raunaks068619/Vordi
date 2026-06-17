#!/usr/bin/env python3
"""Generate README media from docs/vordi-notch.html.

The source HTML is the visual contract. This script injects a capture-only
hook, drives Chrome headless through the exposed demo states, and writes GIFs
plus stills for the README.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
SOURCE_HTML = ROOT / "docs" / "vordi-notch.html"
OUT_DIR = ROOT / "docs" / "readme"
CHROME = os.environ.get(
    "CHROME_PATH", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
)


CAPTURE_HOOK = """
<style>
body[data-readme-capture="true"] .control-rail,
body[data-readme-capture="true"] .hover-zone {
  display: none !important;
}
body[data-readme-capture="true"] .stage::before {
  opacity: .12;
}
body[data-readme-capture="true"] .dynamic-island {
  top: 6px;
}
body[data-readme-capture="true"] *,
body[data-readme-capture="true"] *::before,
body[data-readme-capture="true"] *::after {
  animation: none !important;
  transition-duration: .001ms !important;
  transition-delay: 0s !important;
}
</style>
<script>
(() => {
  const params = new URLSearchParams(location.search);
  if (!params.has("readmeCapture")) return;

  document.body.dataset.readmeCapture = "true";

  const mode = params.get("mode");
  if (mode === "panel") {
    openPanel(Number(params.get("page") || 0));
    return;
  }
  if (mode === "state") {
    setState(params.get("state") || "idle");
  }
})();
</script>
"""


def require_chrome() -> None:
    if not Path(CHROME).exists():
        raise SystemExit(
            "Chrome was not found. Set CHROME_PATH to a Chrome/Chromium binary."
        )


def build_capture_html(tmp_dir: Path) -> Path:
    html = SOURCE_HTML.read_text()
    html = html.replace("</body>", f"{CAPTURE_HOOK}\n</body>")
    capture_html = tmp_dir / "vordi-notch-capture.html"
    capture_html.write_text(html)
    return capture_html


def screenshot(
    capture_html: Path,
    out_path: Path,
    query: str,
    size: tuple[int, int],
    crop_box: tuple[int, int, int, int],
) -> None:
    raw_path = out_path.with_suffix(".raw.png")
    subprocess.run(
        [
            CHROME,
            "--headless=new",
            "--disable-gpu",
            "--disable-extensions",
            "--hide-scrollbars",
            "--no-first-run",
            "--no-default-browser-check",
            "--force-device-scale-factor=1",
            f"--window-size={size[0]},{size[1]}",
            f"--screenshot={raw_path}",
            f"{capture_html.as_uri()}?readmeCapture=1&{query}",
        ],
        check=True,
        timeout=30,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    with Image.open(raw_path) as image:
        image.crop(crop_box).save(out_path)
    raw_path.unlink(missing_ok=True)


def make_gif(frames: list[Path], output: Path, durations: list[int]) -> None:
    images = [Image.open(frame).convert("RGB") for frame in frames]
    paletted = [
        image.quantize(colors=128, method=Image.Quantize.MEDIANCUT)
        for image in images
    ]
    paletted[0].save(
        output,
        save_all=True,
        append_images=paletted[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=2,
    )


def main() -> None:
    require_chrome()
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="vordi-readme-media-") as tmp:
        tmp_dir = Path(tmp)
        capture_html = build_capture_html(tmp_dir)

        state_frames = []
        for state in ["listening", "thinking", "done", "idle"]:
            frame = tmp_dir / f"fn-{state}.png"
            screenshot(
                capture_html,
                frame,
                f"mode=state&state={state}",
                size=(1200, 260),
                crop_box=(140, 0, 1060, 260),
            )
            state_frames.append(frame)

        make_gif(
            state_frames,
            OUT_DIR / "vordi-fn-flow.gif",
            durations=[1050, 850, 900, 650],
        )

        panel_frames = []
        panel_names = ["transcriptions", "notes", "memory", "stats"]
        for index, name in enumerate(panel_names):
            frame = tmp_dir / f"panel-{name}.png"
            screenshot(
                capture_html,
                frame,
                f"mode=panel&page={index}",
                size=(1200, 430),
                crop_box=(150, 0, 1050, 430),
            )
            panel_frames.append(frame)
            if name in {"memory", "stats"}:
                shutil.copyfile(frame, OUT_DIR / f"vordi-panel-{name}.png")

        make_gif(
            panel_frames,
            OUT_DIR / "vordi-panel-carousel.gif",
            durations=[1250, 1150, 1150, 1150],
        )

    print("Generated README notch media in docs/readme")


if __name__ == "__main__":
    main()
