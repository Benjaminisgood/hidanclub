#!/usr/bin/env python3
"""Install all official AIST++ 3D annotations as lossless Swift-readable arrays.

Python + NumPy are installation/verification tools only. Hidan Club reads f64
files directly. No normalization, frame selection, interpolation or smoothing
is performed. Originals and the official ignore list are retained.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import pickle
import re
import shutil
import subprocess
import tempfile
import zipfile

import numpy as np

DEFAULT_ROOT = Path.home() / "Library/Application Support/HidanClub/Datasets/AISTPlusPlus"
RELEASE_URL = "https://github.com/google/aistplusplus_dataset/releases/download/v1.0/"
LICENSE_URL = "https://creativecommons.org/licenses/by/4.0/"
FPS = 60
# Published SHA-256 and exact sizes from the official GitHub release asset API.
ASSETS = {
    "keypoints3d.zip": (876142511, "8b2a3bfcea233b8d1859a0dc93c7800a8f9e832136ef6828d0b3ddff640ddcfd"),
    "cameras.zip": (27294, "134050b967fe92364450fd341bf02c36e23873b7677c42288dfc428db4547637"),
    "ignore_list.txt": (1217, "be44c54baa91a1aff18306da2f3fc44abd1adfbb32317ac9f9b1362685415339"),
    "splits.zip": (16454, "38e2d47c81d245fdc0d65b3897b83db1693eea377edc13b30270e4928f4073ad"),
}
REFERENCE_URLS = {
    "download.html": "https://google.github.io/aistplusplus_dataset/download.html",
    "factsfigures.html": "https://google.github.io/aistplusplus_dataset/factsfigures.html",
    "data_formats.html": "https://aistdancedb.ongaaccel.jp/data_formats/",
    "official_loader.py": "https://raw.githubusercontent.com/google/aistplusplus_api/main/aist_plusplus/loader.py",
    "official_README.md": "https://raw.githubusercontent.com/google/aistplusplus_api/main/README.md",
    "release.json": "https://api.github.com/repos/google/aistplusplus_dataset/releases/tags/v1.0",
}
# Names are transcribed verbatim from AIST Dance DB data_formats/.
GENRES = {
    "gBR": "Break", "gPO": "Pop", "gLO": "Lock", "gMH": "Middle Hip-hop",
    "gLH": "LA style Hip-hop", "gHO": "House", "gWA": "Waack", "gKR": "Krump",
    "gJS": "Street Jazz", "gJB": "Ballet Jazz",
}
JOINTS = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow",
    "left_wrist", "right_wrist", "left_hip", "right_hip", "left_knee",
    "right_knee", "left_ankle", "right_ankle",
]


class RestrictedNumpyUnpickler(pickle.Unpickler):
    """Only NumPy ndarray reconstruction; never resolve arbitrary globals."""

    def find_class(self, module: str, name: str):
        if module == "numpy" and name in {"ndarray", "dtype"}:
            return getattr(np, name)
        if module in {"numpy.core.multiarray", "numpy._core.multiarray"} and name in {"_reconstruct", "scalar"}:
            return getattr(np._core.multiarray, name)
        # Protocol 5 may use this NumPy constructor. Official current data uses
        # the older _reconstruct path; no importlib/eval/os or custom classes.
        if module in {"numpy.core.numeric", "numpy._core.numeric"} and name == "_frombuffer":
            return np._core.numeric._frombuffer
        raise pickle.UnpicklingError(f"Forbidden pickle global: {module}.{name}")

    def persistent_load(self, pid):
        raise pickle.UnpicklingError("Persistent IDs are not supported")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def atomic_bytes(path: Path, payload: bytes, *, preserve_existing: bool = False):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and preserve_existing:
        if path.read_bytes() != payload:
            raise ValueError(f"Refusing to overwrite a different existing file: {path}")
        return
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def atomic_json(path: Path, value: dict):
    atomic_bytes(path, (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode())


def verify_asset(path: Path, expected_size: int, expected_sha: str):
    if path.stat().st_size != expected_size:
        raise ValueError(f"Incorrect source size: {path}")
    if sha256_file(path) != expected_sha:
        raise ValueError(f"SHA-256 mismatch: {path}; original is retained for investigation")


def download_asset(root: Path, name: str):
    target = root / "source" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    size, digest = ASSETS[name]
    if target.exists():
        verify_asset(target, size, digest)
        print(f"Verified existing {name}", flush=True)
        return
    partial = target.with_name(target.name + ".partial")
    if not partial.exists() or partial.stat().st_size != size:
        subprocess.run([
            "curl", "--location", "--fail", "--show-error", "--progress-bar",
            "--retry", "5", "--retry-delay", "3", "--continue-at", "-",
            "--output", str(partial), RELEASE_URL + name,
        ], check=True)
    verify_asset(partial, size, digest)
    os.replace(partial, target)
    print(f"Downloaded and verified {name} ({size:,} bytes)", flush=True)


def snapshot_references(root: Path):
    for name, url in REFERENCE_URLS.items():
        target = root / "source" / "references" / name
        if target.exists():
            continue
        result = subprocess.run([
            "curl", "--location", "--fail", "--silent", "--show-error",
            "--retry", "3", "--max-time", "60", url,
        ], check=True, stdout=subprocess.PIPE)
        atomic_bytes(target, result.stdout, preserve_existing=True)


def safe_members(archive: zipfile.ZipFile):
    seen = set()
    for info in archive.infolist():
        member = PurePosixPath(info.filename)
        if member.is_absolute() or ".." in member.parts or info.filename in seen:
            raise ValueError(f"Unsafe or duplicate ZIP member: {info.filename}")
        seen.add(info.filename)
        if (info.external_attr >> 16) & 0o170000 == 0o120000:
            raise ValueError(f"Symlink ZIP member is forbidden: {info.filename}")
        yield info


def extract_metadata(root: Path, name: str):
    with zipfile.ZipFile(root / "source" / name) as archive:
        for info in safe_members(archive):
            if not info.is_dir():
                atomic_bytes(root / "metadata" / info.filename, archive.read(info), preserve_existing=True)


def read_sequence(payload: bytes, member_name: str):
    data = RestrictedNumpyUnpickler(io.BytesIO(payload)).load()
    if not isinstance(data, dict) or set(data) != {"keypoints3d", "keypoints3d_optim"}:
        raise ValueError(f"Unexpected pickle dictionary schema: {member_name}")
    for name, values in data.items():
        if type(values) is not np.ndarray or values.dtype.kind != "f" or values.dtype.itemsize != 8:
            raise ValueError(f"Expected original Float64 ndarray: {member_name}/{name}")
        if values.ndim != 3 or values.shape[1:] != (17, 3) or len(values) < 1:
            raise ValueError(f"Unexpected keypoint shape: {member_name}/{name}: {values.shape}")
    if data["keypoints3d"].shape != data["keypoints3d_optim"].shape:
        raise ValueError(f"Raw and optimized frame counts differ: {member_name}")
    return data


def sequence_tags(identifier: str):
    match = re.fullmatch(r"(g[A-Z]{2})_(s[A-Z]{2})_cAll_(d\d+)_(m[A-Z]{2}\d+)_(ch\d+)", identifier)
    if not match or match[1] not in GENRES:
        raise ValueError(f"Unknown sequence naming pattern: {identifier}")
    return match.groups()


def little_endian_bytes(values: np.ndarray) -> bytes:
    # Float64 is preserved. On a big-endian platform byteswap preserves NaN
    # payloads as well; no floating-point arithmetic or dtype narrowing occurs.
    if values.dtype.byteorder == ">" or (values.dtype.byteorder == "=" and not np.little_endian):
        values = values.byteswap().view(values.dtype.newbyteorder("<"))
    return values.tobytes(order="C")


def build_or_verify(root: Path, *, verify_only: bool):
    for name, (size, digest) in ASSETS.items():
        verify_asset(root / "source" / name, size, digest)
    if not verify_only:
        extract_metadata(root, "cameras.zip")
        extract_metadata(root, "splits.zip")
    ignored = set((root / "source" / "ignore_list.txt").read_text().split())
    mapping_file = root / "metadata" / "cameras" / "mapping.txt"
    mapping = dict(line.split() for line in mapping_file.read_text().splitlines() if line.strip())
    sequences = []
    genre_counts, genre_frames = Counter(), Counter()
    raw_nan = optimized_nan = raw_inf = optimized_inf = total_frames = ignored_frames = 0
    source_members = []
    archive_metadata_members = []
    with zipfile.ZipFile(root / "source" / "keypoints3d.zip") as archive:
        # Explicit full CRC pass before any deserialization; hash already pins
        # the archive to the official release. All files stay in the original ZIP.
        bad_member = archive.testzip()
        if bad_member is not None:
            raise ValueError(f"ZIP CRC verification failed: {bad_member}")
        members = list(safe_members(archive))
        for info in sorted(members, key=lambda item: item.filename):
            if info.is_dir():
                continue
            member = PurePosixPath(info.filename)
            if member.parts[0] == "__MACOSX":
                # AppleDouble resource forks are ZIP packaging metadata, not
                # keypoint records. Retained in the source ZIP and inventoried.
                archive_metadata_members.append(info.filename)
                continue
            if len(member.parts) != 2 or member.parts[0] != "keypoints3d" or member.suffix != ".pkl":
                raise ValueError(f"Unexpected 3D annotation ZIP content: {info.filename}")
            identifier = member.stem
            genre, situation, dancer, music, choreography = sequence_tags(identifier)
            payload = archive.read(info)
            data = read_sequence(payload, info.filename)
            frame_count = len(data["keypoints3d"])
            record = {
                "id": identifier, "genreCode": genre, "genreName": GENRES[genre],
                "situationCode": situation, "dancerID": dancer, "musicID": music,
                "choreographyID": choreography, "frameCount": frame_count, "fps": FPS,
                "durationSeconds": frame_count / FPS, "ignored": identifier in ignored,
                "rawPath": f"sequences/{identifier}.raw.f64",
                "optimizedPath": f"sequences/{identifier}.optimized.f64",
                "byteCount": frame_count * 17 * 3 * 8,
                "sourceMember": info.filename, "sourceMemberCRC32": f"{info.CRC:08x}",
                "sourceMemberSHA256": hashlib.sha256(payload).hexdigest(),
                "cameraEnvironment": mapping.get(identifier),
            }
            for key, prefix in [("keypoints3d", "raw"), ("keypoints3d_optim", "optimized")]:
                values = data[key]
                encoded = little_endian_bytes(values)
                destination = root / record[prefix + "Path"]
                if not verify_only:
                    atomic_bytes(destination, encoded, preserve_existing=True)
                stored = destination.read_bytes()
                # This compares every byte of every coordinate in every frame,
                # including NaN/Inf and NaN payload bits, not just a sample.
                if stored != encoded:
                    raise ValueError(f"Lossless round-trip comparison failed: {destination}")
                record[prefix + "SHA256"] = hashlib.sha256(stored).hexdigest()
                record[prefix + "NaNCount"] = int(np.isnan(values).sum())
                record[prefix + "InfCount"] = int(np.isinf(values).sum())
            raw_nan += record["rawNaNCount"]
            optimized_nan += record["optimizedNaNCount"]
            raw_inf += record["rawInfCount"]
            optimized_inf += record["optimizedInfCount"]
            total_frames += frame_count
            ignored_frames += frame_count if record["ignored"] else 0
            genre_counts[genre] += 1
            genre_frames[genre] += frame_count
            source_members.append({"name": info.filename, "bytes": info.file_size, "crc32": f"{info.CRC:08x}"})
            sequences.append(record)
            if len(sequences) % 100 == 0:
                print(f"{'Verified' if verify_only else 'Converted'} {len(sequences):,} sequences / {total_frames:,} full frames", flush=True)
    unmatched_ignored = sorted(ignored - {s["id"] for s in sequences})
    manifest = {
        "schemaVersion": 1, "name": "AIST++ 3D Keypoints", "release": "v1.0",
        "fps": FPS, "jointNamesCOCO": JOINTS, "coordinateType": "float64-little-endian",
        "arrayOrder": "frame,joint,xyz", "jointCount": 17, "coordinateCount": 3,
        "sourceURL": RELEASE_URL + "keypoints3d.zip", "licenseURL": LICENSE_URL,
        "sourceSHA256": ASSETS["keypoints3d.zip"][1],
        "attribution": "AIST++ annotations © Google LLC, CC BY 4.0. Li, Yang, Ross and Kanazawa, ICCV 2021. Source performances: AIST Dance Video Database, Tsuchida et al., ISMIR 2019.",
        "modifications": "Lossless serialization from NumPy float64 arrays to little-endian float64 binary. All source frames and raw/optimized arrays retained; no normalization, interpolation, filtering or additional smoothing.",
        "sequenceCount": len(sequences), "totalFrames": total_frames,
        "ignoredSequenceCount": sum(s["ignored"] for s in sequences), "ignoredFrames": ignored_frames,
        "totalSeconds": total_frames / FPS, "totalBinaryBytes": total_frames * 17 * 3 * 8 * 2,
        "rawNaNCount": raw_nan, "optimizedNaNCount": optimized_nan,
        "rawInfCount": raw_inf, "optimizedInfCount": optimized_inf,
        "sequences": sequences,
    }
    report = {
        "verifiedAt": datetime.now(timezone.utc).isoformat(),
        "status": "PASS", "sourceSHA256MatchesOfficialRelease": True,
        "zipCRCPassed": True, "allCoordinatesByteExact": True,
        "archiveMetadataMembersRetainedInSourceZIP": archive_metadata_members,
        "sequenceCount": len(sequences), "totalFrames": total_frames,
        "ignoredSequenceCount": manifest["ignoredSequenceCount"], "ignoredFrames": ignored_frames,
        "unmatchedIgnoreListIDs": unmatched_ignored,
        "totalBinaryBytes": manifest["totalBinaryBytes"],
        "rawNaNCount": raw_nan, "optimizedNaNCount": optimized_nan,
        "rawInfCount": raw_inf, "optimizedInfCount": optimized_inf,
        "genres": [{"code": code, "name": GENRES[code], "sequences": genre_counts[code], "frames": genre_frames[code]} for code in sorted(genre_counts)],
        "frameCountInterpretation": "totalFrames is the sum of N in unique cAll 3D sequences. Official 10,108,015 counts corresponding multi-view images; it is not a count of unique 3D instants. No images/videos/music are included in keypoints3d.zip.",
        "sourceAssets": [{"name": name, "url": RELEASE_URL + name, "bytes": size, "sha256": digest} for name, (size, digest) in ASSETS.items()],
        "referenceSnapshots": [{"name": name, "url": url, "sha256": sha256_file(root / "source" / "references" / name)} for name, url in REFERENCE_URLS.items()],
    }
    if verify_only:
        installed = json.loads((root / "manifest.json").read_text())
        if manifest != installed:
            raise ValueError("Installed manifest differs from independently recomputed source metadata")
        print(json.dumps({k: v for k, v in report.items() if k not in {"archiveMetadataMembersRetainedInSourceZIP", "sourceAssets", "referenceSnapshots"}}, ensure_ascii=False, indent=2), flush=True)
    else:
        atomic_json(root / "source" / "keypoints3d_members.json", {"members": source_members})
        atomic_json(root / "verification.json", report)
        # Publish manifest last; an interrupted first install is never shown as complete.
        atomic_json(root / "manifest.json", manifest)
        print(json.dumps({k: v for k, v in report.items() if k not in {"archiveMetadataMembersRetainedInSourceZIP", "sourceAssets", "referenceSnapshots"}}, ensure_ascii=False, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--verify-only", action="store_true", help="Compare every installed coordinate and manifest field with the original ZIP; no download or writes")
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    if not args.verify_only:
        root.mkdir(parents=True, exist_ok=True)
        if shutil.disk_usage(root).free < 3 * 1024 ** 3:
            raise RuntimeError("At least 3 GiB free space is required for source + both full-precision layers")
        for name in ASSETS:
            download_asset(root, name)
        snapshot_references(root)
    build_or_verify(root, verify_only=args.verify_only)


if __name__ == "__main__":
    main()
