"""Byte-breakdown of a TTI-O .tio file vs the equivalent CRAM file."""
from __future__ import annotations

import argparse
from collections import defaultdict
from pathlib import Path

import h5py


def _categorise(path: str) -> str:
    p = path.lstrip("/")
    if p.startswith("study/genomic_runs/"):
        rest = p.split("/", 3)[-1] if p.count("/") >= 3 else ""
        if rest.startswith("signal_channels/"):
            ch = rest.split("/", 1)[-1].split("/", 1)[0]
            return f"signal:{ch}"
        if rest.startswith("genomic_index"):
            return "genomic_index"
        if rest.startswith("references/"):
            return "references"
        if rest.startswith("provenance"):
            return "run_provenance"
        if rest.startswith("mate_info"):
            return "mate_info_subgroup"
        if rest.startswith("read_names"):
            return "signal:read_names"
        return f"genomic_other:{rest.split('/', 1)[0] or '_root_'}"
    if p.startswith("study/references/"):
        return "references"
    if p.startswith("study/identifications") or p.startswith("study/quantifications"):
        return "study_compounds"
    if p.startswith("study/provenance"):
        return "study_provenance"
    if p.startswith("protection/"):
        return "protection"
    if "ms_runs/" in p or "nmr_runs/" in p:
        return "spectroscopy"
    return f"other:{p.split('/', 1)[0] or '_root_'}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("tio", type=Path)
    ap.add_argument("--cram", type=Path, default=None)
    args = ap.parse_args()

    tio_size = args.tio.stat().st_size
    print(f"TIO file: {args.tio}")
    print(f"  Total on disk: {tio_size/1e6:.2f} MB ({tio_size:,} bytes)\n")

    by_cat: dict[str, int] = defaultdict(int)
    by_ds: list[tuple[str, str, int, str]] = []
    n_datasets = 0
    n_groups = 0
    n_attrs_total = 0
    attr_bytes_est = 0

    def visit(name: str, obj):
        nonlocal n_datasets, n_groups, n_attrs_total, attr_bytes_est
        if isinstance(obj, h5py.Dataset):
            n_datasets += 1
            try:
                storage = obj.id.get_storage_size()
            except Exception:
                storage = 0
            cat = _categorise(name)
            by_cat[cat] += storage
            dt_str = str(obj.dtype) if obj.dtype.kind != "V" else "compound"
            by_ds.append((cat, name, storage, dt_str))
            for k, v in obj.attrs.items():
                n_attrs_total += 1
                try:
                    if hasattr(v, "nbytes"):
                        attr_bytes_est += int(v.nbytes)
                    else:
                        attr_bytes_est += len(str(v).encode("utf-8"))
                except Exception:
                    pass
        elif isinstance(obj, h5py.Group):
            n_groups += 1
            for k, v in obj.attrs.items():
                n_attrs_total += 1
                try:
                    if hasattr(v, "nbytes"):
                        attr_bytes_est += int(v.nbytes)
                    else:
                        attr_bytes_est += len(str(v).encode("utf-8"))
                except Exception:
                    pass

    with h5py.File(args.tio, "r") as f:
        for k, v in f.attrs.items():
            n_attrs_total += 1
            try:
                if hasattr(v, "nbytes"):
                    attr_bytes_est += int(v.nbytes)
                else:
                    attr_bytes_est += len(str(v).encode("utf-8"))
            except Exception:
                pass
        f.visititems(visit)

    sum_ds = sum(by_cat.values())
    framework = tio_size - sum_ds - attr_bytes_est

    print(f"Structure: {n_groups} groups, {n_datasets} datasets, {n_attrs_total} attributes")
    print(f"  Sum of dataset storage:  {sum_ds/1e6:7.2f} MB ({sum_ds/tio_size*100:5.1f}%)")
    print(f"  Attribute payload (est): {attr_bytes_est/1e6:7.2f} MB ({attr_bytes_est/tio_size*100:5.1f}%)")
    print(f"  HDF5 framework residual: {framework/1e6:7.2f} MB ({framework/tio_size*100:5.1f}%)")
    print()
    print("By category (descending):")
    print(f"  {'Category':<40} {'Bytes':>14} {'% file':>7}")
    for cat, n in sorted(by_cat.items(), key=lambda kv: -kv[1]):
        print(f"  {cat:<40} {n:>14,} {n/tio_size*100:>6.2f}%")
    print()
    print("Top 25 datasets by storage:")
    by_ds.sort(key=lambda t: -t[2])
    for cat, path, n, dt in by_ds[:25]:
        print(f"  {n:>14,} /{path:<70} {dt}")
    print()
    if args.cram and args.cram.exists():
        cram_size = args.cram.stat().st_size
        target_115 = int(cram_size * 1.15)
        print(f"CRAM file: {args.cram}")
        print(f"  Total on disk: {cram_size/1e6:.2f} MB ({cram_size:,} bytes)")
        print(f"  TTIO/CRAM ratio: {tio_size/cram_size:.3f}x")
        print(f"  Target 1.15x CRAM = {target_115/1e6:.2f} MB ({target_115:,} bytes)")
        print(f"  Excess to shave: {(tio_size-target_115)/1e6:.2f} MB "
              f"({(tio_size-target_115)/tio_size*100:.1f}% of current TIO)")


if __name__ == "__main__":
    main()
