# tools/perf/compression_suite/stages/encode.py
"""encode: every format x every input, timed, decode-verified, resumable."""
from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import common
import formats
import verify

HERE = Path(__file__).resolve().parents[1]
RESULTS = HERE / "results"

FORMATS_BY_TIER = {
    "aligned": ["bam", "cram30", "cram31_normal", "cram31_small", "cram31_archive", "mpegg", "ttio"],
    "unaligned": ["fastq_gz", "cram31_small_unaligned", "mpegg_unaligned", "ttio_fastq"],
    "ms": ["mzml_gz", "mzml_numpress_gz", "ttio_mzml"],
}
FULL_TAG_FORMATS = {"bam", "cram30", "cram31_normal", "cram31_small", "cram31_archive", "mpegg"}


def breakdown(fmt_key: str, enc: Path) -> dict:
    if fmt_key.startswith("ttio") and shutil.which("h5ls"):
        p = subprocess.run(["h5ls", "-rv", str(enc)], capture_output=True, text=True)
        out, cur = {}, None
        for line in p.stdout.splitlines():
            if line.startswith("/"):
                cur = line.split()[0]
            elif "Storage:" in line and cur:
                # "Storage: <logical> logical bytes, <alloc> allocated bytes, ..."
                toks = line.replace(",", " ").split()
                try:
                    out[cur] = int(toks[toks.index("allocated") - 1])
                except (ValueError, IndexError):
                    pass
        return out
    return {}


_INPUT_DIGEST: dict = {}


def _digest_cached(fn, path: Path) -> str:
    key = (fn.__name__, str(path))
    if key not in _INPUT_DIGEST:
        _INPUT_DIGEST[key] = fn(path)
    return _INPUT_DIGEST[key]


def _verify(tier: str, kind: str, inp: Path, dec: Path, lossy: bool):
    """Returns (verify, max_rel_error, note). The note is filled on an
    aligned FAIL with the column-level summary so the report can say
    what the format did not carry."""
    if tier in ("aligned",):
        if verify.sam11_md5(dec) == _digest_cached(verify.sam11_md5, inp):
            return "PASS", None, ""
        return "FAIL", None, verify.sam11_diff_summary(inp, dec)
    if tier == "unaligned":
        return ("PASS" if verify.fastq_md5(dec) == _digest_cached(verify.fastq_md5, inp) else "FAIL"), None, ""
    if lossy:
        err = verify.mzml_max_rel_error(inp, dec)
        return ("PASS" if err < 1e-3 else "FAIL"), err, ""
    return ("PASS" if verify.mzml_arrays_md5(dec) == verify.mzml_arrays_md5(inp) else "FAIL"), None, ""


def run(corpora: list[common.Corpus], formats_csv: str, smoke: bool) -> int:
    reg = formats.load_all()
    wanted = None if formats_csv == "all" else set(formats_csv.split(","))
    (common.data_dir() / "out").mkdir(parents=True, exist_ok=True)
    for c in corpora:
        if c.tier == "reference":
            continue
        plan_path = common.data_dir() / "prepared" / c.id / "plan.json"
        if not plan_path.exists():
            print(f"encode: {c.id}: no plan (run prepare)"); continue
        if smoke and not c.source.startswith("file://"):
            continue
        plan = json.loads(plan_path.read_text())
        ref = Path(plan["reference"]) if plan.get("reference") else None
        for item in plan["inputs"]:
            for key in FORMATS_BY_TIER[c.tier]:
                if wanted and key not in wanted:
                    continue
                if item["kind"] == "bam_full" and key not in FULL_TAG_FORMATS:
                    continue
                fmt = reg[key]
                out_json = RESULTS / c.id / f"{key}.{item['kind']}.json"
                inp = Path(item["path"]); sha = common.sha256_of(inp); ver = fmt.version()
                mod_sha = _module_sha(fmt)
                if out_json.exists():
                    prev = json.loads(out_json.read_text())
                    if (prev.get("input_sha256") == sha and prev.get("tool_version") == ver
                            and prev.get("format_module_sha256") == mod_sha
                            and prev.get("reference") == (str(ref) if ref else None)):
                        continue
                work = Path(tempfile.mkdtemp(prefix=f"{c.id}.{key}.", dir=common.data_dir() / "out"))
                rec = {"corpus": c.id, "tier": c.tier, "format": key, "input": item["name"],
                       "kind": item["kind"], "input_bytes": inp.stat().st_size, "input_sha256": sha,
                       "tool_version": ver, "lossy": fmt.lossy, "breakdown": {}, "max_rel_error": None,
                       "verify_note": "", "bases": item.get("bases", 0),
                       "format_module_sha256": mod_sha, "reference": str(ref) if ref else None}
                try:
                    holder = {}
                    t_enc = common.run_timed([sys_executable(), "-c", _ENC_SNIPPET,
                                              key, str(inp), str(work), str(ref or "")])
                    enc = Path((work / "enc.path").read_text().strip())
                    rec.update(output_bytes=enc.stat().st_size, encode_s=t_enc.wall_s,
                               encode_rss_mb=t_enc.peak_rss_mb, breakdown=breakdown(key, enc))
                    dec_dir = work / "dec"; dec_dir.mkdir()
                    t_dec = common.run_timed([sys_executable(), "-c", _DEC_SNIPPET,
                                              key, str(enc), str(dec_dir), str(ref or "")])
                    dec = Path((work / "dec.path").read_text().strip())
                    rec.update(decode_s=t_dec.wall_s, decode_rss_mb=t_dec.peak_rss_mb)
                    rec["verify"], rec["max_rel_error"], rec["verify_note"] = _verify(
                        c.tier, item["kind"], inp, dec, fmt.lossy)
                except Exception as e:  # a broken encoder is a FAIL row, not a crash of the suite
                    rec.update(verify="FAIL", error=str(e)[-3000:])
                    rec.setdefault("output_bytes", 0); rec.setdefault("encode_s", 0.0)
                    rec.setdefault("decode_s", 0.0); rec.setdefault("encode_rss_mb", 0.0)
                    rec.setdefault("decode_rss_mb", 0.0)
                finally:
                    shutil.rmtree(work, ignore_errors=True)
                out_json.parent.mkdir(parents=True, exist_ok=True)
                out_json.write_text(json.dumps(rec, indent=1))
                print(f"encode: {c.id} {item['kind']} {key}: {rec.get('output_bytes')} B {rec['verify']}")
    return 0


def _module_sha(fmt) -> str:
    """sha256 of the format module's source: part of the resume key, so
    a changed encoder re-runs its rows."""
    import inspect
    return common.sha256_of(Path(inspect.getfile(type(fmt))))


def sys_executable() -> str:
    import sys
    return sys.executable


# The encode and decode run in a child process so /usr/bin/time -v measures
# the tool (and any Python importer) rather than the driver.
_ENC_SNIPPET = """
import sys; from pathlib import Path
sys.path.insert(0, %r)
import formats; reg = formats.load_all()
key, inp, work, ref = sys.argv[1:5]
out = reg[key].encode(Path(inp), Path(work), Path(ref) if ref else None)
(Path(work) / "enc.path").write_text(str(out))
""" % str(HERE)

_DEC_SNIPPET = """
import sys; from pathlib import Path
sys.path.insert(0, %r)
import formats; reg = formats.load_all()
key, enc, out, ref = sys.argv[1:5]
dec = reg[key].decode(Path(enc), Path(out), Path(ref) if ref else None)
(Path(out).parent / "dec.path").write_text(str(dec))
""" % str(HERE)
