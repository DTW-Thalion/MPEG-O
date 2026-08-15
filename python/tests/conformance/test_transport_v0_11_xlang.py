"""v0.11 transport-spec cross-language conformance matrix.

For every first-class v0.11 accessor (REFERENCES, MS_RUNS, GENOMIC_RUNS,
IMAGE, IDENTIFICATIONS, QUANTIFICATIONS, DATASET_PROVENANCE,
ENCRYPTION_ALGORITHM, plus the Stage 5 / Task 5.6 entries
MS_IMAGE_PROCESSED, RAMAN_IMAGE, IR_IMAGE, plus the Stage 6 /
Task 6.6 entries SUBJECTS, SAMPLES) and every directional pair of
language implementations (Python, Java, ObjC), this test:

1. Builds an isolation fixture ``.tio`` in Python via the same
   :mod:`_v0_11_fixtures` builders used by
   :mod:`tests.test_accessor_matrix_conformance` (so the per-language
   round-trips and the cross-language round-trips share the same
   source content).
2. Encodes the ``.tio`` to ``.tis`` via the writer language's CLI:

   * Python ``ttio.tools.transport_encode_cli``
   * Java ``global.thalion.ttio.tools.TransportEncodeCli``
   * ObjC ``TtioTransportEncode``

3. Decodes the ``.tis`` back to a fresh ``.tio`` via the reader
   language's CLI:

   * Python ``ttio.tools.transport_decode_cli``
   * Java ``global.thalion.ttio.tools.TransportDecodeCli``
   * ObjC ``TtioTransportDecode``

4. Re-opens both sides and asserts content equivalence through the
   accessor-specific comparator from
   :mod:`tests._v0_11_accessor_spec` (logical equivalence — Arrow IPC
   payloads and HDF5 chunk layouts are *not* byte-equivalent across
   SDKs, but the decoded accessor content must match).

Tests are skipped (rather than failed) when the Java or ObjC CLI is
unavailable in the test environment, so Python-side CI keeps running
without those binaries.

Cross-language considerations (from Stages 1–3):

* **Arrow IPC payloads (0x16, 0x17) are NOT byte-equivalent across
  Java/Python/ObjC.** Different flatbuffer envelope encodings.
  The comparator asserts logical equivalence (each decoder lifts the
  same row contents), not byte equality.
* **Hand-written LE byte layouts (0x10–0x15, 0x18, 0x1B) ARE
  byte-equivalent** across all three implementations on the same
  logical input, after the
  ``ProvenanceRecord.parametersJson`` sort-keys fix (commit
  ``9022622f``). We exercise that via the comparator on
  DATASET_PROVENANCE.
* **Reference chromosome ordering:** Java preserves FASTA order;
  Python sorts alphabetically. The comparator on REFERENCES is
  order-agnostic (compares by name set then by per-name sequence).

Stage 4 / Task 4.2 — Python parity for plan §4.2's
``accessor_matrix_xlang.sh``.

Stage 5 / Task 5.6 (Deferral 1) — extends the matrix from 8 → 11
accessors. MS_IMAGE_PROCESSED is routed through each CLI's
``--image-processed`` flag so the encode side exercises
``write_image_processed`` (sparse wire mode) on every SDK; the
decode side is unchanged because each reader auto-dispatches on the
``is_continuous`` byte in the IMAGE_HEADER.

Stage 6 / Task 6.6 (Deferral 2) — extends the matrix from 11 → 13
accessors. SUBJECTS + SAMPLES both flow through the default
``write_dataset`` encode path on every CLI; the §5.4.3 prelude
emits SUBJECT_METADATA (0x19) before SAMPLE_METADATA (0x1A) when
present. Comparators are field-by-field on every Subject / Sample
attribute including the ``attributes`` dict; the cross-language
``attributes_json`` byte parity (sort-keys order) is already
exercised by the multi-key fixture rows.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

# tests/ has no __init__.py — pytest's rootdir auto-adds the package
# root to sys.path. We need the *tests/* directory so the per-accessor
# fixture builders and comparators import cleanly. Mirrors the path
# trick used in tests/test_accessor_matrix_conformance.py.
REPO_ROOT = Path(__file__).resolve().parents[3]
_PY_TESTS = REPO_ROOT / "python" / "tests"
if str(_PY_TESTS) not in sys.path:
    sys.path.insert(0, str(_PY_TESTS))

from _v0_11_accessor_spec import ACCESSOR_SPECS  # noqa: E402

# ── runner config ────────────────────────────────────────────────────

OBJC_CLI_ENCODE = REPO_ROOT / "objc" / "Tools" / "obj" / "TtioTransportEncode"
OBJC_CLI_DECODE = REPO_ROOT / "objc" / "Tools" / "obj" / "TtioTransportDecode"

JAVA_ENCODE_CLASS = "global.thalion.ttio.tools.TransportEncodeCli"
JAVA_DECODE_CLASS = "global.thalion.ttio.tools.TransportDecodeCli"

# Java 25 preview-API + FFM flags. The library uses FFM for HDF5 1.14
# VL_BYTES handling; classes compiled with --enable-preview cannot be
# loaded without the same flag at runtime.
# ``-Djava.library.path=/usr/local/lib`` forces loading the source-
# built HDF5 1.14 ``libhdf5_java.so``; without it Java's default search
# path picks up the apt-installed ``libhdf5-jni`` 1.10 first and the
# version mismatch triggers UnsatisfiedLinkError. Same flag set used by
# ``tests/integration/test_per_au_cross_language.py``.
#
# ``--add-opens=java.base/java.nio=ALL-UNNAMED`` is needed by
# ``arrow-memory-core``'s reflective ``Buffer.address`` lookup on
# JDK 17+. The pom.xml's surefire argLine includes this for in-VM
# unit tests; CLI subprocesses do not inherit it, so we set it
# explicitly here for the IDENTIFICATIONS_TABLE (0x16) and
# QUANTIFICATIONS_TABLE (0x17) packet paths.
_NATIVE_LIB_DIR = str(REPO_ROOT / "native" / "_build")
_JAVA_FLAGS = [
    "--enable-preview",
    "--enable-native-access=ALL-UNNAMED",
    "--add-opens=java.base/java.nio=ALL-UNNAMED",
    # Both directories: ``/usr/local/lib`` for the HDF5 1.14 source-
    # built ``libhdf5_java.so`` AND the in-tree ``native/_build`` so
    # GENOMIC_RUNS can find ``libttio_rans_jni.so`` without a system-
    # wide install (``cp native/_build/libttio_rans_jni.so
    # /usr/local/lib`` would work too but is sysadmin-only).
    f"-Djava.library.path=/usr/local/lib:{_NATIVE_LIB_DIR}",
]


def _java_executable() -> str | None:
    """Prefer the locally-built JDK 25 at ``~/jdk25`` so the preview-
    API + FFM flags above resolve. Fall back to ``which java``."""
    home = os.environ.get("HOME", "")
    candidate = Path(home) / "jdk25" / "bin" / "java"
    if candidate.exists() and os.access(candidate, os.X_OK):
        return str(candidate)
    return shutil.which("java")


def _java_classpath() -> str | None:
    """Build a classpath string usable by the Java CLIs, or return
    None when the Java side hasn't been built. Mirrors the layout
    discovery used by
    ``tests/integration/test_per_au_cross_language.py`` so the two
    suites stay in lock-step on the Maven side."""
    java_root = REPO_ROOT / "java"
    classes = java_root / "target" / "classes"
    cp_file = java_root / "target" / "classpath.txt"
    if not classes.exists():
        return None
    if not cp_file.exists():
        try:
            subprocess.run(
                ["mvn", "-q", "-DincludeScope=runtime",
                 "dependency:build-classpath",
                 f"-Dmdep.outputFile={cp_file}"],
                cwd=java_root, check=True, capture_output=True, timeout=180,
            )
        except Exception:
            return None
    extra = cp_file.read_text().strip() if cp_file.exists() else ""
    # jarhdf5 is ``<scope>system</scope>`` in pom.xml; build-classpath
    # omits it. Splice it in manually — see ``feedback`` memory entry
    # ``feedback_mvn_system_scope_classpath.md``.
    hdf5_jar = "/usr/local/lib/jarhdf5.jar"
    parts = [str(classes)]
    if extra:
        parts.append(extra)
    if Path(hdf5_jar).exists():
        parts.append(hdf5_jar)
    return ":".join(parts)


def _objc_available() -> bool:
    return (OBJC_CLI_ENCODE.exists() and os.access(OBJC_CLI_ENCODE, os.X_OK)
            and OBJC_CLI_DECODE.exists()
            and os.access(OBJC_CLI_DECODE, os.X_OK))


def _java_available() -> bool:
    return _java_executable() is not None and _java_classpath() is not None


# ── per-language CLI invocations ─────────────────────────────────────

def _py_encode(src: Path, dst: Path, extra_flags: list[str] | None = None) -> None:
    args = [sys.executable, "-m", "ttio.tools.transport_encode_cli"]
    if extra_flags:
        args.extend(extra_flags)
    args.extend([str(src), str(dst)])
    subprocess.run(args, check=True, capture_output=True)


def _py_decode(src: Path, dst: Path) -> None:
    subprocess.run(
        [sys.executable, "-m", "ttio.tools.transport_decode_cli",
         str(src), str(dst)],
        check=True, capture_output=True,
    )


def _objc_env() -> dict[str, str]:
    """Ensure the dynamic linker finds libTTIO built alongside the
    transport tools. Without this LD_LIBRARY_PATH augmentation the
    binary fails at load time on a clean shell, even though the tools
    themselves built fine."""
    env = os.environ.copy()
    lib_dir = str(REPO_ROOT / "objc" / "Source" / "obj")
    prior = env.get("LD_LIBRARY_PATH", "")
    env["LD_LIBRARY_PATH"] = f"{lib_dir}:{prior}" if prior else lib_dir
    return env


def _objc_encode(src: Path, dst: Path, extra_flags: list[str] | None = None) -> None:
    args = [str(OBJC_CLI_ENCODE)]
    if extra_flags:
        args.extend(extra_flags)
    args.extend([str(src), str(dst)])
    subprocess.run(args, check=True, capture_output=True, env=_objc_env())


def _objc_decode(src: Path, dst: Path) -> None:
    subprocess.run(
        [str(OBJC_CLI_DECODE), str(src), str(dst)],
        check=True, capture_output=True, env=_objc_env(),
    )


def _java_encode(src: Path, dst: Path, extra_flags: list[str] | None = None) -> None:
    java = _java_executable()
    cp = _java_classpath()
    assert java is not None and cp is not None
    args = [java, *_JAVA_FLAGS, "-cp", cp, JAVA_ENCODE_CLASS]
    if extra_flags:
        args.extend(extra_flags)
    args.extend([str(src), str(dst)])
    subprocess.run(args, check=True, capture_output=True)


def _java_decode(src: Path, dst: Path) -> None:
    java = _java_executable()
    cp = _java_classpath()
    assert java is not None and cp is not None
    subprocess.run(
        [java, *_JAVA_FLAGS, "-cp", cp, JAVA_DECODE_CLASS,
         str(src), str(dst)],
        check=True, capture_output=True,
    )


ENCODERS: dict[str, callable] = {"py": _py_encode}
DECODERS: dict[str, callable] = {"py": _py_decode}
if _objc_available():
    ENCODERS["objc"] = _objc_encode
    DECODERS["objc"] = _objc_decode
if _java_available():
    ENCODERS["java"] = _java_encode
    DECODERS["java"] = _java_decode


# Stage 5 / Task 5.6 (Deferral 1): per-accessor encode-side extra
# flags. MS_IMAGE_PROCESSED routes through ``--image-processed`` on
# every CLI so the encode side exercises write_image_processed
# (sparse wire mode); the decoder auto-dispatches on the
# ``is_continuous`` byte in the IMAGE_HEADER so the same decode path
# is used for both wire shapes.
_ENCODE_EXTRA_FLAGS: dict[str, list[str]] = {
    "MS_IMAGE_PROCESSED": ["--image-processed"],
}


# GENOMIC_RUNS exercises the v1.0 NAME_TOKENIZED_V2 codec which
# requires the native ``libttio_rans`` library on the Python side and
# the JNI shim ``libttio_rans_jni.so`` on the Java side. The Python
# codec dispatch is inside ``SpectralDataset.write_minimal``; mirrors
# the gating used by ``tests/test_accessor_matrix_conformance.py``.
def _genomic_runs_available_for_python() -> bool:
    from ttio.codecs._native_loader import load_ttio_rans

    return load_ttio_rans() is not None


def _genomic_runs_available_for_java() -> bool:
    """Java's ``NameTokenizerV2.decode`` path is a JNI bridge into
    ``libttio_rans_jni.so``. Probe the standard locations (the
    ``java.library.path`` we set via ``_JAVA_FLAGS`` + ``LD_LIBRARY_PATH``
    env var if set + the native build dir for in-tree runs)."""
    candidates = [
        Path("/usr/local/lib/libttio_rans_jni.so"),
        Path("/usr/lib/libttio_rans_jni.so"),
        Path(_NATIVE_LIB_DIR) / "libttio_rans_jni.so",
    ]
    env = os.environ.get("LD_LIBRARY_PATH", "")
    for p in env.split(":"):
        if p:
            candidates.append(Path(p) / "libttio_rans_jni.so")
    return any(c.exists() for c in candidates)


# ── tests ────────────────────────────────────────────────────────────


@pytest.mark.parametrize("spec", ACCESSOR_SPECS, ids=lambda s: s.name)
@pytest.mark.parametrize(
    "enc_lang,dec_lang",
    [(e, d) for e in ENCODERS for d in DECODERS],
)
def test_xlang_round_trip_preserves_accessor(
    tmp_path: Path, spec, enc_lang: str, dec_lang: str,
) -> None:
    """For one (encoder_lang × decoder_lang × accessor) cell of the
    9×8 matrix: build the isolation fixture, encode→decode through the
    requested language pair, then assert the accessor's content
    survives the round trip.

    All comparators are field-by-field rather than byte-equality on
    the ``.tio`` (HDF5 storage is not deterministic across SDKs) or
    byte-equality on the ``.tis`` (Arrow IPC framing diverges).
    Logical content equivalence is the conformance contract."""
    if spec.name == "GENOMIC_RUNS":
        if not _genomic_runs_available_for_python():
            pytest.skip(
                "GENOMIC_RUNS fixture requires libttio_rans native "
                "shim (NAME_TOKENIZED_V2 codec). Set "
                "TTIO_RANS_LIB_PATH or install ttio[native] to "
                "exercise this accessor."
            )
        if ("java" in (enc_lang, dec_lang)
                and not _genomic_runs_available_for_java()):
            pytest.skip(
                "GENOMIC_RUNS via Java requires libttio_rans_jni.so on "
                "java.library.path (/usr/local/lib or LD_LIBRARY_PATH). "
                "Built but uninstalled: cp native/_build/libttio_rans_jni.so "
                "/usr/local/lib/."
            )
    # Stage 5 / Task 5.6 cross-language IR_IMAGE — the SDK on-disk
    # representations were unified in commits e0a34674 (Java) and
    # 589f8a93 (ObjC): all three SDKs now write ``ir_mode`` as int64
    # (0=transmittance, 1=absorbance) and ``pixel_size_*`` /
    # ``resolution_cm_inv`` as native float64, matching Python's
    # original layout. Readers retain backward compat with the
    # legacy VL-string form, so existing .tio files keep loading.

    from ttio.spectral_dataset import SpectralDataset

    src = spec.build_fixture(tmp_path / f"{spec.name}.tio")
    tis = tmp_path / f"{spec.name}_{enc_lang}_to_{dec_lang}.tis"
    rt = tmp_path / f"{spec.name}_{enc_lang}_to_{dec_lang}-rt.tio"

    extra_flags = _ENCODE_EXTRA_FLAGS.get(spec.name)
    ENCODERS[enc_lang](src, tis, extra_flags=extra_flags)
    DECODERS[dec_lang](tis, rt)

    with SpectralDataset.open(src) as a, SpectralDataset.open(rt) as b:
        spec.assert_content_equals(a, b)


@pytest.mark.parametrize("enc_lang", list(ENCODERS.keys()))
def test_xlang_tis_bytes_equal_across_decoders(
    tmp_path: Path, enc_lang: str,
) -> None:
    """For each encoder language: emit the same fixture through one
    encoder, then verify every decoder lifts it to a content-
    equivalent ``.tio``. Pinpoints which (encoder, decoder) edge
    drops content if more than one decoder fails simultaneously on
    the same encoded ``.tis``.

    Uses the ENCRYPTION_ALGORITHM fixture as the smallest content-
    isolating one (no Arrow IPC, no HDF5 chunked datasets, no native
    codec dependency)."""
    enc_spec = next(s for s in ACCESSOR_SPECS
                    if s.name == "ENCRYPTION_ALGORITHM")
    src = enc_spec.build_fixture(tmp_path / "src.tio")
    tis = tmp_path / f"src_{enc_lang}.tis"
    ENCODERS[enc_lang](src, tis)

    from ttio.spectral_dataset import SpectralDataset

    failures: list[str] = []
    for dec_lang, dec in DECODERS.items():
        rt = tmp_path / f"rt_{enc_lang}_to_{dec_lang}.tio"
        try:
            dec(tis, rt)
            with SpectralDataset.open(src) as a, \
                    SpectralDataset.open(rt) as b:
                enc_spec.assert_content_equals(a, b)
        except Exception as e:  # noqa: BLE001 — surface every edge
            failures.append(f"{enc_lang}->{dec_lang}: {e}")
    if failures:
        raise AssertionError(
            "decoder edges failed on the same encoded .tis (encoder "
            f"= {enc_lang}):\n  " + "\n  ".join(failures)
        )
