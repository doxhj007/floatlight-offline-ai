#!/usr/bin/env python3
"""Build a split, stream-extractable Floatlight offline package."""

import argparse
import hashlib
import json
import pathlib
import shutil


MODEL_NAMES = (
    "gemma-3-4b-it-mmproj-f16.gguf",
    "gemma-3-4b-it-q4_0.gguf",
    "sd-turbo-q4_0.gguf",
    "stable-diffusion-xl-1.0-turbo-Q4_0.gguf",
)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=pathlib.Path, required=True)
    parser.add_argument("--models", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--version", default="v1.0.1")
    parser.add_argument("--part-size", type=int, default=1_900_000_000)
    return parser.parse_args()


def iter_files(repo, models):
    mapped = {}
    for path in repo.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(repo)
        if ".git" in relative.parts:
            continue
        if relative.parts[:1] == ("release-tools",):
            continue
        if relative.as_posix() == "PortableAI/models/.gitkeep":
            continue
        mapped[relative.as_posix()] = path
    for name in MODEL_NAMES:
        source = models / name
        if not source.is_file():
            raise FileNotFoundError(source)
        mapped[f"PortableAI/models/{name}"] = source
    for relative in sorted(mapped, key=str.casefold):
        yield relative, mapped[relative]


def main():
    args = parse_args()
    repo = args.repo.resolve()
    models = args.models.resolve()
    output = args.output.resolve()
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    prefix = f"Floatlight-Full-{args.version}"
    part_number = 0
    part_stream = None
    part_hash = None
    part_written = 0
    parts = []
    files = []
    total_written = 0

    def open_part():
        nonlocal part_number, part_stream, part_hash, part_written
        part_number += 1
        name = f"{prefix}.part{part_number:02d}.bin"
        part_stream = (output / name).open("wb")
        part_hash = hashlib.sha256()
        part_written = 0
        print(f"PART_OPEN {name}", flush=True)

    def close_part():
        nonlocal part_stream, part_hash, part_written
        if part_stream is None:
            return
        name = pathlib.Path(part_stream.name).name
        part_stream.close()
        parts.append({"name": name, "size": part_written, "sha256": part_hash.hexdigest()})
        print(f"PART_DONE {name} {part_written / 1_000_000_000:.3f} GB", flush=True)
        part_stream = None
        part_hash = None
        part_written = 0

    open_part()
    for relative, source in iter_files(repo, models):
        size = source.stat().st_size
        file_hash = hashlib.sha256()
        copied = 0
        with source.open("rb") as input_stream:
            while True:
                block = input_stream.read(8 * 1024 * 1024)
                if not block:
                    break
                file_hash.update(block)
                offset = 0
                while offset < len(block):
                    room = args.part_size - part_written
                    take = min(room, len(block) - offset)
                    piece = block[offset : offset + take]
                    part_stream.write(piece)
                    part_hash.update(piece)
                    part_written += take
                    copied += take
                    total_written += take
                    offset += take
                    if part_written == args.part_size:
                        close_part()
                        open_part()
        if copied != size:
            raise RuntimeError(f"Size changed while reading {source}")
        files.append(
            {"path": relative, "size": size, "sha256": file_hash.hexdigest()}
        )
        print(f"FILE {relative} {size / 1_000_000_000:.3f} GB", flush=True)

    if part_written:
        close_part()
    elif part_stream is not None:
        part_stream.close()
        pathlib.Path(part_stream.name).unlink()

    manifest = {
        "format": 1,
        "package": "浮光完整离线 AI",
        "version": args.version,
        "totalSize": total_written,
        "files": files,
        "parts": parts,
    }
    (output / "Floatlight-Full-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    for name in ("安装浮光完整离线包.cmd", "Install-FloatlightFull.ps1"):
        shutil.copy2(repo / "release-tools" / name, output / name)
    print(
        f"PACKAGE_COMPLETE parts={len(parts)} files={len(files)} "
        f"bytes={total_written}",
        flush=True,
    )


if __name__ == "__main__":
    main()
