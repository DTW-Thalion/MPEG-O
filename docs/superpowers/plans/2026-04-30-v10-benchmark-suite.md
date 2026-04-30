# V10 — Comprehensive Benchmark Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing V2 perf infrastructure with 6 missing benchmark dimensions (genomic codecs, genomic pipeline write/read/random-access, encryption at genomic scale, streaming) across Python, Java, and ObjC, plus a Python M95 hard-floor gate.

**Architecture:** Each language's full-harness file gets new benchmark functions registered in its benchmark registry. Results flow into the existing `baseline.json` → `compare_baseline.py` regression pipeline. No new infrastructure files are needed.

**Tech Stack:** Python (profile_python_full.py), Java (ProfileHarnessFull.java), ObjC (profile_objc_full.m), existing tools/perf/ CI plumbing.

---

## File Structure

| File | Responsibility | Change |
|------|---------------|--------|
| `tools/perf/profile_python_full.py` | Python perf harness | Add 5 benchmark functions + register |
| `python/tests/perf/test_m95_throughput.py` | DELTA_RANS hard-floor gate | Create |
| `tools/perf/ProfileHarnessFull.java` | Java perf harness | Add 4 benchmark methods + register |
| `tools/perf/profile_objc_full.m` | ObjC perf harness | Add 4 benchmark functions + register |
| `tools/perf/baseline.json` | Baseline timings | Capture initial values via `--update-baseline` |

---

### Task 1: Python Genomic Codec Benchmarks (B1)

**Files:**
- Modify: `tools/perf/profile_python_full.py`

- [ ] **Step 1: Add genomic codec imports**

At the top of `tools/perf/profile_python_full.py`, after the existing codec imports (line 66), add:

```python
# V10: genomic codec benchmarks.
from ttio.codecs.ref_diff import encode as _ref_diff_encode, decode as _ref_diff_decode
from ttio.codecs.fqzcomp_nx16 import encode as _fqzcomp_encode
from ttio.codecs.fqzcomp_nx16 import decode as _fqzcomp_decode
from ttio.codecs.fqzcomp_nx16_z import encode as _fqzcomp_z_encode
from ttio.codecs.fqzcomp_nx16_z import decode_with_metadata as _fqzcomp_z_decode
from ttio.codecs.delta_rans import encode as _delta_rans_encode, decode as _delta_rans_decode
```

- [ ] **Step 2: Add the `bench_codecs_genomic` function**

Insert after the existing `bench_codecs` function (after line 423):

```python
def bench_codecs_genomic(_tmp: Path, _n: int) -> dict[str, float]:
    """Isolated encode/decode for the 4 genomic codecs (V10).

    Production-scale inputs (~10 MiB each) so inner loops are hot for
    seconds. Deterministic seeds for cross-language parity.
    """
    import hashlib
    rng = np.random.default_rng(42)

    # ── REF_DIFF: 100K reads × 100bp against a 100Kbp reference ──
    ref_len = 100_000
    ref_seq = bytes(rng.choice(list(b"ACGT"), size=ref_len).tolist())
    ref_md5 = hashlib.md5(ref_seq).digest()
    n_reads_rd = 100_000
    read_len = 100
    sequences_rd: list[bytes] = []
    for i in range(n_reads_rd):
        start = i % (ref_len - read_len)
        seq = bytearray(ref_seq[start:start + read_len])
        # ~2% mutation rate
        for j in range(read_len):
            if rng.random() < 0.02:
                seq[j] = rng.choice(list(b"ACGT"))
        sequences_rd.append(bytes(seq))
    cigars_rd = [f"{read_len}M"] * n_reads_rd
    positions_rd = sorted(rng.integers(1, ref_len - read_len, size=n_reads_rd).tolist())

    t_rd_enc, rd_encoded = _timed(
        _ref_diff_encode, sequences_rd, cigars_rd, positions_rd,
        ref_seq, ref_md5, "perf-ref")
    t_rd_dec, _ = _timed(
        _ref_diff_decode, rd_encoded, cigars_rd, positions_rd, ref_seq)

    # ── FQZCOMP_NX16: 100K × 100bp quality strings, Q20-Q40 LCG ──
    n_qual = 100_000 * 100
    qual_buf = bytearray(n_qual)
    s = 0xBEEF
    mask64 = (1 << 64) - 1
    for i in range(n_qual):
        s = (s * 6364136223846793005 + 1442695040888963407) & mask64
        qual_buf[i] = 33 + 20 + ((s >> 32) % 21)
    qualities = bytes(qual_buf)
    read_lengths = [100] * 100_000
    revcomp_flags = [0] * 100_000

    t_fqz_enc, fqz_encoded = _timed(
        _fqzcomp_encode, qualities, read_lengths, revcomp_flags)
    t_fqz_dec, _ = _timed(_fqzcomp_decode, fqz_encoded)

    # ── FQZCOMP_NX16_Z: same quality input ──
    revcomp_flags_z = [(1 if (i & 7) == 0 else 0) for i in range(100_000)]
    t_fqz_z_enc, fqz_z_encoded = _timed(
        _fqzcomp_z_encode, qualities, read_lengths, revcomp_flags_z)
    t_fqz_z_dec, _ = _timed(
        _fqzcomp_z_decode, fqz_z_encoded, revcomp_flags_z)

    # ── DELTA_RANS: 1.25M sorted int64 positions, LCG deltas 100-500 ──
    n_pos = 1_250_000
    pos_vals = np.empty(n_pos, dtype=np.int64)
    pos_vals[0] = 1000
    s = 0xBEEF
    for i in range(1, n_pos):
        s = (s * 6364136223846793005 + 1442695040888963407) & mask64
        delta = 100 + ((s >> 32) % 401)  # 100..500
        pos_vals[i] = pos_vals[i - 1] + delta
    dr_input = pos_vals.astype("<i8").tobytes()

    t_dr_enc, dr_encoded = _timed(_delta_rans_encode, dr_input, 8)
    t_dr_dec, _ = _timed(_delta_rans_decode, dr_encoded)

    raw_mb_rd = sum(len(sq) for sq in sequences_rd) / 1e6
    print(f"  [genomic codec] ref_diff   {raw_mb_rd:.1f} MiB  "
          f"enc={t_rd_enc:.2f}s  dec={t_rd_dec:.2f}s")
    print(f"  [genomic codec] fqzcomp    {n_qual/1e6:.1f} MiB  "
          f"enc={t_fqz_enc:.2f}s  dec={t_fqz_dec:.2f}s")
    print(f"  [genomic codec] fqzcomp_z  {n_qual/1e6:.1f} MiB  "
          f"enc={t_fqz_z_enc:.2f}s  dec={t_fqz_z_dec:.2f}s")
    print(f"  [genomic codec] delta_rans {len(dr_input)/1e6:.1f} MiB  "
          f"enc={t_dr_enc:.2f}s  dec={t_dr_dec:.2f}s")

    return {
        "ref_diff_encode": t_rd_enc,
        "ref_diff_decode": t_rd_dec,
        "fqzcomp_nx16_encode": t_fqz_enc,
        "fqzcomp_nx16_decode": t_fqz_dec,
        "fqzcomp_nx16_z_encode": t_fqz_z_enc,
        "fqzcomp_nx16_z_decode": t_fqz_z_dec,
        "delta_rans_encode": t_dr_enc,
        "delta_rans_decode": t_dr_dec,
    }
```

- [ ] **Step 3: Register in the BENCHMARKS dict**

Add to the `BENCHMARKS` dict (after the `"codecs"` entry):

```python
    "codecs.genomic": lambda tmp, a: bench_codecs_genomic(tmp, a.n),
```

- [ ] **Step 4: Run to verify**

Run:
```bash
cd ~/TTI-O && python3 tools/perf/profile_python_full.py --only codecs.genomic --json /tmp/v10_test.json
```

Expected: Output shows `[codecs.genomic]` section with 8 timing entries. Verify the JSON file contains `"codecs.genomic": {"ref_diff_encode": ..., ...}` under `"results"`.

- [ ] **Step 5: Commit**

```bash
git add tools/perf/profile_python_full.py
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "perf(v10): Python genomic codec benchmarks (B1)"
```

---

### Task 2: Python Genomic Pipeline Benchmarks (B2-B4)

**Files:**
- Modify: `tools/perf/profile_python_full.py`

- [ ] **Step 1: Add genomic pipeline imports**

Add to the import section of `profile_python_full.py`:

```python
# V10: genomic pipeline benchmarks.
from ttio import SpectralDataset
from ttio.written_genomic_run import WrittenGenomicRun
from ttio.genomic_run import GenomicRun
from ttio.enums import AcquisitionMode
```

Note: `SpectralDataset` is already imported — skip if present. Add only `WrittenGenomicRun`, `GenomicRun`, `AcquisitionMode` if not already imported.

- [ ] **Step 2: Add the genomic workload builder**

Insert after the `bench_codecs_genomic` function:

```python
def _build_genomic_run(rng) -> WrittenGenomicRun:
    """100K-read synthetic WGS run with all channels populated (V10)."""
    n_reads = 100_000
    read_len = 100

    # Positions: sorted ascending, LCG deltas 100-500.
    positions = np.empty(n_reads, dtype=np.int64)
    positions[0] = 1000
    s = 0xBEEF
    mask64 = (1 << 64) - 1
    for i in range(1, n_reads):
        s = (s * 6364136223846793005 + 1442695040888963407) & mask64
        delta = 100 + ((s >> 32) % 401)
        positions[i] = positions[i - 1] + delta
    positions.sort()

    # Flags: 5 dominant values.
    flag_vals = np.array([0, 16, 83, 99, 163], dtype=np.uint32)
    flags = rng.choice(flag_vals, size=n_reads).astype(np.uint32)

    # Mapping qualities: Q0-Q60.
    mapping_qualities = rng.integers(0, 61, size=n_reads, dtype=np.uint8)

    # Sequences: ACGT pattern with seeded mutations, 100bp per read.
    base_pattern = b"ACGTACGTAC" * 10  # 100bp
    seq_buf = bytearray()
    for i in range(n_reads):
        seq = bytearray(base_pattern)
        for j in range(read_len):
            if rng.random() < 0.02:
                seq[j] = rng.choice(list(b"ACGT"))
        seq_buf.extend(seq)
    sequences = np.frombuffer(bytes(seq_buf), dtype=np.uint8)

    # Qualities: Q20-Q40 LCG profile.
    n_qual = n_reads * read_len
    qual_buf = bytearray(n_qual)
    qs = 0xBEEF
    for i in range(n_qual):
        qs = (qs * 6364136223846793005 + 1442695040888963407) & mask64
        qual_buf[i] = 33 + 20 + ((qs >> 32) % 21)
    qualities = np.frombuffer(bytes(qual_buf), dtype=np.uint8)

    offsets = np.arange(n_reads, dtype=np.uint64) * read_len
    lengths = np.full(n_reads, read_len, dtype=np.uint32)

    cigars = [f"{read_len}M"] * n_reads
    read_names = [f"M88_{i:08d}:001:01" for i in range(n_reads)]

    # Mate info.
    mate_chromosomes = ["chr1"] * n_reads
    mate_positions = positions + rng.integers(100, 500, size=n_reads)
    template_lengths = rng.integers(200, 500, size=n_reads, dtype=np.int32)

    chromosomes = ["chr1"]

    return WrittenGenomicRun(
        acquisition_mode=AcquisitionMode.GENOMIC_WGS,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="V10-BENCH",
        positions=positions,
        mapping_qualities=mapping_qualities,
        flags=flags,
        sequences=sequences,
        qualities=qualities,
        offsets=offsets,
        lengths=lengths,
        cigars=cigars,
        read_names=read_names,
        mate_chromosomes=mate_chromosomes,
        mate_positions=mate_positions,
        template_lengths=template_lengths,
        chromosomes=chromosomes,
    )
```

- [ ] **Step 3: Add `bench_genomic_write_read` function**

```python
def bench_genomic_write_read(tmp: Path, _n: int) -> dict[str, float]:
    """E2E genomic pipeline: write 100K reads → .tio, read all back,
    random-access 1000 reads (V10 B2-B4)."""
    rng = np.random.default_rng(42)
    genomic_run = _build_genomic_run(rng)

    tio_path = str(tmp / "genomic-bench.tio")
    raw_bytes = (
        genomic_run.sequences.nbytes +
        genomic_run.qualities.nbytes +
        genomic_run.positions.nbytes +
        genomic_run.flags.nbytes +
        genomic_run.mapping_qualities.nbytes
    )

    # B2: write
    t_write, _ = _timed(
        SpectralDataset.write_minimal,
        tio_path, title="v10-bench", isa_investigation_id="ISA-V10",
        genomic_runs={"bench": genomic_run},
    )

    # B3: sequential read
    def _seq_read() -> int:
        with SpectralDataset.open(tio_path) as ds:
            run = ds.genomic_runs["bench"]
            count = 0
            for read in run:
                count += 1
            return count
    t_read, n_read = _timed(_seq_read)

    # B4: random access — 1000 reads at random indices
    access_rng = np.random.default_rng(99)
    indices = access_rng.integers(0, 100_000, size=1000).tolist()
    latencies: list[float] = []

    with SpectralDataset.open(tio_path) as ds:
        run = ds.genomic_runs["bench"]
        for idx in indices:
            t0 = time.perf_counter()
            _ = run[idx]
            latencies.append(time.perf_counter() - t0)

    latencies.sort()
    p50 = latencies[len(latencies) // 2]
    p99 = latencies[int(len(latencies) * 0.99)]

    print(f"  [genomic] write: {t_write:.2f}s  "
          f"read: {t_read:.2f}s ({n_read} reads)  "
          f"random p50={p50*1000:.2f}ms  p99={p99*1000:.2f}ms")

    return {
        "write": t_write,
        "write_mb": raw_bytes / 1e6,
        "read": t_read,
        "random_access_p50": p50,
        "random_access_p99": p99,
    }
```

- [ ] **Step 4: Register in BENCHMARKS**

```python
    "genomic":        lambda tmp, a: bench_genomic_write_read(tmp, a.n),
```

- [ ] **Step 5: Run to verify**

Run:
```bash
cd ~/TTI-O && python3 tools/perf/profile_python_full.py --only genomic --json /tmp/v10_genomic.json
```

Expected: Output shows `[genomic]` section with write/read/random_access timings. JSON has 5 keys under `"genomic"`.

- [ ] **Step 6: Commit**

```bash
git add tools/perf/profile_python_full.py
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "perf(v10): Python genomic pipeline benchmarks (B2-B4)"
```

---

### Task 3: Python Encryption + Streaming Benchmarks (B5-B6)

**Files:**
- Modify: `tools/perf/profile_python_full.py`

- [ ] **Step 1: Add encryption and streaming imports**

Add to the imports if not already present:

```python
# V10: encryption at genomic scale + streaming.
from ttio.encryption import encrypt_bytes, decrypt_bytes
from ttio.stream_writer import StreamWriter
from ttio.stream_reader import StreamReader
```

- [ ] **Step 2: Add `bench_encryption_genomic` function**

```python
def bench_encryption_genomic(_tmp: Path, _n: int) -> dict[str, float]:
    """AES-256-GCM encrypt/decrypt on a 10 MiB payload (V10 B5).

    Confirms no size-dependent perf cliff vs. the existing ~0.33 MiB
    spectral encryption benchmark.
    """
    payload_size = 10 * 1024 * 1024  # 10 MiB
    rng = np.random.default_rng(42)
    payload = rng.integers(0, 256, size=payload_size, dtype=np.uint8).tobytes()
    key = bytes(range(32))

    t_enc, sealed = _timed(encrypt_bytes, payload, key)
    t_dec, _ = _timed(decrypt_bytes, sealed, key)

    mb = payload_size / 1e6
    print(f"  [encryption.genomic] {mb:.1f} MiB  "
          f"enc={t_enc:.3f}s  dec={t_dec:.3f}s")

    return {
        "encrypt": t_enc,
        "decrypt": t_dec,
        "bytes_mb": mb,
    }
```

- [ ] **Step 3: Add `bench_streaming` function**

```python
def bench_streaming(tmp: Path, n: int, peaks: int) -> dict[str, float]:
    """StreamWriter/StreamReader throughput: 10K spectra (V10 B6)."""
    tis_path = str(tmp / "streaming-bench.tis")
    run = _build_ms_run(n, peaks)

    # Build the source .tio so StreamWriter has something to work with.
    tio_path = str(tmp / "streaming-src.tio")
    SpectralDataset.write_minimal(
        tio_path, title="stream-bench", isa_investigation_id="ISA-STREAM",
        runs={"r": run},
    )

    # Write .tis
    def _stream_write():
        writer = StreamWriter(tis_path, "r",
                              acquisition_mode=0,
                              instrument_config=None)
        with SpectralDataset.open(tio_path) as ds:
            r = ds.ms_runs["r"]
            for i in range(n):
                writer.append_spectrum(r[i])
        writer.flush_and_close()
    t_write, _ = _timed(_stream_write)

    # Read .tis
    def _stream_read() -> int:
        reader = StreamReader(tis_path, "r")
        count = 0
        with reader:
            while not reader.at_end():
                reader.next_spectrum()
                count += 1
        return count
    t_read, count = _timed(_stream_read)

    print(f"  [streaming] {n} spectra × {peaks} peaks  "
          f"write={t_write:.2f}s  read={t_read:.2f}s ({count} read back)")

    return {
        "write": t_write,
        "read": t_read,
    }
```

- [ ] **Step 4: Register both in BENCHMARKS**

```python
    "encryption.genomic": lambda tmp, a: bench_encryption_genomic(tmp, a.n),
    "streaming":          lambda tmp, a: bench_streaming(tmp, a.n, a.peaks),
```

- [ ] **Step 5: Run to verify**

```bash
cd ~/TTI-O && python3 tools/perf/profile_python_full.py --only encryption.genomic,streaming --json /tmp/v10_enc_stream.json
```

Expected: Both sections appear with timings. JSON has `"encryption.genomic"` and `"streaming"` keys.

- [ ] **Step 6: Commit**

```bash
git add tools/perf/profile_python_full.py
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "perf(v10): Python encryption genomic + streaming benchmarks (B5-B6)"
```

---

### Task 4: Python M95 DELTA_RANS Hard-Floor Gate

**Files:**
- Create: `python/tests/perf/test_m95_throughput.py`

- [ ] **Step 1: Create the perf test file**

```python
"""M95 DELTA_RANS throughput regression smoke.

Marked ``perf`` so it doesn't run in the default pytest pass; opt-in via
``pytest -m perf``. Asserts a conservative lower bound on the Python
encoder and decoder.

Input: 1.25M sorted ascending int64 positions, LCG seed 0xBEEF, deltas
100-500 (~10 MiB raw). Matches the V10 harness bench_codecs_genomic
workload.

Run::

    pytest python/tests/perf/test_m95_throughput.py -v -s -m perf
"""
from __future__ import annotations

import struct
import time

import pytest

from ttio.codecs.delta_rans import decode as delta_rans_decode
from ttio.codecs.delta_rans import encode as delta_rans_encode

MIN_ENCODE_MBPS = 1.0
MIN_DECODE_MBPS = 1.0


def _build_sorted_positions(n: int) -> bytes:
    """1.25M sorted ascending int64, LCG deltas 100-500."""
    values = []
    pos = 1000
    s = 0xBEEF
    mask64 = (1 << 64) - 1
    for _ in range(n):
        values.append(pos)
        s = (s * 6364136223846793005 + 1442695040888963407) & mask64
        delta = 100 + ((s >> 32) % 401)
        pos += delta
    return struct.pack(f"<{n}q", *values)


@pytest.mark.perf
def test_delta_rans_encode_decode_throughput(capsys):
    """Encode+decode 1.25M sorted int64 positions (~10 MiB)."""
    n = 1_250_000
    raw = _build_sorted_positions(n)
    raw_mb = len(raw) / 1e6

    t0 = time.perf_counter()
    encoded = delta_rans_encode(raw, 8)
    t_enc = time.perf_counter() - t0

    t1 = time.perf_counter()
    decoded = delta_rans_decode(encoded)
    t_dec = time.perf_counter() - t1

    enc_mbps = raw_mb / t_enc if t_enc > 0 else float("inf")
    dec_mbps = raw_mb / t_dec if t_dec > 0 else float("inf")
    ratio = len(encoded) / len(raw)

    with capsys.disabled():
        print(
            f"\n[m95 perf] {n:,} int64 positions, "
            f"{raw_mb:.1f}MB raw -> {len(encoded)/1e6:.2f}MB encoded "
            f"({ratio:.3f}x ratio)"
        )
        print(
            f"  encode {enc_mbps:.1f} MB/s ({t_enc:.2f}s), "
            f"decode {dec_mbps:.1f} MB/s ({t_dec:.2f}s)"
        )

    assert decoded == raw, "round-trip mismatch"
    assert enc_mbps >= MIN_ENCODE_MBPS, (
        f"DELTA_RANS encode at {enc_mbps:.1f} MB/s, need >={MIN_ENCODE_MBPS} MB/s"
    )
    assert dec_mbps >= MIN_DECODE_MBPS, (
        f"DELTA_RANS decode at {dec_mbps:.1f} MB/s, need >={MIN_DECODE_MBPS} MB/s"
    )
```

- [ ] **Step 2: Run the test**

```bash
cd ~/TTI-O && python3 -m pytest python/tests/perf/test_m95_throughput.py -v -s -m perf
```

Expected: PASS with throughput output printed.

- [ ] **Step 3: Commit**

```bash
git add python/tests/perf/test_m95_throughput.py
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "perf(v10): M95 DELTA_RANS hard-floor regression gate"
```

---

### Task 5: Java Genomic Codec Benchmarks (B1)

**Files:**
- Modify: `tools/perf/ProfileHarnessFull.java`

- [ ] **Step 1: Add the `benchCodecsGenomic` method**

Insert after the existing `benchCodecs` method (after line 432). Java stores timing as milliseconds internally (nanos / 1e6); the JSON output layer divides by 1000 to get seconds.

```java
    private static Result benchCodecsGenomic(int n) {
        Result r = new Result();
        long t;

        // ── REF_DIFF: 100K reads × 100bp ──
        int refLen = 100_000;
        int readLen = 100;
        int nReadsRd = 100_000;
        java.util.Random rdRng = new java.util.Random(42);
        byte[] refSeq = new byte[refLen];
        byte[] alpha = {(byte) 'A', (byte) 'C', (byte) 'G', (byte) 'T'};
        for (int i = 0; i < refLen; i++) refSeq[i] = alpha[rdRng.nextInt(4)];
        byte[] refMd5;
        try {
            refMd5 = java.security.MessageDigest.getInstance("MD5").digest(refSeq);
        } catch (Exception e) { throw new RuntimeException(e); }

        java.util.List<byte[]> seqsRd = new java.util.ArrayList<>(nReadsRd);
        long[] positionsRd = new long[nReadsRd];
        // Generate sorted positions.
        long pos = 1000;
        long lcg = 0xBEEFL;
        for (int i = 0; i < nReadsRd; i++) {
            positionsRd[i] = pos;
            lcg = (lcg * 6364136223846793005L + 1442695040888963407L);
            long delta = 100 + (((lcg >>> 32) & 0xFFFFFFFFL) % 401);
            pos += delta;
        }
        java.util.Arrays.sort(positionsRd);
        for (int i = 0; i < nReadsRd; i++) {
            int start = (int) (positionsRd[i] % (refLen - readLen));
            if (start < 0) start = 0;
            byte[] seq = java.util.Arrays.copyOfRange(refSeq, start, start + readLen);
            for (int j = 0; j < readLen; j++) {
                if (rdRng.nextDouble() < 0.02) seq[j] = alpha[rdRng.nextInt(4)];
            }
            seqsRd.add(seq);
        }
        java.util.List<String> cigarsRd = new java.util.ArrayList<>(nReadsRd);
        for (int i = 0; i < nReadsRd; i++) cigarsRd.add(readLen + "M");

        t = System.nanoTime();
        byte[] rdEnc = global.thalion.ttio.codecs.RefDiff.encode(
                seqsRd, cigarsRd, positionsRd, refSeq, refMd5, "perf-ref");
        r.timings.put("ref_diff_encode", (System.nanoTime() - t) / 1e6);

        t = System.nanoTime();
        global.thalion.ttio.codecs.RefDiff.decode(rdEnc, cigarsRd, positionsRd, refSeq);
        r.timings.put("ref_diff_decode", (System.nanoTime() - t) / 1e6);

        // ── FQZCOMP_NX16: 100K × 100bp quality strings ──
        int nQual = 100_000 * 100;
        byte[] quals = new byte[nQual];
        long qs = 0xBEEFL;
        for (int i = 0; i < nQual; i++) {
            qs = (qs * 6364136223846793005L + 1442695040888963407L);
            quals[i] = (byte) (33 + 20 + (int) (((qs >>> 32) & 0xFFFFFFFFL) % 21));
        }
        int[] readLengths = new int[100_000];
        java.util.Arrays.fill(readLengths, 100);
        int[] revcomp = new int[100_000];

        t = System.nanoTime();
        byte[] fqzEnc = global.thalion.ttio.codecs.FqzcompNx16.encode(
                quals, readLengths, revcomp);
        r.timings.put("fqzcomp_nx16_encode", (System.nanoTime() - t) / 1e6);

        t = System.nanoTime();
        global.thalion.ttio.codecs.FqzcompNx16.decode(fqzEnc);
        r.timings.put("fqzcomp_nx16_decode", (System.nanoTime() - t) / 1e6);

        // ── FQZCOMP_NX16_Z: same qualities, with revcomp flags ──
        int[] revcompZ = new int[100_000];
        for (int i = 0; i < 100_000; i++) revcompZ[i] = ((i & 7) == 0) ? 1 : 0;

        t = System.nanoTime();
        byte[] fqzZEnc = global.thalion.ttio.codecs.FqzcompNx16Z.encode(
                quals, readLengths, revcompZ);
        r.timings.put("fqzcomp_nx16_z_encode", (System.nanoTime() - t) / 1e6);

        t = System.nanoTime();
        global.thalion.ttio.codecs.FqzcompNx16Z.decode(fqzZEnc, revcompZ);
        r.timings.put("fqzcomp_nx16_z_decode", (System.nanoTime() - t) / 1e6);

        // ── DELTA_RANS: 1.25M sorted int64 positions ──
        int nPos = 1_250_000;
        ByteBuffer bb = ByteBuffer.allocate(nPos * 8).order(ByteOrder.LITTLE_ENDIAN);
        long dpos = 1000;
        long ds = 0xBEEFL;
        for (int i = 0; i < nPos; i++) {
            bb.putLong(dpos);
            ds = (ds * 6364136223846793005L + 1442695040888963407L);
            long dd = 100 + (((ds >>> 32) & 0xFFFFFFFFL) % 401);
            dpos += dd;
        }
        byte[] drInput = bb.array();

        t = System.nanoTime();
        byte[] drEnc = global.thalion.ttio.codecs.DeltaRans.encode(drInput, 8);
        r.timings.put("delta_rans_encode", (System.nanoTime() - t) / 1e6);

        t = System.nanoTime();
        global.thalion.ttio.codecs.DeltaRans.decode(drEnc);
        r.timings.put("delta_rans_decode", (System.nanoTime() - t) / 1e6);

        return r;
    }
```

- [ ] **Step 2: Register in BENCH_ORDER**

Add to the `BENCH_ORDER` array:

```java
    private static final String[] BENCH_ORDER = {
        "ms.hdf5", "ms.memory", "ms.sqlite", "ms.zarr",
        "transport.plain", "transport.compressed",
        "encryption", "signatures", "jcamp", "spectra.build",
        "codecs",
        "codecs.genomic",
    };
```

- [ ] **Step 3: Add case to `runOne` switch**

```java
            case "codecs.genomic": return benchCodecsGenomic(n);
```

- [ ] **Step 4: Run to verify**

```bash
cd ~/TTI-O && mvn -f java/pom.xml compile -q && \
  java -cp "java/target/classes:$(cat java/target/runtime-classpath.txt)" \
    tools.perf.ProfileHarnessFull --only codecs.genomic --json /tmp/v10_java_codecs.json
```

Expected: `[codecs.genomic]` section with 8 timing entries.

- [ ] **Step 5: Commit**

```bash
git add tools/perf/ProfileHarnessFull.java
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "perf(v10): Java genomic codec benchmarks (B1)"
```

---

### Task 6: Java Pipeline + Encryption + Streaming Benchmarks (B2-B6)

**Files:**
- Modify: `tools/perf/ProfileHarnessFull.java`

- [ ] **Step 1: Add genomic pipeline imports**

Add to the imports section:

```java
import global.thalion.ttio.genomics.WrittenGenomicRun;
import global.thalion.ttio.genomics.GenomicRun;
import global.thalion.ttio.genomics.AlignedRead;
import global.thalion.ttio.Enums.Compression;
import global.thalion.ttio.StreamWriter;
import global.thalion.ttio.StreamReader;
import global.thalion.ttio.protection.EncryptionManager;
```

- [ ] **Step 2: Add `benchGenomic` method**

```java
    private static Result benchGenomic(Path tmp, int n) throws Exception {
        Result r = new Result();
        int nReads = 100_000;
        int readLen = 100;

        // Build positions (sorted ascending, LCG deltas 100-500).
        long[] positions = new long[nReads];
        long pos = 1000;
        long lcg = 0xBEEFL;
        for (int i = 0; i < nReads; i++) {
            positions[i] = pos;
            lcg = (lcg * 6364136223846793005L + 1442695040888963407L);
            long delta = 100 + (((lcg >>> 32) & 0xFFFFFFFFL) % 401);
            pos += delta;
        }
        Arrays.sort(positions);

        // Flags.
        int[] flagVals = {0, 16, 83, 99, 163};
        java.util.Random rng = new java.util.Random(42);
        int[] flags = new int[nReads];
        for (int i = 0; i < nReads; i++) flags[i] = flagVals[rng.nextInt(5)];

        // Mapping qualities.
        byte[] mapQ = new byte[nReads];
        for (int i = 0; i < nReads; i++) mapQ[i] = (byte) rng.nextInt(61);

        // Sequences.
        byte[] seqPattern = "ACGTACGTAC".repeat(10).getBytes();
        byte[] sequences = new byte[nReads * readLen];
        byte[] acgt = {(byte) 'A', (byte) 'C', (byte) 'G', (byte) 'T'};
        for (int i = 0; i < nReads; i++) {
            System.arraycopy(seqPattern, 0, sequences, i * readLen, readLen);
            for (int j = 0; j < readLen; j++) {
                if (rng.nextDouble() < 0.02)
                    sequences[i * readLen + j] = acgt[rng.nextInt(4)];
            }
        }

        // Qualities (LCG Q20-Q40).
        int nQual = nReads * readLen;
        byte[] qualities = new byte[nQual];
        long qs = 0xBEEFL;
        for (int i = 0; i < nQual; i++) {
            qs = (qs * 6364136223846793005L + 1442695040888963407L);
            qualities[i] = (byte) (33 + 20 + (int) (((qs >>> 32) & 0xFFFFFFFFL) % 21));
        }

        long[] offsets = new long[nReads];
        int[] lengths = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            offsets[i] = (long) i * readLen;
            lengths[i] = readLen;
        }

        List<String> cigars = new java.util.ArrayList<>(nReads);
        List<String> readNames = new java.util.ArrayList<>(nReads);
        List<String> mateChroms = new java.util.ArrayList<>(nReads);
        long[] matePositions = new long[nReads];
        int[] templateLengths = new int[nReads];
        for (int i = 0; i < nReads; i++) {
            cigars.add(readLen + "M");
            readNames.add(String.format("M88_%08d:001:01", i));
            mateChroms.add("chr1");
            matePositions[i] = positions[i] + 100 + rng.nextInt(400);
            templateLengths[i] = 200 + rng.nextInt(300);
        }

        WrittenGenomicRun genomicRun = new WrittenGenomicRun(
                AcquisitionMode.GENOMIC_WGS,
                "GRCh38.p14", "ILLUMINA", "V10-BENCH",
                positions, mapQ, flags, sequences, qualities,
                offsets, lengths, cigars, readNames,
                mateChroms, matePositions, templateLengths,
                List.of("chr1"),
                Compression.RANS_ORDER0,
                Map.of(),
                List.of(),
                false, null, null);

        String tioPath = tmp.resolve("genomic-bench.tio").toString();

        // B2: write
        long s = System.nanoTime();
        try (SpectralDataset ds = SpectralDataset.create(
                tioPath, "v10-bench", "ISA-V10",
                List.of(), List.of(), List.of(), List.of(),
                Map.of("bench", genomicRun))) {
        }
        r.timing("write", System.nanoTime() - s);
        long rawBytes = (long) sequences.length + qualities.length +
                         positions.length * 8L + flags.length * 4L + mapQ.length;
        r.size("write_mb", rawBytes);

        // B3: sequential read
        s = System.nanoTime();
        int readCount = 0;
        try (SpectralDataset ds = SpectralDataset.open(tioPath)) {
            GenomicRun run = ds.genomicRuns().get("bench");
            for (AlignedRead read : run) {
                readCount++;
            }
        }
        r.timing("read", System.nanoTime() - s);

        // B4: random access — 1000 reads
        java.util.Random accessRng = new java.util.Random(99);
        int[] indices = new int[1000];
        for (int i = 0; i < 1000; i++) indices[i] = accessRng.nextInt(nReads);
        long[] latenciesNs = new long[1000];
        try (SpectralDataset ds = SpectralDataset.open(tioPath)) {
            GenomicRun run = ds.genomicRuns().get("bench");
            for (int i = 0; i < 1000; i++) {
                long t0 = System.nanoTime();
                run.alignedReadAt(indices[i]);
                latenciesNs[i] = System.nanoTime() - t0;
            }
        }
        Arrays.sort(latenciesNs);
        r.timings.put("random_access_p50", latenciesNs[500] / 1e6);
        r.timings.put("random_access_p99", latenciesNs[990] / 1e6);

        return r;
    }
```

- [ ] **Step 3: Add `benchEncryptionGenomic` method**

```java
    private static Result benchEncryptionGenomic() throws Exception {
        Result r = new Result();
        int payloadSize = 10 * 1024 * 1024; // 10 MiB
        java.util.Random rng = new java.util.Random(42);
        byte[] payload = new byte[payloadSize];
        rng.nextBytes(payload);
        byte[] key = new byte[32];
        for (int i = 0; i < 32; i++) key[i] = (byte) i;

        long s = System.nanoTime();
        EncryptionManager.EncryptResult sealed = EncryptionManager.encrypt(payload, key);
        r.timing("encrypt", System.nanoTime() - s);

        s = System.nanoTime();
        EncryptionManager.decrypt(sealed.ciphertext(), sealed.iv(), sealed.tag(), key);
        r.timing("decrypt", System.nanoTime() - s);
        r.size("bytes_mb", payloadSize);

        return r;
    }
```

- [ ] **Step 4: Add `benchStreaming` method**

```java
    private static Result benchStreaming(Path tmp, int n, int peaks) throws Exception {
        Result r = new Result();
        // Build source .tio.
        Path src = tmp.resolve("stream-src.tio");
        AcquisitionRun run = makeRun(n, peaks);
        try (SpectralDataset ds = SpectralDataset.create(
                src.toString(), "stream-bench", "ISA-STREAM",
                List.of(run), List.of(), List.of(), List.of())) {
        }

        Path tisPath = tmp.resolve("streaming-bench.tis");

        // Write .tis
        long s = System.nanoTime();
        try (SpectralDataset ds = SpectralDataset.open(src.toString())) {
            AcquisitionRun back = ds.msRuns().get("r");
            StreamWriter writer = new StreamWriter(tisPath, "r",
                    AcquisitionMode.MS1_DDA, null);
            for (int i = 0; i < n; i++) {
                writer.appendSpectrum(back.objectAtIndex(i));
            }
            writer.flushAndClose();
        }
        r.timing("write", System.nanoTime() - s);

        // Read .tis
        s = System.nanoTime();
        int count = 0;
        try (StreamReader reader = new StreamReader(tisPath, "r")) {
            while (reader.hasMore()) {
                reader.nextObject();
                count++;
            }
        }
        r.timing("read", System.nanoTime() - s);
        if (count != n) throw new IllegalStateException(
                "streaming read " + count + " != " + n);

        return r;
    }
```

- [ ] **Step 5: Register all three in BENCH_ORDER and switch**

Update `BENCH_ORDER`:

```java
    private static final String[] BENCH_ORDER = {
        "ms.hdf5", "ms.memory", "ms.sqlite", "ms.zarr",
        "transport.plain", "transport.compressed",
        "encryption", "signatures", "jcamp", "spectra.build",
        "codecs",
        "codecs.genomic", "genomic",
        "encryption.genomic", "streaming",
    };
```

Add cases to `runOne`:

```java
            case "codecs.genomic":    return benchCodecsGenomic(n);
            case "genomic":           return benchGenomic(tmp, n);
            case "encryption.genomic": return benchEncryptionGenomic();
            case "streaming":         return benchStreaming(tmp, n, peaks);
```

- [ ] **Step 6: Run to verify**

```bash
cd ~/TTI-O && mvn -f java/pom.xml compile -q && \
  java -cp "java/target/classes:$(cat java/target/runtime-classpath.txt)" \
    tools.perf.ProfileHarnessFull --only genomic,encryption.genomic,streaming \
    --json /tmp/v10_java_pipeline.json
```

Expected: Three benchmark sections with timings. JSON file has all keys.

- [ ] **Step 7: Commit**

```bash
git add tools/perf/ProfileHarnessFull.java
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "perf(v10): Java genomic pipeline + encryption + streaming benchmarks (B2-B6)"
```

---

### Task 7: ObjC Genomic Codec Benchmarks (B1)

**Files:**
- Modify: `tools/perf/profile_objc_full.m`

- [ ] **Step 1: Add genomic codec imports**

After the existing codec imports (line 619), add:

```objc
#import "Codecs/TTIORefDiff.h"
#import "Codecs/TTIOFqzcompNx16.h"
#import "Codecs/TTIOFqzcompNx16Z.h"
#import "Codecs/TTIODeltaRans.h"
```

- [ ] **Step 2: Add `bench_codecs_genomic` function**

Insert after the existing `bench_codecs` function:

```objc
static int cmp_int64(const void *a, const void *b) {
    int64_t va = *(const int64_t *)a, vb = *(const int64_t *)b;
    return (va > vb) - (va < vb);
}

static void bench_codecs_genomic(NSString *tmp, NSUInteger n, NSUInteger peaks,
                                  NSMutableDictionary *out)
{
    (void)tmp; (void)n; (void)peaks;
    @autoreleasepool {
        // ── REF_DIFF: 100K reads × 100bp ──
        const NSUInteger refLen = 100000;
        const NSUInteger readLen = 100;
        const NSUInteger nReadsRd = 100000;
        srand(42);

        NSMutableData *refSeqData = [NSMutableData dataWithLength:refLen];
        uint8_t *refp = refSeqData.mutableBytes;
        const char alpha[] = "ACGT";
        for (NSUInteger i = 0; i < refLen; i++) refp[i] = (uint8_t)alpha[rand() & 3];

        // Sorted positions via LCG.
        int64_t *posArr = malloc(nReadsRd * sizeof(int64_t));
        int64_t pos = 1000;
        uint64_t lcg = 0xBEEFULL;
        for (NSUInteger i = 0; i < nReadsRd; i++) {
            posArr[i] = pos;
            lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL;
            int64_t delta = 100 + (int64_t)(((lcg >> 32) & 0xFFFFFFFF) % 401);
            pos += delta;
        }
        // Sort positions (already ascending from LCG+delta, but sort for safety).
        qsort(posArr, nReadsRd, sizeof(int64_t), cmp_int64);
        NSData *positionsData = [NSData dataWithBytes:posArr length:nReadsRd * sizeof(int64_t)];

        NSMutableArray<NSData *> *seqsRd = [NSMutableArray arrayWithCapacity:nReadsRd];
        NSMutableArray<NSString *> *cigarsRd = [NSMutableArray arrayWithCapacity:nReadsRd];
        for (NSUInteger i = 0; i < nReadsRd; i++) {
            NSUInteger start = (NSUInteger)(posArr[i] % (int64_t)(refLen - readLen));
            NSMutableData *seq = [NSMutableData dataWithBytes:refp + start length:readLen];
            uint8_t *sp = seq.mutableBytes;
            for (NSUInteger j = 0; j < readLen; j++) {
                if ((rand() % 100) < 2) sp[j] = (uint8_t)alpha[rand() & 3];
            }
            [seqsRd addObject:seq];
            [cigarsRd addObject:[NSString stringWithFormat:@"%luM", (unsigned long)readLen]];
        }
        free(posArr);

        // MD5 of reference.
        unsigned char refMd5Bytes[16];
        CC_MD5(refSeqData.bytes, (CC_LONG)refSeqData.length, refMd5Bytes);
        NSData *refMd5 = [NSData dataWithBytes:refMd5Bytes length:16];

        NSError *err = nil;
        double t0 = nowSeconds();
        NSData *rdEnc = [TTIORefDiff encodeWithSequences:seqsRd
                                                  cigars:cigarsRd
                                               positions:positionsData
                                      referenceChromSeq:refSeqData
                                            referenceMD5:refMd5
                                            referenceURI:@"perf-ref"
                                                   error:&err];
        putSeconds(out, @"ref_diff_encode", nowSeconds() - t0);
        if (!rdEnc) { NSLog(@"REF_DIFF encode failed: %@", err); return; }

        t0 = nowSeconds();
        (void)[TTIORefDiff decodeData:rdEnc
                               cigars:cigarsRd
                            positions:positionsData
                   referenceChromSeq:refSeqData
                                error:&err];
        putSeconds(out, @"ref_diff_decode", nowSeconds() - t0);

        // ── FQZCOMP_NX16: 100K × 100bp qualities ──
        const NSUInteger nQual = 100000 * 100;
        NSMutableData *qualData = [NSMutableData dataWithLength:nQual];
        uint8_t *qp = qualData.mutableBytes;
        uint64_t qs = 0xBEEFULL;
        for (NSUInteger i = 0; i < nQual; i++) {
            qs = qs * 6364136223846793005ULL + 1442695040888963407ULL;
            qp[i] = (uint8_t)(33u + 20u + (uint32_t)((qs >> 32) % 21u));
        }
        NSMutableArray<NSNumber *> *rdLens = [NSMutableArray arrayWithCapacity:100000];
        NSMutableArray<NSNumber *> *revcomp = [NSMutableArray arrayWithCapacity:100000];
        NSMutableArray<NSNumber *> *revcompZ = [NSMutableArray arrayWithCapacity:100000];
        for (NSUInteger i = 0; i < 100000; i++) {
            [rdLens addObject:@(100)];
            [revcomp addObject:@(0)];
            [revcompZ addObject:@((i & 7) == 0 ? 1 : 0)];
        }

        t0 = nowSeconds();
        NSData *fqzEnc = [TTIOFqzcompNx16 encodeWithQualities:qualData
                                                   readLengths:rdLens
                                                  revcompFlags:revcomp
                                                         error:&err];
        putSeconds(out, @"fqzcomp_nx16_encode", nowSeconds() - t0);

        t0 = nowSeconds();
        (void)[TTIOFqzcompNx16 decodeData:fqzEnc error:&err];
        putSeconds(out, @"fqzcomp_nx16_decode", nowSeconds() - t0);

        // ── FQZCOMP_NX16_Z ──
        t0 = nowSeconds();
        NSData *fqzZEnc = [TTIOFqzcompNx16Z encodeWithQualities:qualData
                                                     readLengths:rdLens
                                                    revcompFlags:revcompZ
                                                           error:&err];
        putSeconds(out, @"fqzcomp_nx16_z_encode", nowSeconds() - t0);

        t0 = nowSeconds();
        (void)[TTIOFqzcompNx16Z decodeData:fqzZEnc
                              revcompFlags:revcompZ
                                     error:&err];
        putSeconds(out, @"fqzcomp_nx16_z_decode", nowSeconds() - t0);

        // ── DELTA_RANS: 1.25M sorted int64 positions ──
        const NSUInteger nPos = 1250000;
        NSMutableData *drIn = [NSMutableData dataWithLength:nPos * 8];
        int64_t *dp = (int64_t *)drIn.mutableBytes;
        int64_t dpos = 1000;
        uint64_t ds = 0xBEEFULL;
        for (NSUInteger i = 0; i < nPos; i++) {
            dp[i] = dpos;
            ds = ds * 6364136223846793005ULL + 1442695040888963407ULL;
            int64_t dd = 100 + (int64_t)(((ds >> 32) & 0xFFFFFFFF) % 401);
            dpos += dd;
        }

        t0 = nowSeconds();
        NSData *drEnc = TTIODeltaRansEncode(drIn, 8, &err);
        putSeconds(out, @"delta_rans_encode", nowSeconds() - t0);

        t0 = nowSeconds();
        (void)TTIODeltaRansDecode(drEnc, &err);
        putSeconds(out, @"delta_rans_decode", nowSeconds() - t0);
    }
}
```

Note: Add `#include <CommonCrypto/CommonDigest.h>` at the top for `CC_MD5`. If the ObjC build already links CommonCrypto (it links `-lcrypto`), this may need to use OpenSSL's `MD5()` instead — check which is available. The build script links `-lcrypto` (OpenSSL), so use:

```objc
#include <openssl/md5.h>
```

And replace `CC_MD5(...)` with:

```objc
MD5(refSeqData.bytes, refSeqData.length, refMd5Bytes);
```

- [ ] **Step 3: Register in kBenches**

Add to the `kBenches` array:

```objc
    { "codecs.genomic",    bench_codecs_genomic },
```

- [ ] **Step 4: Run to verify**

```bash
cd ~/TTI-O && ./tools/perf/build_and_run_objc_full.sh --only codecs.genomic
```

Expected: `[codecs.genomic]` section with 8 timing entries.

- [ ] **Step 5: Commit**

```bash
git add tools/perf/profile_objc_full.m
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "perf(v10): ObjC genomic codec benchmarks (B1)"
```

---

### Task 8: ObjC Pipeline + Encryption + Streaming Benchmarks (B2-B6)

**Files:**
- Modify: `tools/perf/profile_objc_full.m`

- [ ] **Step 1: Add genomic + streaming imports**

```objc
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Query/TTIOStreamWriter.h"
#import "Query/TTIOStreamReader.h"
```

- [ ] **Step 2: Add `bench_genomic` function**

```objc
static void bench_genomic(NSString *tmp, NSUInteger n, NSUInteger peaks,
                           NSMutableDictionary *out)
{
    (void)n; (void)peaks;
    @autoreleasepool {
        const NSUInteger nReads = 100000;
        const NSUInteger readLen = 100;
        srand(42);

        // Positions: sorted ascending, LCG deltas 100-500.
        NSMutableData *posData = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
        int64_t *posP = (int64_t *)posData.mutableBytes;
        int64_t pos = 1000;
        uint64_t lcg = 0xBEEFULL;
        for (NSUInteger i = 0; i < nReads; i++) {
            posP[i] = pos;
            lcg = lcg * 6364136223846793005ULL + 1442695040888963407ULL;
            int64_t delta = 100 + (int64_t)(((lcg >> 32) & 0xFFFFFFFF) % 401);
            pos += delta;
        }

        // Flags.
        const int32_t flagVals[] = {0, 16, 83, 99, 163};
        NSMutableData *flagsData = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
        uint32_t *fp = (uint32_t *)flagsData.mutableBytes;
        for (NSUInteger i = 0; i < nReads; i++) fp[i] = (uint32_t)flagVals[rand() % 5];

        // Mapping qualities.
        NSMutableData *mapQData = [NSMutableData dataWithLength:nReads];
        uint8_t *mqp = mapQData.mutableBytes;
        for (NSUInteger i = 0; i < nReads; i++) mqp[i] = (uint8_t)(rand() % 61);

        // Sequences.
        NSUInteger totalBases = nReads * readLen;
        NSMutableData *seqData = [NSMutableData dataWithLength:totalBases];
        uint8_t *sp = seqData.mutableBytes;
        const char acgt[] = "ACGTACGTAC";
        for (NSUInteger i = 0; i < totalBases; i++) {
            sp[i] = (uint8_t)acgt[i % 10];
            if ((rand() % 100) < 2) sp[i] = (uint8_t)"ACGT"[rand() & 3];
        }

        // Qualities (LCG Q20-Q40).
        NSMutableData *qualData = [NSMutableData dataWithLength:totalBases];
        uint8_t *qp = qualData.mutableBytes;
        uint64_t qs = 0xBEEFULL;
        for (NSUInteger i = 0; i < totalBases; i++) {
            qs = qs * 6364136223846793005ULL + 1442695040888963407ULL;
            qp[i] = (uint8_t)(33u + 20u + (uint32_t)((qs >> 32) % 21u));
        }

        // Offsets/lengths.
        NSMutableData *offData = [NSMutableData dataWithLength:nReads * sizeof(uint64_t)];
        NSMutableData *lenData = [NSMutableData dataWithLength:nReads * sizeof(uint32_t)];
        uint64_t *op = (uint64_t *)offData.mutableBytes;
        uint32_t *lp = (uint32_t *)lenData.mutableBytes;
        NSMutableArray *cigars = [NSMutableArray arrayWithCapacity:nReads];
        NSMutableArray *readNames = [NSMutableArray arrayWithCapacity:nReads];
        NSMutableArray *mateChroms = [NSMutableArray arrayWithCapacity:nReads];
        NSMutableData *matePos = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
        NSMutableData *tLens = [NSMutableData dataWithLength:nReads * sizeof(int32_t)];
        int64_t *mpp = (int64_t *)matePos.mutableBytes;
        int32_t *tlp = (int32_t *)tLens.mutableBytes;
        for (NSUInteger i = 0; i < nReads; i++) {
            op[i] = (uint64_t)i * readLen;
            lp[i] = (uint32_t)readLen;
            [cigars addObject:[NSString stringWithFormat:@"%luM", (unsigned long)readLen]];
            [readNames addObject:[NSString stringWithFormat:@"M88_%08lu:001:01", (unsigned long)i]];
            [mateChroms addObject:@"chr1"];
            mpp[i] = posP[i] + 100 + (rand() % 400);
            tlp[i] = (int32_t)(200 + rand() % 300);
        }

        TTIOWrittenGenomicRun *genomicRun = [[TTIOWrittenGenomicRun alloc]
            initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                       referenceUri:@"GRCh38.p14"
                           platform:@"ILLUMINA"
                         sampleName:@"V10-BENCH"
                      positionsData:posData
               mappingQualitiesData:mapQData
                          flagsData:flagsData
                      sequencesData:seqData
                      qualitiesData:qualData
                        offsetsData:offData
                        lengthsData:lenData
                             cigars:cigars
                          readNames:readNames
                   mateChromosomes:mateChroms
                  matePositionsData:matePos
                templateLengthsData:tLens
                        chromosomes:@[@"chr1"]];

        NSString *tioPath = [tmp stringByAppendingPathComponent:@"genomic-bench.tio"];
        NSError *err = nil;

        // B2: write
        double t0 = nowSeconds();
        BOOL ok = [TTIOSpectralDataset writeMinimalToPath:tioPath
                                                     title:@"v10-bench"
                                       isaInvestigationId:@"ISA-V10"
                                                   msRuns:nil
                                             genomicRuns:@{@"bench": genomicRun}
                                           identifications:nil
                                           quantifications:nil
                                         provenanceRecords:nil
                                                     error:&err];
        if (!ok) { NSLog(@"genomic write failed: %@", err); return; }
        putSeconds(out, @"write", nowSeconds() - t0);
        long rawBytes = (long)(seqData.length + qualData.length +
                               posData.length + flagsData.length + mapQData.length);
        putSeconds(out, @"write_mb", rawBytes / 1e6);

        // B3: sequential read
        t0 = nowSeconds();
        TTIOSpectralDataset *ds =
            [TTIOSpectralDataset readFromFilePath:tioPath error:&err];
        if (!ds) { NSLog(@"genomic read open failed: %@", err); return; }
        TTIOGenomicRun *run = ds.genomicRuns[@"bench"];
        NSUInteger readCount = run.readCount;
        for (NSUInteger i = 0; i < readCount; i++) {
            (void)[run readAtIndex:i error:&err];
        }
        [ds closeFile];
        putSeconds(out, @"read", nowSeconds() - t0);

        // B4: random access — 1000 reads
        srand(99);
        ds = [TTIOSpectralDataset readFromFilePath:tioPath error:&err];
        run = ds.genomicRuns[@"bench"];
        double latencies[1000];
        for (int i = 0; i < 1000; i++) {
            NSUInteger idx = (NSUInteger)(rand() % nReads);
            double lt0 = nowSeconds();
            (void)[run readAtIndex:idx error:&err];
            latencies[i] = nowSeconds() - lt0;
        }
        [ds closeFile];

        // Sort for percentiles.
        for (int i = 0; i < 999; i++) {
            for (int j = i + 1; j < 1000; j++) {
                if (latencies[j] < latencies[i]) {
                    double t = latencies[i];
                    latencies[i] = latencies[j];
                    latencies[j] = t;
                }
            }
        }
        putSeconds(out, @"random_access_p50", latencies[500]);
        putSeconds(out, @"random_access_p99", latencies[990]);
    }
}
```

- [ ] **Step 3: Add `bench_encryption_genomic` function**

```objc
static void bench_encryption_genomic(NSString *tmp, NSUInteger n, NSUInteger peaks,
                                      NSMutableDictionary *out)
{
    (void)tmp; (void)n; (void)peaks;
    @autoreleasepool {
        const NSUInteger payloadSize = 10 * 1024 * 1024; // 10 MiB
        srand(42);
        NSMutableData *payload = [NSMutableData dataWithLength:payloadSize];
        uint8_t *pp = payload.mutableBytes;
        for (NSUInteger i = 0; i < payloadSize; i++) pp[i] = (uint8_t)rand();

        uint8_t keyBytes[32];
        for (int i = 0; i < 32; i++) keyBytes[i] = (uint8_t)i;
        NSData *key = [NSData dataWithBytes:keyBytes length:32];

        NSError *err = nil;
        NSData *iv = nil, *tag = nil;

        double t0 = nowSeconds();
        NSData *ct = [TTIOEncryptionManager encryptData:payload
                                                withKey:key
                                                     iv:&iv
                                                authTag:&tag
                                                  error:&err];
        putSeconds(out, @"encrypt", nowSeconds() - t0);

        t0 = nowSeconds();
        (void)[TTIOEncryptionManager decryptData:ct
                                          withKey:key
                                              iv:iv
                                         authTag:tag
                                           error:&err];
        putSeconds(out, @"decrypt", nowSeconds() - t0);
        putSeconds(out, @"bytes_mb", payloadSize / 1e6);
    }
}
```

- [ ] **Step 4: Add `bench_streaming` function**

```objc
static void bench_streaming(NSString *tmp, NSUInteger n, NSUInteger peaks,
                              NSMutableDictionary *out)
{
    @autoreleasepool {
        NSString *srcPath = [tmp stringByAppendingPathComponent:@"stream-src.tio"];
        NSString *tisPath = [tmp stringByAppendingPathComponent:@"streaming-bench.tis"];
        TTIOWrittenRun *run = buildMsRun(n, peaks);
        NSError *err = nil;

        if (![TTIOSpectralDataset writeMinimalToPath:srcPath
                                                 title:@"stream-bench"
                                   isaInvestigationId:@"ISA-STREAM"
                                               msRuns:@{@"r": run}
                                       identifications:nil
                                       quantifications:nil
                                     provenanceRecords:nil
                                                 error:&err]) {
            NSLog(@"streaming src write failed: %@", err); return;
        }

        TTIOSpectralDataset *ds =
            [TTIOSpectralDataset readFromFilePath:srcPath error:&err];
        TTIOAcquisitionRun *r = ds.msRuns[@"r"];

        // Write .tis
        double t0 = nowSeconds();
        TTIOStreamWriter *writer = [[TTIOStreamWriter alloc]
            initWithFilePath:tisPath
                     runName:@"r"
             acquisitionMode:TTIOAcquisitionModeMS1DDA
            instrumentConfig:nil
                       error:&err];
        for (NSUInteger i = 0; i < n; i++) {
            [writer appendSpectrum:[r objectAtIndex:i] error:&err];
        }
        [writer flushAndCloseWithError:&err];
        putSeconds(out, @"write", nowSeconds() - t0);
        [ds closeFile];

        // Read .tis
        t0 = nowSeconds();
        TTIOStreamReader *reader = [[TTIOStreamReader alloc]
            initWithFilePath:tisPath runName:@"r" error:&err];
        NSUInteger count = 0;
        while (![reader atEnd]) {
            (void)[reader nextSpectrumWithError:&err];
            count++;
        }
        [reader close];
        putSeconds(out, @"read", nowSeconds() - t0);
    }
}
```

- [ ] **Step 5: Register all three in kBenches**

```objc
    { "codecs.genomic",       bench_codecs_genomic },
    { "genomic",              bench_genomic },
    { "encryption.genomic",   bench_encryption_genomic },
    { "streaming",            bench_streaming },
```

- [ ] **Step 6: Run to verify**

```bash
cd ~/TTI-O && ./tools/perf/build_and_run_objc_full.sh --only genomic,encryption.genomic,streaming
```

Expected: Three sections with timings.

- [ ] **Step 7: Commit**

```bash
git add tools/perf/profile_objc_full.m
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "perf(v10): ObjC genomic pipeline + encryption + streaming benchmarks (B2-B6)"
```

---

### Task 9: Capture Initial Baselines (B7)

**Files:**
- Modify: `tools/perf/baseline.json`

- [ ] **Step 1: Run the full Python harness and capture**

```bash
cd ~/TTI-O && python3 tools/perf/profile_python_full.py \
  --only codecs.genomic,genomic,encryption.genomic,streaming \
  --json tools/perf/_out_python_full/full_v10.json
```

- [ ] **Step 2: Run the full Java harness and capture**

```bash
cd ~/TTI-O && mvn -f java/pom.xml compile -q && \
  java -cp "java/target/classes:$(cat java/target/runtime-classpath.txt)" \
    tools.perf.ProfileHarnessFull \
    --only codecs.genomic,genomic,encryption.genomic,streaming \
    --json tools/perf/_out_java_full/full_v10.json
```

- [ ] **Step 3: Run the full ObjC harness and capture**

```bash
cd ~/TTI-O && ./tools/perf/build_and_run_objc_full.sh \
  --only codecs.genomic,genomic,encryption.genomic,streaming \
  --json tools/perf/_out_objc_full/full_v10.json
```

- [ ] **Step 4: Merge into baseline.json**

Manually add the new keys from each `full_v10.json` into `tools/perf/baseline.json` under the appropriate language section. The keys should be nested under the benchmark group name (e.g., `"codecs.genomic": {"ref_diff_encode": 1.23, ...}`).

Alternatively, run the full sweep with `--update-baseline`:

```bash
cd ~/TTI-O && tools/perf/run_perf_ci.sh --update-baseline
```

This runs all benchmarks (old + new) and overwrites `baseline.json` with fresh numbers.

- [ ] **Step 5: Verify regression detection works**

```bash
cd ~/TTI-O && tools/perf/run_perf_ci.sh --skip-java --skip-objc
```

Expected: All new metrics appear in the Markdown table with `OK` verdicts (since baseline was just captured).

- [ ] **Step 6: Commit**

```bash
git add tools/perf/baseline.json
git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "perf(v10): capture initial baselines for genomic + streaming benchmarks (B7)"
```
