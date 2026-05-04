"""4-corpus × 3-language byte-exact gate for NAME_TOKENIZED v2."""
from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
from pathlib import Path

import pytest

from ttio.codecs import name_tokenizer_v2 as nt2

CORPORA = {
    "chr22": "/home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam",
    "wes": "/home/toddw/TTI-O/data/genomic/na12878_wes/na12878_wes.chr22.bam",
    "hg002_illumina": "/home/toddw/TTI-O/data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam",
    "hg002_pacbio": "/home/toddw/TTI-O/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam",
}

OBJC_BIN = "/home/toddw/TTI-O/objc/Tools/obj/TtioNameTokV2Cli"
OBJC_LIB_DIR = "/home/toddw/TTI-O/objc/Source/obj"
NATIVE_LIB_DIR = "/home/toddw/TTI-O/native/_build"
JAVA_TARGET_DIR = "/home/toddw/TTI-O/java/target"


def _extract_names(bam_path: str, out_txt: str) -> int:
    proc = subprocess.run(
        ["samtools", "view", bam_path],
        capture_output=True, check=True, text=False,
    )
    n = 0
    with open(out_txt, "w") as f:
        for line in proc.stdout.split(b"\n"):
            if not line:
                continue
            qname = line.split(b"\t", 1)[0].decode("ascii", errors="replace")
            if qname == "*":
                continue
            f.write(qname + "\n")
            n += 1
    return n


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def _find_jar() -> str:
    candidates = sorted(Path(JAVA_TARGET_DIR).glob("ttio-*.jar"))
    candidates = [p for p in candidates if "sources" not in p.name and "javadoc" not in p.name]
    if not candidates:
        raise FileNotFoundError(f"no ttio-*.jar in {JAVA_TARGET_DIR} — run mvn package first")
    return str(candidates[0])


@pytest.mark.integration
@pytest.mark.parametrize("corpus,bam_path", list(CORPORA.items()))
def test_three_lang_byte_equal(corpus, bam_path, capsys):
    if not nt2.HAVE_NATIVE_LIB:
        pytest.skip("native lib not loaded")
    if not os.path.exists(bam_path):
        pytest.skip(f"BAM not found: {bam_path}")
    if not os.path.exists(OBJC_BIN):
        pytest.skip(f"ObjC CLI not built: {OBJC_BIN}")
    try:
        jar = _find_jar()
    except FileNotFoundError as e:
        pytest.skip(str(e))

    with tempfile.TemporaryDirectory(dir=os.path.expanduser("~")) as td:
        names_txt = f"{td}/names.txt"
        n = _extract_names(bam_path, names_txt)
        if n == 0:
            pytest.skip(f"{corpus}: BAM has no decodable QNAMEs")

        # Python encode
        with open(names_txt) as f:
            names = [line.rstrip("\n") for line in f]
        py_path = f"{td}/py.bin"
        Path(py_path).write_bytes(nt2.encode(names))

        # Java encode
        java_path = f"{td}/java.bin"
        subprocess.run(
            [
                "java",
                f"-Djava.library.path={NATIVE_LIB_DIR}",
                "-cp", jar,
                "global.thalion.ttio.tools.NameTokenizedV2Cli",
                names_txt, java_path,
            ],
            check=True, capture_output=True,
        )

        # ObjC encode
        objc_path = f"{td}/objc.bin"
        env = os.environ.copy()
        env["LD_LIBRARY_PATH"] = f"{OBJC_LIB_DIR}:{NATIVE_LIB_DIR}:{env.get('LD_LIBRARY_PATH', '')}"
        subprocess.run([OBJC_BIN, names_txt, objc_path], check=True, env=env, capture_output=True)

        py_hash = _sha256_file(py_path)
        java_hash = _sha256_file(java_path)
        objc_hash = _sha256_file(objc_path)

        with capsys.disabled():
            print()
            print(f"{corpus}: n={n:,}, blob={os.path.getsize(py_path):,} bytes")
            print(f"  Python: {py_hash}")
            print(f"  Java:   {java_hash}")
            print(f"  ObjC:   {objc_hash}")

        assert py_hash == java_hash, f"Python ↔ Java byte-equal failed for {corpus}"
        assert py_hash == objc_hash, f"Python ↔ ObjC byte-equal failed for {corpus}"
