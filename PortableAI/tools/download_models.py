#!/usr/bin/env python3
"""Resume and verify Floatlight models on the USB drive."""

from __future__ import annotations

import hashlib
import os
import pathlib
import sys
import time
import urllib.request


MODELS = [
    {
        "name": "Gemma 3 4B Q4_K_M",
        "file": "gemma-3-4b-it-q4_0.gguf",
        "size": 2_489_757_856,
        "sha256": "882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863",
        "path": "ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf",
        "group": "chat",
        "alternates": [
            (3_155_051_328, "76aed0a8285b83102f18b5d60e53c70d09eb4e9917a20ce8956bd546452b56e2"),
        ],
    },
    {
        "name": "Gemma 3 视觉投影 F16",
        "file": "gemma-3-4b-it-mmproj-f16.gguf",
        "size": 851_251_104,
        "sha256": "8c0fb064b019a6972856aaae2c7e4792858af3ca4561be2dbf649123ba6c40cb",
        "path": "ggml-org/gemma-3-4b-it-GGUF/resolve/main/mmproj-model-f16.gguf",
        "group": "chat",
    },
    {
        "name": "SD-Turbo Q4_0",
        "file": "sd-turbo-q4_0.gguf",
        "size": 1_847_909_248,
        "sha256": "d069ef2b2d3d5c2465662d706c242a1016db56163c109bd7e3008a94cdd00359",
        "path": "samoudi/sd-turbo-gguf/resolve/main/sd_turbo_q4_0.gguf",
        "group": "image",
    },
    {
        "name": "SDXL-Turbo Q4_0（高显存精细模式）",
        "file": "stable-diffusion-xl-1.0-turbo-Q4_0.gguf",
        "size": 3_940_010_720,
        "sha256": "5282eec23430ca46de87de984521fbf04e3cf78fa4152b05610089bc71d8a535",
        "path": "gpustack/stable-diffusion-xl-1.0-turbo-GGUF/resolve/main/stable-diffusion-xl-1.0-turbo-Q4_0.gguf",
        "group": "quality",
    },
]


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(model: dict[str, object], url: str, part: pathlib.Path) -> None:
    offset = part.stat().st_size if part.exists() else 0
    headers = {"User-Agent": "Floatlight-OfflineAI/1.0"}
    if offset:
        headers["Range"] = f"bytes={offset}-"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=45) as response:
        append = offset > 0 and response.status == 206
        if offset and not append:
            offset = 0
        mode = "ab" if append else "wb"
        started = time.monotonic()
        last = started
        received = offset
        with part.open(mode) as output:
            while True:
                chunk = response.read(8 * 1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
                received += len(chunk)
                now = time.monotonic()
                if now - last >= 2:
                    percent = received * 100 / int(model["size"])
                    speed = (received - offset) / max(1, now - started) / 1024 / 1024
                    print(f"\r{percent:6.2f}%  {speed:5.1f} MB/s", end="", flush=True)
                    last = now
        print()


def install(model: dict[str, object], models: pathlib.Path) -> None:
    target = models / str(model["file"])
    part = target.with_suffix(target.suffix + ".part")
    if target.exists():
        candidates = [(int(model["size"]), str(model["sha256"]))] + list(model.get("alternates", []))
        size = target.stat().st_size
        for expected_size, expected_hash in candidates:
            if size == expected_size and sha256(target) == expected_hash:
                print(f"{model['name']} 已存在并校验通过。")
                return
    error: Exception | None = None
    urls = [f"https://hf-mirror.com/{model['path']}", f"https://huggingface.co/{model['path']}"]
    for url in urls:
        try:
            print(f"正在下载 {model['name']}：{url.split('/')[2]}")
            download(model, url, part)
            error = None
            break
        except Exception as exc:  # try the official endpoint after the mirror
            error = exc
            print(f"下载源暂不可用：{exc}")
    if error:
        raise error
    if part.stat().st_size != model["size"]:
        raise RuntimeError(f"文件大小不正确：{part.stat().st_size}")
    print("正在校验 SHA-256…")
    actual = sha256(part)
    if actual != model["sha256"]:
        raise RuntimeError(f"SHA-256 不匹配：{actual}")
    os.replace(part, target)
    print(f"完成：{target}")


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    models = root / "models"
    models.mkdir(parents=True, exist_ok=True)
    image_only = "--image-only" in sys.argv
    quality_only = "--quality-only" in sys.argv
    quality = "--quality" in sys.argv
    selected = [model for model in MODELS if (model["group"] == "quality" if quality_only else model["group"] == "image" if image_only else model["group"] in {"chat", "image"})]
    if quality and not quality_only:
        selected += [model for model in MODELS if model["group"] == "quality"]
    for model in selected:
        install(model, models)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n已暂停，下次运行会继续下载。")
        raise SystemExit(130)
    except Exception as exc:
        print(f"失败：{exc}", file=sys.stderr)
        raise SystemExit(1)
