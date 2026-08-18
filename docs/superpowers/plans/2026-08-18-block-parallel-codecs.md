# Block-Parallel Codecs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The genomic and MS stream writers and the sequential readers in Python, Java and ObjC encode and decode several `blocks_v1` / FDZ blocks at once, byte for byte identical to the one-thread output, under one knob (`TTIO_THREADS`, `threads=`, `--threads`) and a bounded in-flight window.

**Architecture:** Each SDK keeps its runtime pool (Python `ThreadPoolExecutor`, Java `ExecutorService`, ObjC `NSOperationQueue`). Writers do the ordered work (chromosome ids, reference md5, sequence number) on the caller's thread, submit `encode_block` to the pool, and append completed blocks in sequence order from the caller's thread with at most `threads + 1` blocks in flight. Sequential readers materialise the raw blob bytes of the next `threads` blocks on the caller's thread and decode them on the pool. The C kernel gains one process-global setter so its own auto-tune threads stand down inside a pool.

**Tech Stack:** Python 3.12 (`concurrent.futures`, ctypes), Java 21+ (`java.util.concurrent`), ObjC/GNUstep (`NSOperationQueue`, `NSCondition`), C11 + pthreads in `native/`, HDF5 through the storage providers (single-threaded by construction).

**Spec:** `docs/superpowers/specs/2026-08-18-block-parallel-codecs-design.md`

## Global Constraints

- All commands run in WSL Ubuntu in the worktree `/home/toddw/TTI-O.worktrees/block-parallel` (branch `block-parallel-codecs`, off main after #299). Python is `/home/toddw/TTI-O/python/.venv/bin/python` (`PY` below): the venv is an editable install of `/home/toddw/TTI-O/python/src`, so Python tests of this worktree run with `PYTHONPATH` unset and the module loaded from a path: every Python test step below sets `TTIO_SRC=/home/toddw/TTI-O.worktrees/block-parallel/python/src` and runs `cd $TTIO_SRC/.. && $PY -m pytest` after `pip install -e` of the worktree is NOT possible; instead run tests as `cd /home/toddw/TTI-O.worktrees/block-parallel/python && $PY -c "import sys; sys.path.insert(0, 'src'); import pytest; sys.exit(pytest.main([...]))"` — abbreviated below as `$PYT <args>` with `PYT='$PY -c "import sys,pytest; sys.path.insert(0,\"src\"); sys.exit(pytest.main(sys.argv[1:]))"'`. (The main tree is running the compression benchmark and must not be switched.)
- Native library: build in the worktree with `cmake -S native -B native/_build -DTTIO_RANS_BUILD_JNI=ON && cmake --build native/_build -j8`; Python tests export `TTIO_RANS_LIB_PATH=/home/toddw/TTI-O.worktrees/block-parallel/native/_build/libttio_rans.so`; Java tests pass `-Dhdf5.native.path=/usr/local/lib:/home/toddw/TTI-O.worktrees/block-parallel/native/_build`; ObjC builds against `../../native/_build` by its GNUmakefile.
- `TTIO_THREADS`: unset or `0` = `max(1, os.cpu_count() - 8)`; `1` = the serial code path with no executor; N = pool size. Same semantics in all three SDKs.
- Window: at most `threads + 1` blocks pending or encoding in a writer; `threads` blocks decoding ahead in a reader.
- Output identity: files written with `threads=1` and `threads>1` are byte for byte identical; every task that touches a writer ends with such a test.
- HDF5 and the storage providers are only ever called from the caller's thread.
- Commit messages: plain subject, no bullets, no attribution trailers.

---

### Task 1: Kernel setter for the auto-tune threads

**Files:**
- Modify: `native/src/m94z_qual.c` (the auto-tune from #299)
- Modify: `native/include/ttio_rans.h`
- Modify: `native/src/ttio_rans_jni.c`
- Modify: `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java`
- Modify: `python/src/ttio/codecs/fqzcomp_nx16_z.py`
- Modify: `native/tests/test_fqzcomp_qual_autotune.c`
- Test: `python/tests/test_qualities_v5.py`

**Interfaces:**
- Produces (C): `void ttio_m94z_set_autotune_threads(int n)` and `int ttio_m94z_get_autotune_threads(void)`; process-global; initial value 1 when `TTIO_M94Z_SEQUENTIAL=1` is set at first use, else 3; any `n <= 1` means sequential.
- Produces (Python): `ttio.codecs.fqzcomp_nx16_z.set_autotune_threads(n: int) -> None`, `get_autotune_threads() -> int`.
- Produces (Java): `FqzcompNx16Z.setAutotuneThreads(int n)`, `FqzcompNx16Z.getAutotuneThreads()`.
- ObjC calls the C function directly (`ttio_rans.h` is included by the writers' translation units already through `TTIOFqzcomp*`); no wrapper.

- [ ] **Step 1: Write the failing C test**

Append to `native/tests/test_fqzcomp_qual_autotune.c` before `int main`:

```c
static int test_autotune_threads_setter(void) {
    int initial = ttio_m94z_get_autotune_threads();
    if (initial != 3 && initial != 1) { fprintf(stderr, "initial %d\n", initial); return 1; }
    ttio_m94z_set_autotune_threads(1);
    if (ttio_m94z_get_autotune_threads() != 1) return 1;
    ttio_m94z_set_autotune_threads(0);   /* <= 1 clamps to 1 */
    if (ttio_m94z_get_autotune_threads() != 1) return 1;
    ttio_m94z_set_autotune_threads(3);
    if (ttio_m94z_get_autotune_threads() != 3) return 1;
    printf("autotune threads setter: PASS\n");
    return 0;
}
```

and `if (test_autotune_threads_setter() != 0) return 1;` as the first line of `main`.

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel && cmake --build native/_build -j8 2>&1 | grep -E "error" | head -3`
Expected: `implicit declaration of function 'ttio_m94z_get_autotune_threads'`.

- [ ] **Step 3: Implement the setter in the kernel**

In `native/include/ttio_rans.h`, after the `ttio_m94z_qual_encode` prototype:

```c
/* Threads the FQZCOMP auto-tune uses for its V4/S5/S6 candidate encodes
 * (default 3; <= 1 runs them in sequence). Process-global; the initial
 * value is 1 when TTIO_M94Z_SEQUENTIAL=1 is set. A caller that already
 * runs blocks on a pool sets 1 for the life of the pool. */
void ttio_m94z_set_autotune_threads(int n);
int  ttio_m94z_get_autotune_threads(void);
```

In `native/src/m94z_qual.c`, replace the environment read inside `ttio_m94z_qual_encode`:

```c
static int g_autotune_threads = -1;   /* -1: not initialised */
static pthread_mutex_t g_autotune_lock = PTHREAD_MUTEX_INITIALIZER;

static int autotune_threads(void) {
    pthread_mutex_lock(&g_autotune_lock);
    if (g_autotune_threads < 0) {
        const char *e = getenv("TTIO_M94Z_SEQUENTIAL");
        g_autotune_threads = (e && e[0] == '1') ? 1 : 3;
    }
    int n = g_autotune_threads;
    pthread_mutex_unlock(&g_autotune_lock);
    return n;
}

void ttio_m94z_set_autotune_threads(int n) {
    pthread_mutex_lock(&g_autotune_lock);
    g_autotune_threads = n <= 1 ? 1 : 3;
    pthread_mutex_unlock(&g_autotune_lock);
}

int ttio_m94z_get_autotune_threads(void) { return autotune_threads(); }
```

and in the auto-tune body change

```c
    const char *seq_env = getenv("TTIO_M94Z_SEQUENTIAL");
    int sequential = seq_env && seq_env[0] == '1';
```

to

```c
    int sequential = autotune_threads() <= 1;
```

- [ ] **Step 4: Run the C tests**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel && cmake --build native/_build -j8 2>&1 | grep -E "error" ; cd native/_build && ctest 2>&1 | tail -2`
Expected: `100% tests passed`.

- [ ] **Step 5: Python and Java bindings**

`python/src/ttio/codecs/fqzcomp_nx16_z.py`, next to the other ctypes prototypes (find `_lib = load_ttio_rans()` or the module's loader call and add after it):

```python
def set_autotune_threads(n: int) -> None:
    """Threads the FQZCOMP auto-tune uses for its candidate encodes
    (default 3; <= 1 runs them in sequence). A writer or reader that runs
    blocks on its own pool sets 1 while the pool exists."""
    lib = load_ttio_rans()
    if lib is None:
        return
    lib.ttio_m94z_set_autotune_threads.argtypes = [ctypes.c_int]
    lib.ttio_m94z_set_autotune_threads.restype = None
    lib.ttio_m94z_set_autotune_threads(int(n))


def get_autotune_threads() -> int:
    lib = load_ttio_rans()
    if lib is None:
        return 1
    lib.ttio_m94z_get_autotune_threads.restype = ctypes.c_int
    return int(lib.ttio_m94z_get_autotune_threads())
```

`native/src/ttio_rans_jni.c`, next to the existing `Java_global_thalion_ttio_codecs_FqzcompNx16Z_*` functions:

```c
JNIEXPORT void JNICALL
Java_global_thalion_ttio_codecs_FqzcompNx16Z_setAutotuneThreadsInternal(JNIEnv *env, jclass cls, jint n)
{
    (void)env; (void)cls;
    ttio_m94z_set_autotune_threads((int)n);
}

JNIEXPORT jint JNICALL
Java_global_thalion_ttio_codecs_FqzcompNx16Z_getAutotuneThreadsInternal(JNIEnv *env, jclass cls)
{
    (void)env; (void)cls;
    return (jint)ttio_m94z_get_autotune_threads();
}
```

`FqzcompNx16Z.java`, next to the other `native` declarations:

```java
    private static native void setAutotuneThreadsInternal(int n);
    private static native int getAutotuneThreadsInternal();

    /** Threads the FQZCOMP auto-tune uses for its candidate encodes
     *  (default 3; {@code n <= 1} runs them in sequence). No-op when the
     *  native library is absent. */
    public static void setAutotuneThreads(int n) {
        if (isAvailable()) setAutotuneThreadsInternal(n);
    }

    public static int getAutotuneThreads() {
        return isAvailable() ? getAutotuneThreadsInternal() : 1;
    }
```

- [ ] **Step 6: Python test**

Append to `python/tests/test_qualities_v5.py`:

```python
def test_autotune_threads_setter_round_trips():
    from ttio.codecs import fqzcomp_nx16_z as fz
    from ttio.codecs._native_loader import load_ttio_rans
    if load_ttio_rans() is None:
        pytest.skip("native lib")
    before = fz.get_autotune_threads()
    try:
        fz.set_autotune_threads(1)
        assert fz.get_autotune_threads() == 1
        fz.set_autotune_threads(3)
        assert fz.get_autotune_threads() == 3
    finally:
        fz.set_autotune_threads(before)
```

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/python && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O.worktrees/block-parallel/native/_build/libttio_rans.so $PYT tests/test_qualities_v5.py -q`
Expected: all pass, including the new one.

- [ ] **Step 7: Java compile check and commit**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/java && mvn -q -o test -Dhdf5.native.path=/usr/local/lib:/home/toddw/TTI-O.worktrees/block-parallel/native/_build -Dtest=QualitiesV5Test -Dsurefire.failIfNoSpecifiedTests=false 2>&1 | grep -E "Tests run|ERROR" | head -3`
Expected: `Tests run: 9, Failures: 0, Errors: 0`.

```bash
git add native/include/ttio_rans.h native/src/m94z_qual.c native/src/ttio_rans_jni.c native/tests/test_fqzcomp_qual_autotune.c java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java python/src/ttio/codecs/fqzcomp_nx16_z.py python/tests/test_qualities_v5.py
git commit -m "codecs: process-global setter for the FQZCOMP auto-tune threads"
```

---

### Task 2: Python thread knob and CLI flag

**Files:**
- Create: `python/src/ttio/_threads.py`
- Modify: `python/src/ttio/tools/workbench_cli.py` (encode and export parsers)
- Test: `python/tests/test_threads.py`

**Interfaces:**
- Produces: `ttio._threads.resolve_threads(explicit: int | None = None) -> int` — `explicit` wins when not None and > 0; else `TTIO_THREADS`; unset/0 → `max(1, cpu_count - 8)`; never below 1.
- Produces: `ttio._threads.pool_context(threads: int)` — a context manager that, for `threads > 1`, calls `fqzcomp_nx16_z.set_autotune_threads(1)` on entry and restores the previous value on exit; for `threads == 1` it is a no-op. Reference-counted, so nested writers/readers share it.
- Produces: `--threads N` on `ttio encode` and `ttio export`; the CLI sets `os.environ["TTIO_THREADS"] = str(N)` before dispatch (the writers and readers resolve from the environment).

- [ ] **Step 1: Write the failing tests**

```python
# python/tests/test_threads.py
import os
import pytest
from ttio import _threads


def test_resolve_threads_precedence(monkeypatch):
    monkeypatch.delenv("TTIO_THREADS", raising=False)
    monkeypatch.setattr(os, "cpu_count", lambda: 32)
    assert _threads.resolve_threads() == 24
    monkeypatch.setattr(os, "cpu_count", lambda: 4)
    assert _threads.resolve_threads() == 1
    monkeypatch.setenv("TTIO_THREADS", "0")
    assert _threads.resolve_threads() == 1
    monkeypatch.setenv("TTIO_THREADS", "6")
    assert _threads.resolve_threads() == 6
    assert _threads.resolve_threads(2) == 2
    assert _threads.resolve_threads(0) == 6
    monkeypatch.setenv("TTIO_THREADS", "junk")
    assert _threads.resolve_threads() == 1


def test_pool_context_stands_down_the_autotune(monkeypatch):
    calls = []
    monkeypatch.setattr(_threads, "_get_autotune", lambda: 3)
    monkeypatch.setattr(_threads, "_set_autotune", lambda n: calls.append(n))
    with _threads.pool_context(1):
        pass
    assert calls == []
    with _threads.pool_context(4):
        with _threads.pool_context(2):
            assert calls == [1]
        assert calls == [1]
    assert calls == [1, 3]


def test_cli_threads_flag_sets_env(monkeypatch, tmp_path):
    from ttio.tools.workbench_cli import main
    monkeypatch.delenv("TTIO_THREADS", raising=False)
    fq = tmp_path / "in.fastq"
    fq.write_text("@r1\nACGT\n+\nIIII\n")
    assert main(["encode", "--input", str(fq), "--format", "fastq",
                 "--output", str(tmp_path / "o.tio"), "--threads", "3"]) == 0
    assert os.environ["TTIO_THREADS"] == "3"
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/python && $PYT tests/test_threads.py -q`
Expected: FAIL (`No module named 'ttio._threads'`).

- [ ] **Step 3: Implement `_threads.py`**

```python
# python/src/ttio/_threads.py
"""The one thread knob of the SDK.

``TTIO_THREADS`` unset or 0 means ``max(1, cpu_count - 8)``; ``1`` is the
serial path with no executor; N is the pool size. ``threads=`` on a
writer or reader overrides the environment for that object.
"""
from __future__ import annotations

import contextlib
import os
import threading


def resolve_threads(explicit: int | None = None) -> int:
    if explicit is not None and int(explicit) > 0:
        return int(explicit)
    raw = os.environ.get("TTIO_THREADS", "").strip()
    try:
        n = int(raw) if raw else 0
    except ValueError:
        n = 1
    if n <= 0:
        n = max(1, (os.cpu_count() or 1) - 8)
    return n


def _get_autotune() -> int:
    from .codecs.fqzcomp_nx16_z import get_autotune_threads
    return get_autotune_threads()


def _set_autotune(n: int) -> None:
    from .codecs.fqzcomp_nx16_z import set_autotune_threads
    set_autotune_threads(n)


_lock = threading.Lock()
_depth = 0
_saved: int | None = None


@contextlib.contextmanager
def pool_context(threads: int):
    """While a pool of more than one worker exists, the FQZCOMP auto-tune
    runs its candidates in sequence (three threads per worker would
    oversubscribe the machine). Reference-counted across nested pools."""
    global _depth, _saved
    if threads <= 1:
        yield
        return
    with _lock:
        if _depth == 0:
            _saved = _get_autotune()
            _set_autotune(1)
        _depth += 1
    try:
        yield
    finally:
        with _lock:
            _depth -= 1
            if _depth == 0 and _saved is not None:
                _set_autotune(_saved)
                _saved = None
```

- [ ] **Step 4: CLI flag**

In `workbench_cli.py`, where the `encode` and `export` sub-parsers are built (`pe = sub.add_parser("encode", ...)` near line 915 and `px = sub.add_parser("export", ...)` near line 947), add to both:

```python
    p_.add_argument("--threads", type=int, default=None,
                    help="worker threads for block encode/decode (default: "
                         "TTIO_THREADS, else cores minus 8; 1 = serial)")
```

(`p_` is the parser variable of that block.) In `cmd_encode` and `cmd_export`, as the first statement:

```python
    if getattr(args, "threads", None) is not None:
        os.environ["TTIO_THREADS"] = str(int(args.threads))
```

(`os` is already imported in the module; if not, add `import os`.)

- [ ] **Step 5: Run tests**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/python && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O.worktrees/block-parallel/native/_build/libttio_rans.so $PYT tests/test_threads.py -q`
Expected: 3 passed.

- [ ] **Step 6: Commit**

```bash
git add python/src/ttio/_threads.py python/src/ttio/tools/workbench_cli.py python/tests/test_threads.py
git commit -m "python: TTIO_THREADS knob, --threads on encode and export"
```

---

### Task 3: Python GenomicStreamWriter encodes blocks on a pool

**Files:**
- Modify: `python/src/ttio/genomic/stream_writer.py`
- Modify: `python/src/ttio/genomic/lazy_reference.py` (lock around the LRU cache)
- Modify: `python/src/ttio/importers/import_result.py` (`write_into` passes `threads`)
- Modify: `python/src/ttio/spectral_dataset.py` (`_write_genomic_run_default` passes `threads` from the run's `threads` if present, else resolves)
- Test: `python/tests/test_genomic_stream_writer.py`

**Interfaces:**
- Consumes: `ttio._threads.resolve_threads`, `pool_context` (Task 2).
- Produces: `GenomicStreamWriter(..., threads: int | None = None)`; `register_block_chromosomes(block, chrom_map)` in `stream_writer.py` — assigns ids for every own chromosome name of the block in read order (`'*'` included) and then every mate chromosome name that is not `''`, `'*'` or `'='`, exactly the order the block encoder assigns them, so the encoder never writes the map.
- Produces: `GenomicStreamWriter.threads` property.

- [ ] **Step 1: Write the failing tests**

Append to `python/tests/test_genomic_stream_writer.py`:

```python
def _big_synthetic_run(n=60_000, seed=7):
    """A synthetic run over two chromosomes with placed-unmapped reads and
    cross-chromosome mates, big enough for several 20k-read blocks."""
    from ttio.written_genomic_run import WrittenGenomicRun
    rng = np.random.default_rng(seed)
    L = 100
    ref = {"chr1": bytes(rng.choice(list(b"ACGT"), 400_000)),
           "chr2": bytes(rng.choice(list(b"ACGT"), 400_000))}
    chroms = ["chr1"] * (n // 2) + ["chr2"] * (n - n // 2)
    positions = np.concatenate([np.sort(rng.integers(1, 399_000, n // 2)),
                                np.sort(rng.integers(1, 399_000, n - n // 2))]).astype(np.int64)
    seqs = bytearray()
    cigars, flags, mates, mpos = [], np.full(n, 0x3, dtype=np.uint32), [], np.full(n, -1, dtype=np.int64)
    for i in range(n):
        s = bytearray(ref[chroms[i]][positions[i] - 1:positions[i] - 1 + L])
        for k in rng.integers(0, L, 3):
            s[k] = ord("ACGT"[rng.integers(0, 4)])
        seqs.extend(s)
        if i % 97 == 0:
            cigars.append("*"); flags[i] = 0x5
        else:
            cigars.append(f"{L}M")
        if i % 13 == 0:
            mates.append("chr2" if chroms[i] == "chr1" else "chr1"); mpos[i] = int(positions[(i * 7) % n])
        elif i % 3 == 0:
            mates.append("="); mpos[i] = int(positions[i]) + 200
        else:
            mates.append("")
    return WrittenGenomicRun(
        acquisition_mode=7, reference_uri="synthetic", platform="ILLUMINA", sample_name="s",
        positions=positions, mapping_qualities=np.full(n, 60, dtype=np.uint8), flags=flags,
        sequences=np.frombuffer(bytes(seqs), dtype=np.uint8),
        qualities=np.frombuffer(bytes(rng.integers(2, 40, n * L, dtype=np.uint8)), dtype=np.uint8),
        offsets=(np.arange(n) * L).astype(np.uint64), lengths=np.full(n, L, dtype=np.uint32),
        cigars=cigars, read_names=[f"r{i:06d}" for i in range(n)],
        mate_chromosomes=mates, mate_positions=mpos,
        template_lengths=np.zeros(n, dtype=np.int32), chromosomes=chroms,
        reference_chrom_seqs=ref, embed_reference=True,
    )


def _write_with_threads(tmp_path, run, threads, block_reads=20_000):
    from ttio.spectral_dataset import SpectralDataset
    out = tmp_path / f"t{threads}.tio"
    root = Hdf5Provider.create(str(out)).root_group()
    study = root.create_group("study")
    with GenomicStreamWriter(study, "g", acquisition_mode=7, reference_uri="synthetic",
                             platform="ILLUMINA", sample_name="s",
                             reference_chrom_seqs=run.reference_chrom_seqs, embed_reference=True,
                             block_reads=block_reads, threads=threads) as w:
        # feed in uneven batches so blocks are cut inside batches
        n = int(len(run.lengths))
        for a in range(0, n, 7_001):
            w.append_batch(_blocks.slice_run(run, a, min(n, a + 7_001)))
        assert w.threads == threads
    root.close()
    return out


def _run_bytes(path):
    """Every genomic dataset's raw bytes and every attribute, in a stable
    order: the identity contract between the serial and threaded writer."""
    import h5py
    out = {}
    with h5py.File(path, "r") as f:
        def visit(name, obj):
            if name.startswith("study/genomic_runs") or name.startswith("study/references"):
                attrs = {k: (v.tobytes() if hasattr(v, "tobytes") else v) for k, v in obj.attrs.items()}
                data = obj[()].tobytes() if isinstance(obj, h5py.Dataset) and obj.shape != () else None
                out[name] = (attrs, data)
        f.visititems(visit)
    return out


def test_threaded_writer_is_byte_identical_to_serial(tmp_path):
    from ttio.codecs import ref_diff_v2 as rdv2
    if not rdv2.HAVE_NATIVE_LIB:
        pytest.skip("native lib")
    run = _big_synthetic_run()
    a = _write_with_threads(tmp_path, run, 1)
    b = _write_with_threads(tmp_path, run, 6)
    ba, bb = _run_bytes(a), _run_bytes(b)
    assert ba.keys() == bb.keys()
    for k in ba:
        assert ba[k] == bb[k], f"{k} differs between threads=1 and threads=6"
    with SpectralDataset.open(b) as ds:
        g = ds.genomic_runs["g"]
        assert len(g) == 60_000
        assert g.layout == "blocks_v1" and g.block_count == 3
        assert g[96].cigar == "*"
        assert g[59_999].sequence == run.sequences.tobytes()[59_999 * 100:].decode()


def test_register_block_chromosomes_matches_the_encoder_order():
    from ttio.genomic.stream_writer import register_block_chromosomes
    m = {}
    register_block_chromosomes(_mini(["chr2", "*", "chr2"], ["chr1", "*", "="]), m)
    assert m == {"chr2": 0, "*": 1, "chr1": 2}
    register_block_chromosomes(_mini(["chr3"], ["chr2"]), m)
    assert m == {"chr2": 0, "*": 1, "chr1": 2, "chr3": 3}


def _mini(chroms, mates):
    return make_written_genomic_run(n=len(chroms), chromosomes=chroms, mate_chromosomes=mates)


def test_threads_default_and_window(monkeypatch, tmp_path):
    monkeypatch.setenv("TTIO_THREADS", "4")
    root = Hdf5Provider.create(str(tmp_path / "w.tio")).root_group()
    w = GenomicStreamWriter(root.create_group("study"), "g", acquisition_mode=7,
                            reference_uri="", platform="", sample_name="")
    assert w.threads == 4 and w._window == 5
    w.close(); root.close()
```

If `make_written_genomic_run` in `python/tests/_genomic_fixture.py` does not accept `chromosomes=`/`mate_chromosomes=` keyword overrides, extend it (it builds a `WrittenGenomicRun`; add the two keywords with defaults equal to what it builds today).

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/python && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O.worktrees/block-parallel/native/_build/libttio_rans.so $PYT tests/test_genomic_stream_writer.py -q -k "threaded or register or window"`
Expected: FAIL (`unexpected keyword argument 'threads'` / `cannot import name 'register_block_chromosomes'`).

- [ ] **Step 3: Lock the LazyReference cache**

In `python/src/ttio/genomic/lazy_reference.py`, `__init__`: add `self._lock = threading.Lock()` (import `threading`), and wrap the body of `__getitem__` after the `if name not in self._entries: raise KeyError` check in `with self._lock:` (the cache lookup, the file read, the cache insert and the eviction). `set_md5` also takes the lock around its sidecar read/write and digest.

- [ ] **Step 4: Implement the pooled writer**

In `stream_writer.py`:

Imports: `import concurrent.futures as _cf`, `from .._threads import resolve_threads, pool_context`.

Add the module-level helper (above the class):

```python
def register_block_chromosomes(block: WrittenGenomicRun, chrom_map: dict) -> None:
    """Assign ids for every chromosome name the block introduces, in the
    order the block encoder assigns them (own names in read order, '*'
    included, then mate names that are not '', '*' or '='), so the
    encoder only reads the map and blocks can encode concurrently."""
    for name in block.chromosomes:
        if name not in chrom_map:
            chrom_map[name] = len(chrom_map)
    for name in block.mate_chromosomes:
        if name and name not in ("*", "=") and name not in chrom_map:
            chrom_map[name] = len(chrom_map)
```

Constructor: add parameter `threads: int | None = None`; body:

```python
        self._threads = resolve_threads(threads)
        self._window = self._threads + 1
        self._pool = None
        self._pool_ctx = None
        self._inflight: list[tuple[WrittenGenomicRun, "_cf.Future"]] = []
        if self._threads > 1:
            self._pool_ctx = pool_context(self._threads)
            self._pool_ctx.__enter__()
            self._pool = _cf.ThreadPoolExecutor(max_workers=self._threads,
                                                thread_name_prefix="ttio-block-encode")
```

Property:

```python
    @property
    def threads(self) -> int:
        return self._threads
```

Replace `flush` with:

```python
    def flush(self) -> None:
        """Encode and write the pending reads as one block. With more than
        one thread the encode runs on the pool and the block is written,
        in order, by a later flush or by close."""
        if self._legacy or not self._pending:
            return
        block = _blocks.concat_runs(self._pending)
        self._pending = []
        self._pending_reads = 0
        self._pending_bytes = 0
        if self._reference_md5 is None and self._meta["reference_chrom_seqs"] is not None:
            from .._dataset_write_genomic import _reference_md5_for_run
            probe = _apply_meta(block, self._meta, None)
            self._reference_md5 = _reference_md5_for_run(probe)
        register_block_chromosomes(block, self._chrom_map)
        block = _apply_meta(block, self._meta, self._chrom_map, self._reference_md5)
        if not self._embedded and self._meta["embed_reference"]:
            from .._dataset_write_genomic import _embed_references_for_runs
            _embed_references_for_runs(self._study, {self._name: block})
            self._embedded = True
        if self._pool is None:
            self._write_encoded(block, _blocks.encode_block(block))
            return
        self._drain(block_until=self._window - 1)
        self._inflight.append((block, self._pool.submit(_blocks.encode_block, block)))

    def _drain(self, block_until: int) -> None:
        """Write completed blocks in sequence order; wait on the oldest
        until at most ``block_until`` remain in flight."""
        while self._inflight and (len(self._inflight) > block_until or self._inflight[0][1].done()):
            block, fut = self._inflight.pop(0)
            self._write_encoded(block, fut.result())

    def _write_encoded(self, block: WrittenGenomicRun, blobs: _blocks.BlockBlobs) -> None:
        self._ensure_layout(blobs)
        row = {"read_start": self._read_count, "n_reads": blobs.n_reads,
               "base_start": self._base_count, "n_bases": blobs.n_bases}
        for ch in _blocks.BLOCK_CHANNELS:
            data = blobs.blobs[ch]
            ds = self._ds.get(ch)
            row[f"{ch}_codec"] = int(blobs.compression[ch])
            if ds is None:
                if data:
                    ds = self._create_channel(ch, blobs)
                else:
                    row[f"{ch}_off"] = 0
                    row[f"{ch}_len"] = 0
                    continue
            row[f"{ch}_off"] = int(ds.length)
            row[f"{ch}_len"] = len(data)
            if data:
                ds.append(np.frombuffer(data, dtype=np.uint8))
        self._index.append([row])
        self._append_index_arrays(block)
        self._read_count += blobs.n_reads
        self._base_count += blobs.n_bases
        self._block_count += 1
        io.write_int_attr(self._rg, "read_count", self._read_count)
        io.write_int_attr(self._rg, "base_count", self._base_count)
```

(`_write_encoded` is the former tail of `flush`, unchanged.) In `close`, after `self.flush()` add `self._drain(block_until=0)` and, at the very end of `close` (both branches; use a `finally`), shut the pool:

```python
    def _shutdown_pool(self) -> None:
        if self._pool is not None:
            self._pool.shutdown(wait=True)
            self._pool = None
        if self._pool_ctx is not None:
            self._pool_ctx.__exit__(None, None, None)
            self._pool_ctx = None
```

`close` becomes:

```python
    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            if self._legacy:
                ...unchanged legacy body...
                return
            self.flush()
            self._drain(block_until=0)
            if self._rg is None:
                self._ensure_layout(None)
            self._write_close_tables()
            if self._provenance:
                ...unchanged...
        finally:
            self._shutdown_pool()
```

Note on `_append_index_arrays`: it reads `self._chrom_map` — every name is registered before submission, so it resolves.

`read_count`/`block_count` properties: they count written blocks only; document in the docstring: "blocks still in flight are counted after `flush`+drain or `close`".

Callers: `import_result.write_into` creates `GenomicStreamWriter(...)` — add `threads=getattr(self, "threads", None)` where `GenomicStreamSource` gains an optional `threads: int | None = None` field; `spectral_dataset._write_genomic_run_default` (the default writer used by `write_minimal`) passes `threads=None` (resolves from the environment).

- [ ] **Step 5: Run the tests**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/python && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O.worktrees/block-parallel/native/_build/libttio_rans.so $PYT tests/test_genomic_stream_writer.py tests/test_genomic_blocks_reader.py tests/test_blocks_v1_golden.py tests/test_importers_stream_genomic.py -q`
Expected: all pass, including `test_threaded_writer_is_byte_identical_to_serial`.

- [ ] **Step 6: Commit**

```bash
git add python/src/ttio/genomic/stream_writer.py python/src/ttio/genomic/lazy_reference.py python/src/ttio/importers/import_result.py python/src/ttio/spectral_dataset.py python/tests/test_genomic_stream_writer.py python/tests/_genomic_fixture.py
git commit -m "python: GenomicStreamWriter encodes blocks on a pool, written in order"
```

---

### Task 4: Python SpectralStreamWriter encodes FDZ blocks on a pool

**Files:**
- Modify: `python/src/ttio/spectral_stream_writer.py`
- Test: `python/tests/test_spectral_stream_writer.py`

**Interfaces:**
- Produces: `SpectralStreamWriter(..., threads: int | None = None)`, `.threads`.
- The FDZ block bytes of a channel are appended in emission order; the per-channel FIFO of futures is drained on every `_write_batch` and at `close`, window `threads + 1` per channel.

- [ ] **Step 1: Write the failing test**

Append to `python/tests/test_spectral_stream_writer.py` (reuse that file's helpers for building a writer over an HDF5 provider; the byte-comparison helper below is standalone):

```python
def _ms_bytes(path):
    import h5py
    out = {}
    with h5py.File(path, "r") as f:
        def visit(name, obj):
            if name.startswith("study/ms_runs"):
                attrs = {k: (v.tobytes() if hasattr(v, "tobytes") else v) for k, v in obj.attrs.items()}
                data = obj[()].tobytes() if isinstance(obj, h5py.Dataset) and obj.shape != () else None
                out[name] = (attrs, data)
        f.visititems(visit)
    return out


def _write_ms(tmp_path, threads, n_spectra=40_000, peaks=64):
    from ttio.providers.hdf5 import Hdf5Provider
    from ttio.spectral_stream_writer import SpectralStreamWriter
    from ttio.importers.import_result import ImportedSpectrum, _pack_run
    rng = np.random.default_rng(3)
    out = tmp_path / f"ms{threads}.tio"
    root = Hdf5Provider.create(str(out)).root_group()
    w = SpectralStreamWriter(root.create_group("study"), "run_0001", spectrum_class=1,
                             acquisition_mode=1, channel_names=["mz", "intensity"],
                             batch_spectra=1000, threads=threads)
    for j0 in range(0, n_spectra, 1000):
        specs = [ImportedSpectrum(mz_or_chemical_shift=np.sort(rng.uniform(100, 2000, peaks)),
                                  intensity=rng.uniform(0, 1e6, peaks), retention_time=float(i),
                                  ms_level=1, polarity=1, precursor_mz=0.0, precursor_charge=0)
                 for i in range(j0, j0 + 1000)]
        w.append_batch(_pack_run(specs, spectrum_class=1, acquisition_mode=1, channel_x="mz"))
    assert w.threads == threads
    w.close(); root.close()
    return out


def test_threaded_ms_writer_is_byte_identical(tmp_path):
    a, b = _write_ms(tmp_path, 1), _write_ms(tmp_path, 5)
    ba, bb = _ms_bytes(a), _ms_bytes(b)
    assert ba.keys() == bb.keys()
    for k in ba:
        assert ba[k] == bb[k], k
```

(Adjust the `SpectralStreamWriter` constructor keywords to the ones the file already uses in its other tests: `spectrum_class`, `acquisition_mode`, `channel_names`, `batch_spectra`.)

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/python && $PYT tests/test_spectral_stream_writer.py -q -k threaded`
Expected: FAIL (`unexpected keyword argument 'threads'`).

- [ ] **Step 3: Implement**

Constructor: `threads: int | None = None`; set `self._threads = resolve_threads(threads)`, `self._pool`, `self._pool_ctx` exactly as in Task 3, and `self._fdz_inflight: dict[str, list] = {c: [] for c in self._channels}`. Property `threads`.

Replace `_emit_fdz_block`:

```python
    def _emit_fdz_block(self, c: str, values: np.ndarray) -> None:
        values = np.ascontiguousarray(values, dtype=np.float64)
        if self._pool is None:
            self._append_fdz(c, fdz.encode_block(values), len(values))
            return
        self._drain_fdz(c, block_until=self._threads)
        self._fdz_inflight[c].append((self._pool.submit(fdz.encode_block, values), len(values)))

    def _drain_fdz(self, c: str, block_until: int) -> None:
        q = self._fdz_inflight[c]
        while q and (len(q) > block_until or q[0][0].done()):
            fut, n = q.pop(0)
            self._append_fdz(c, fut.result(), n)

    def _append_fdz(self, c: str, encoded, n_values: int) -> None:
        transform, body = encoded
        self._sig[c].append(np.frombuffer(fdz.block_bytes(transform, body), dtype=np.uint8))
        self._fdz_n[c] += n_values
        self._fdz_blocks[c] += 1
```

In `close`, before the loop that emits the tail buffer and rewrites the FDZ1 header, drain: `for c in self._channels: self._drain_fdz(c, block_until=0)` — and again after the tail `_emit_fdz_block` calls (`block_until=0`) so the tail block is written before `write_slice` of the header. Wrap the body of `close` in `try/finally` with the same `_shutdown_pool` as Task 3.

- [ ] **Step 4: Run tests**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/python && $PYT tests/test_spectral_stream_writer.py tests/test_importers_stream_ms.py -q`
Expected: pass. (If `test_importers_stream_ms.py` does not exist, run `tests/test_exporters_stream.py` instead.)

- [ ] **Step 5: Commit**

```bash
git add python/src/ttio/spectral_stream_writer.py python/tests/test_spectral_stream_writer.py
git commit -m "python: SpectralStreamWriter encodes FDZ blocks on a pool, appended in order"
```

---

### Task 5: Python readers decode ahead

**Files:**
- Modify: `python/src/ttio/genomic_run.py` (`iter_reads`, `_block_view`, a `threads` slot)
- Modify: `python/src/ttio/acquisition_run.py` (`_fdz_range`)
- Modify: `python/src/ttio/exporters/bam.py`, `python/src/ttio/exporters/fastq.py` (`opts.get("threads")` → `iter_reads(threads=...)`)
- Test: `python/tests/test_genomic_blocks_reader.py`, `python/tests/test_acquisition_run_lazy.py` (or the file that tests `channel_range`)

**Interfaces:**
- Produces: `GenomicRun.iter_reads(start=0, stop=None, *, threads: int | None = None)`; `AcquisitionRun.channel_range(channel, start, count, *, threads=None)`, `iter_spectra(batch=4096, *, threads=None)`.
- Produces: `GenomicRun._prefetch_view(b) -> GenomicRun` (materialise on the caller thread, warm on the pool: `view[0]` decodes every channel cache).

- [ ] **Step 1: Write the failing tests**

Append to `python/tests/test_genomic_blocks_reader.py`:

```python
def test_iter_reads_threaded_matches_serial(tmp_path):
    from ttio.codecs import ref_diff_v2 as rdv2
    if not rdv2.HAVE_NATIVE_LIB:
        pytest.skip("native lib")
    from test_genomic_stream_writer import _big_synthetic_run, _write_with_threads
    run = _big_synthetic_run(n=30_000)
    path = _write_with_threads(tmp_path, run, 1, block_reads=5_000)
    from ttio.spectral_dataset import SpectralDataset
    with SpectralDataset.open(path) as ds:
        g = ds.genomic_runs["g"]
        serial = [(r.read_name, r.sequence, r.cigar, r.mate_chromosome) for r in g.iter_reads(threads=1)]
        threaded = [(r.read_name, r.sequence, r.cigar, r.mate_chromosome) for r in g.iter_reads(threads=4)]
        assert threaded == serial
        part = [r.read_name for r in g.iter_reads(12_345, 17_890, threads=3)]
        assert part == [t[0] for t in serial[12_345:17_890]]
```

Append to the acquisition-run test file:

```python
def test_channel_range_threaded_matches_serial(tmp_path):
    from test_spectral_stream_writer import _write_ms
    from ttio.spectral_dataset import SpectralDataset
    path = _write_ms(tmp_path, 1, n_spectra=20_000, peaks=64)
    with SpectralDataset.open(path) as ds:
        run = ds.runs["run_0001"]
        n = int(run.index.offsets[-1] + run.index.lengths[-1])
        a = run.channel_range("mz", 1000, n - 2000, threads=1)
        b = run.channel_range("mz", 1000, n - 2000, threads=4)
        assert np.array_equal(a, b)
        s1 = [sp.signal_array("intensity").data.sum() for sp in run.iter_spectra(threads=1)]
        s4 = [sp.signal_array("intensity").data.sum() for sp in run.iter_spectra(threads=4)]
        assert s1 == s4
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/python && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O.worktrees/block-parallel/native/_build/libttio_rans.so $PYT tests/test_genomic_blocks_reader.py -q -k threaded`
Expected: FAIL (`unexpected keyword argument 'threads'`).

- [ ] **Step 3: Implement the genomic reader prefetch**

In `genomic_run.py`:

```python
    def _prefetch_view(self, b: int) -> "GenomicRun":
        """The block view for ``b`` built on the caller's thread (storage
        reads) but not yet decoded; ``_warm`` decodes it (pool-safe)."""
        from .genomic._block_view import materialise_block, _rows_of
        if self._name_tables is None:
            idx = self.group.open_group("genomic_index")
            sc = self.group.open_group("signal_channels")
            mate = _rows_of(sc.open_group("mate_info"), "chrom_names") if sc.has_child("mate_info") else None
            self._name_tables = (_rows_of(idx, "chromosome_names"), mate)
        grp = materialise_block(self.group, self._block_table, b,
                                chrom_name_rows=self._name_tables[0],
                                mate_chrom_rows=self._name_tables[1])
        self._blocks_materialised += 1
        return GenomicRun.open(grp, self.name, references_group=self._references_group,
                               bulk_read=self._bulk_read)

    @staticmethod
    def _warm(view: "GenomicRun") -> "GenomicRun":
        if len(view):
            view[0]          # decodes every channel of the block into its caches
        return view
```

`_block_view(b)` keeps its one-block cache but builds through `_prefetch_view` + `_warm` inline.

`iter_reads`:

```python
    def iter_reads(self, start: int = 0, stop: int | None = None, *,
                   threads: int | None = None) -> Iterator[AlignedRead]:
        """Yield reads ``[start, stop)`` in order. Under ``blocks_v1`` the
        next ``threads`` blocks decode ahead on a pool (``threads`` from
        the argument, else TTIO_THREADS); one thread keeps today's
        one-block path."""
        n = len(self)
        if stop is None or stop > n:
            stop = n
        if start < 0:
            start += n
        if self._layout != "blocks_v1":
            for i in range(max(start, 0), stop):
                yield self[i]
            return
        from ._threads import resolve_threads, pool_context
        t = self._block_table
        nthreads = resolve_threads(threads)
        i = max(start, 0)
        if nthreads <= 1 or i >= stop:
            while i < stop:
                b = t.block_for(i)
                r0 = int(t.read_start[b])
                b_end = min(r0 + int(t.n_reads[b]), stop)
                view = self._block_view(b)
                for j in range(i, b_end):
                    yield view[j - r0]
                i = b_end
            return
        import concurrent.futures as _cf
        b_first, b_last = t.block_for(i), t.block_for(stop - 1)
        with pool_context(nthreads), _cf.ThreadPoolExecutor(max_workers=nthreads) as pool:
            pending: dict[int, "_cf.Future"] = {}
            def submit(b):
                if b not in pending and b <= b_last:
                    pending[b] = pool.submit(self._warm, self._prefetch_view(b))
            for b in range(b_first, min(b_last, b_first + nthreads - 1) + 1):
                submit(b)
            b = b_first
            while i < stop:
                view = pending.pop(b).result()
                submit(b + nthreads)
                r0 = int(t.read_start[b])
                b_end = min(r0 + int(t.n_reads[b]), stop)
                for j in range(i, b_end):
                    yield view[j - r0]
                i = b_end
                b += 1
```

`_prefetch_view` runs storage reads on the caller thread; only `_warm` runs on the pool. `iter_reads` is a generator: closing it early exits the `with`, which waits for in-flight warms (bounded by the window).

- [ ] **Step 4: Implement the MS reader prefetch**

In `acquisition_run.py`, `channel_range(..., *, threads=None)` passes `threads` to `_fdz_range(channel, start, count, threads)`; `_fdz_range` when `k1 > k0` and `resolve_threads(threads) > 1`:

```python
        nthreads = resolve_threads(threads)
        ks = list(range(k0, k1 + 1))
        if nthreads > 1 and len(ks) > 1:
            from .codecs import float_delta_zstd as _fdz
            import concurrent.futures as _cf
            ds = self._signal_dataset(channel)
            raw = {}
            for k in ks:                       # storage reads on this thread
                off, ln = table.block_offset(k), table.block_length(k)
                raw[k] = np.asarray(ds.read(offset=off, count=ln), dtype=np.uint8).tobytes()
            with pool_context(nthreads), _cf.ThreadPoolExecutor(max_workers=nthreads) as pool:
                futs = {k: pool.submit(_fdz.decode_block, (lambda o, n, _b=raw[k], _o=table.block_offset(k): _b[o - _o:o - _o + n]), table, k) for k in ks}
                blocks = {k: futs[k].result() for k in ks}
            self._fdz_cache[channel] = (k1, blocks[k1])
            self._fdz_blocks_decoded[channel] = self._fdz_blocks_decoded.get(channel, 0) + len(ks)
        else:
            blocks = {k: self._fdz_block(channel, k) for k in ks}
        parts = []
        for k in ks:
            blk = blocks[k]
            lo = start - k * bs if k == k0 else 0
            hi = (start + count) - k * bs if k == k1 else len(blk)
            parts.append(blk[lo:hi])
        return np.concatenate(parts)
```

`table.block_offset(k)` / `table.block_length(k)`: if `BlockTable` in `codecs/float_delta_zstd.py` exposes the per-block offset/length under other names (check `read_block_table`), use those; `decode_block(reader, table, k)` reads through the passed reader callable, so the lambda serves the block's bytes from memory. `iter_spectra(batch, *, threads=None)` passes `threads` to `channel_range`.

Exporters: in `exporters/bam.py` and `exporters/fastq.py`, where `run.iter_reads(...)` is called, pass `threads=opts.get("threads")` (the exporter `write(ds, layer, output, opts)` receives the opts dict; `ttio export --extra threads=8` reaches it too, but the CLI's `--threads` works through the environment already).

- [ ] **Step 5: Run tests**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/python && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O.worktrees/block-parallel/native/_build/libttio_rans.so $PYT tests/test_genomic_blocks_reader.py tests/test_genomic_stream_writer.py tests/test_exporters_stream.py tests/test_blocks_v1_golden.py -q`
and the acquisition test file. Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add python/src/ttio/genomic_run.py python/src/ttio/acquisition_run.py python/src/ttio/exporters/bam.py python/src/ttio/exporters/fastq.py python/tests
git commit -m "python: readers decode the next blocks ahead on a pool"
```

---

### Task 6: Java knob, CLI flag and GenomicStreamWriter pool

**Files:**
- Create: `java/src/main/java/global/thalion/ttio/Threads.java`
- Modify: `java/src/main/java/global/thalion/ttio/tools/EncodeCli.java`, `ExportCli.java` (`--threads N` → `System.setProperty("ttio.threads", N)`)
- Modify: `java/src/main/java/global/thalion/ttio/genomics/GenomicStreamWriter.java`
- Modify: `java/src/main/java/global/thalion/ttio/genomics/LazyReference.java` (`synchronized` on `get` and `setMd5`)
- Test: `java/src/test/java/global/thalion/ttio/ThreadsTest.java`, `java/src/test/java/global/thalion/ttio/genomics/GenomicStreamWriterTest.java`

**Interfaces:**
- Produces: `Threads.resolve(Integer explicit)` — explicit > 0 wins; else system property `ttio.threads`; else env `TTIO_THREADS`; unset/0 → `max(1, availableProcessors() - 8)`. `Threads.PoolScope` (`AutoCloseable`): `Threads.pool(int n)` returns a scope holding an `ExecutorService` (`null` when `n <= 1`), sets `FqzcompNx16Z.setAutotuneThreads(1)` while any scope with n > 1 is open (reference-counted), restores on close.
- Produces: `GenomicStreamWriter(StorageGroup study, String name, Options options, int threads)`; the 3-arg constructor resolves `Threads.resolve(null)`. `int threads()`.
- Produces: `GenomicStreamWriter.registerBlockChromosomes(WrittenGenomicRun block, Map<String,Integer> map)` (static, package-visible), same order as the Python helper.

- [ ] **Step 1: Write the failing tests**

```java
// java/src/test/java/global/thalion/ttio/ThreadsTest.java
package global.thalion.ttio;

import static org.junit.jupiter.api.Assertions.*;
import org.junit.jupiter.api.Test;

class ThreadsTest {
    @Test
    void resolvePrecedence() {
        System.clearProperty("ttio.threads");
        int cores = Runtime.getRuntime().availableProcessors();
        assertEquals(Math.max(1, cores - 8), Threads.resolveIgnoringEnv(null));
        System.setProperty("ttio.threads", "6");
        assertEquals(6, Threads.resolve(null));
        assertEquals(2, Threads.resolve(2));
        assertEquals(6, Threads.resolve(0));
        System.setProperty("ttio.threads", "junk");
        assertEquals(1, Threads.resolve(null));
        System.clearProperty("ttio.threads");
    }

    @Test
    void poolScopeStandsDownAutotune() {
        if (!global.thalion.ttio.codecs.FqzcompNx16Z.isAvailable()) return;
        int before = global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads();
        try (Threads.PoolScope s = Threads.pool(1)) {
            assertNull(s.executor());
            assertEquals(before, global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads());
        }
        try (Threads.PoolScope s = Threads.pool(4)) {
            assertNotNull(s.executor());
            assertEquals(1, global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads());
            try (Threads.PoolScope inner = Threads.pool(2)) {
                assertEquals(1, global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads());
            }
            assertEquals(1, global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads());
        }
        assertEquals(before, global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads());
    }
}
```

Append to `GenomicStreamWriterTest.java` (it already builds runs and writes through `SpectralDataset.create` / the writer; add a synthetic multi-block run helper mirroring Python's `_big_synthetic_run`: 60,000 reads, two chromosomes, every 97th read `cigar "*"` with flag 0x5, every 13th a cross-chromosome mate, every 3rd `"="`, embedded 400 kb random references) and:

```java
    @Test
    void threadedWriterIsByteIdenticalToSerial(@TempDir Path tmp) throws Exception {
        WrittenGenomicRun run = bigSyntheticRun(60_000, 7);
        Path a = writeWithThreads(tmp.resolve("t1.tio"), run, 1, 20_000);
        Path b = writeWithThreads(tmp.resolve("t6.tio"), run, 6, 20_000);
        assertEquals(runBytes(a), runBytes(b));
        try (SpectralDataset ds = SpectralDataset.open(b.toString())) {
            GenomicRun g = ds.genomicRuns().get("g");
            assertEquals(60_000, g.readCount());
            assertEquals(3, g.blockCount());
            assertEquals("*", g.readAt(96).cigar());
        }
    }

    @Test
    void registerBlockChromosomesMatchesEncoderOrder() {
        Map<String, Integer> m = new LinkedHashMap<>();
        GenomicStreamWriter.registerBlockChromosomes(miniRun(List.of("chr2", "*", "chr2"), List.of("chr1", "*", "=")), m);
        assertEquals(Map.of("chr2", 0, "*", 1, "chr1", 2), m);
        GenomicStreamWriter.registerBlockChromosomes(miniRun(List.of("chr3"), List.of("chr2")), m);
        assertEquals(4, m.size()); assertEquals(3, m.get("chr3"));
    }
```

`writeWithThreads` opens an `Hdf5Provider` file, creates `study`, constructs `new GenomicStreamWriter(study, "g", options.withReference(run.referenceChromSeqs(), true).withBlockPolicy(blockReads, Long.MAX_VALUE), threads)`, appends the run in slices of 7,001 reads (`GenomicBlocks.sliceRun`), closes. `runBytes` walks `/study/genomic_runs` and `/study/references` with the `Hdf5File` API and returns a `Map<String, List<Object>>` of attribute values and dataset bytes (`readAll()`), in link order.

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/java && mvn -q -o test -Dhdf5.native.path=/usr/local/lib:/home/toddw/TTI-O.worktrees/block-parallel/native/_build -Dtest="ThreadsTest,GenomicStreamWriterTest" -Dsurefire.failIfNoSpecifiedTests=false 2>&1 | grep -E "ERROR.*java|cannot find symbol" | head -3`
Expected: `cannot find symbol Threads`.

- [ ] **Step 3: Implement `Threads.java`**

```java
package global.thalion.ttio;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** The one thread knob of the SDK: {@code -Dttio.threads}, then
 *  {@code TTIO_THREADS}; unset or 0 means {@code max(1, cores - 8)}; 1 is
 *  the serial path with no executor. */
public final class Threads {
    private Threads() {}

    public static int resolve(Integer explicit) {
        if (explicit != null && explicit > 0) return explicit;
        String raw = System.getProperty("ttio.threads");
        if (raw == null || raw.isBlank()) raw = System.getenv("TTIO_THREADS");
        return fromRaw(raw);
    }

    /** As {@link #resolve} but ignoring the environment (tests). */
    static int resolveIgnoringEnv(Integer explicit) {
        if (explicit != null && explicit > 0) return explicit;
        return fromRaw(System.getProperty("ttio.threads"));
    }

    private static int fromRaw(String raw) {
        int n = 0;
        if (raw != null && !raw.isBlank()) {
            try { n = Integer.parseInt(raw.trim()); } catch (NumberFormatException e) { return 1; }
        }
        if (n <= 0) n = Math.max(1, Runtime.getRuntime().availableProcessors() - 8);
        return n;
    }

    private static int depth;
    private static int savedAutotune;

    /** A pool of {@code n} workers ({@code null} executor when n <= 1) that
     *  stands the FQZCOMP auto-tune threads down while it exists. */
    public static PoolScope pool(int n) { return new PoolScope(n); }

    public static final class PoolScope implements AutoCloseable {
        private final ExecutorService executor;
        PoolScope(int n) {
            if (n <= 1) { executor = null; return; }
            executor = Executors.newFixedThreadPool(n, r -> {
                Thread t = new Thread(r, "ttio-block"); t.setDaemon(true); return t; });
            synchronized (Threads.class) {
                if (depth++ == 0) {
                    savedAutotune = global.thalion.ttio.codecs.FqzcompNx16Z.getAutotuneThreads();
                    global.thalion.ttio.codecs.FqzcompNx16Z.setAutotuneThreads(1);
                }
            }
        }
        public ExecutorService executor() { return executor; }
        @Override public void close() {
            if (executor == null) return;
            executor.shutdown();
            synchronized (Threads.class) {
                if (--depth == 0) global.thalion.ttio.codecs.FqzcompNx16Z.setAutotuneThreads(savedAutotune);
            }
        }
    }
}
```

CLI: in `EncodeCli` and `ExportCli` argument loops add `case "--threads" -> System.setProperty("ttio.threads", args[++i]);` and the usage line.

- [ ] **Step 4: Implement the pooled writer**

`GenomicStreamWriter`: fields

```java
    private final int threads;
    private final Threads.PoolScope scope;
    private final java.util.ArrayDeque<InFlight> inflight = new java.util.ArrayDeque<>();
    private record InFlight(WrittenGenomicRun block, java.util.concurrent.Future<GenomicBlocks.BlockBlobs> blobs) {}
```

Constructors:

```java
    public GenomicStreamWriter(StorageGroup studyGroup, String runName, Options options) {
        this(studyGroup, runName, options, Threads.resolve(null));
    }

    public GenomicStreamWriter(StorageGroup studyGroup, String runName, Options options, int threads) {
        ...existing body...
        this.threads = Math.max(1, threads);
        this.scope = Threads.pool(this.threads);
    }

    public int threads() { return threads; }

    static void registerBlockChromosomes(WrittenGenomicRun block, Map<String, Integer> map) {
        for (String name : block.chromosomes()) map.putIfAbsent(name, map.size());
        for (String name : block.mateChromosomes()) {
            if (name != null && !name.isEmpty() && !"*".equals(name) && !"=".equals(name)) map.putIfAbsent(name, map.size());
        }
    }
```

`flush`: after `block = applyMeta(block);` and the embed step, replace the encode + write with

```java
        registerBlockChromosomes(block, chromMap);
        GenomicWriteContext ctx = new GenomicWriteContext(chromMap, referenceMd5);
        if (scope.executor() == null) {
            writeEncoded(block, GenomicBlocks.encodeBlock(block, ctx));
            return;
        }
        drain(threads);   // window: threads in the pool plus this one
        WrittenGenomicRun fb = block;
        inflight.add(new InFlight(block, scope.executor().submit(() -> GenomicBlocks.encodeBlock(fb, ctx))));
```

with

```java
    private void drain(int blockUntil) {
        while (!inflight.isEmpty() && (inflight.size() > blockUntil || inflight.peekFirst().blobs().isDone())) {
            InFlight f = inflight.pollFirst();
            try {
                writeEncoded(f.block(), f.blobs().get());
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt(); throw new IllegalStateException(e);
            } catch (java.util.concurrent.ExecutionException e) {
                Throwable c = e.getCause();
                throw c instanceof RuntimeException r ? r : new IllegalStateException(c);
            }
        }
    }

    private void writeEncoded(WrittenGenomicRun block, GenomicBlocks.BlockBlobs blobs) {
        ensureLayout();
        ...the former tail of flush from `Object[] row = ...` to `rg.setAttribute("base_count", baseCount);`...
    }
```

Note: `registerBlockChromosomes` must run before `applyMeta` is used to build the context only in the sense that the map is complete before submission; the existing `applyMeta(block)` does not touch the map. `close`: after `flush()` call `drain(0)`; wrap the non-legacy body in try/finally that calls `scope.close()` (and the legacy branch too).

`LazyReference`: make `get(Object)` and `setMd5()` `synchronized`.

- [ ] **Step 5: Run tests**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/java && mvn -q -o test -Dhdf5.native.path=/usr/local/lib:/home/toddw/TTI-O.worktrees/block-parallel/native/_build -Dtest="ThreadsTest,GenomicStreamWriterTest,GenomicBlocksReaderTest,BlocksV1GoldenTest,M89GenomicTransportTest" -Dsurefire.failIfNoSpecifiedTests=false 2>&1 | grep -E "Tests run:|ERROR\]" | grep -v "class file" | head`
Expected: all `Failures: 0, Errors: 0`.

- [ ] **Step 6: Commit**

```bash
git add java/src/main/java/global/thalion/ttio/Threads.java java/src/main/java/global/thalion/ttio/tools/EncodeCli.java java/src/main/java/global/thalion/ttio/tools/ExportCli.java java/src/main/java/global/thalion/ttio/genomics/GenomicStreamWriter.java java/src/main/java/global/thalion/ttio/genomics/LazyReference.java java/src/test/java/global/thalion/ttio/ThreadsTest.java java/src/test/java/global/thalion/ttio/genomics/GenomicStreamWriterTest.java
git commit -m "java: Threads knob, --threads, GenomicStreamWriter encodes blocks on a pool"
```

---

### Task 7: Java SpectralStreamWriter pool and reader prefetch

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/SpectralStreamWriter.java`
- Modify: `java/src/main/java/global/thalion/ttio/genomics/GenomicRun.java` (`iterReads(int,int)`, `iterReads(int,int,int threads)`)
- Modify: `java/src/main/java/global/thalion/ttio/AcquisitionRun.java` (`channelRange(String,long,int,int threads)`, `iterSpectra(int batch, int threads)`)
- Modify: `java/src/main/java/global/thalion/ttio/exporters/BamWriter.java`, `FastqWriter.java` (pass `Threads.resolve(null)` where they iterate)
- Test: `SpectralStreamWriterTest.java`, `GenomicBlocksReaderTest.java`, `AcquisitionRunLazyTest.java` (or the existing lazy-run test file)

**Interfaces:**
- Produces: `SpectralStreamWriter(StorageGroup, String, Options, int threads)`, `int threads()`; `GenomicRun.iterReads(int start, int stop, int threads)`; `AcquisitionRun.channelRange(String channel, long start, int count, int threads)`, `iterSpectra(int batch, int threads)`. The 2/3-arg forms resolve `Threads.resolve(null)`.

- [ ] **Step 1: Write the failing tests**

`SpectralStreamWriterTest`: `threadedMsWriterIsByteIdentical` — write 40,000 synthetic spectra of 64 peaks with `batchSpectra 1000` through `new SpectralStreamWriter(study, "run_0001", opts, 1)` and `... , 5)`, compare `runBytes` (walk `/study/ms_runs`) for equality.

`GenomicBlocksReaderTest`: `iterReadsThreadedMatchesSerial` — write the 30,000-read synthetic run with `blockReads 5000`, then compare `List` of `(readName, sequence, cigar, mateChromosome)` from `iterReads(0, n, 1)` and `iterReads(0, n, 4)`, and a sub-range `iterReads(12_345, 17_890, 3)`.

`AcquisitionRun` test: `channelRangeThreadedMatchesSerial` — write 20,000 spectra, compare `channelRange("mz", 1000, n - 2000, 1)` with `(..., 4)` by `assertArrayEquals`, and the per-spectrum intensity sums from `iterSpectra(4096, 1)` and `iterSpectra(4096, 4)`.

- [ ] **Step 2: Run to verify failure**

Run the three test classes as in Task 6 Step 5. Expected: `cannot find symbol` on the new overloads.

- [ ] **Step 3: Implement**

`SpectralStreamWriter`: fields `threads`, `scope`, `Map<String, ArrayDeque<InFlightFdz>> fdzInflight` (`record InFlightFdz(Future<FloatDeltaZstd.Encoded> encoded, int nValues)`); the FDZ emit method submits `FloatDeltaZstd.encodeBlock(values)` when `scope.executor() != null` after `drainFdz(channel, threads)`, appends in order through `appendFdz(channel, encoded, n)`; `close` drains every channel with `blockUntil 0` before and after the tail block, before the FDZ1 header rewrite; `scope.close()` in a finally.

`GenomicRun.iterReads(start, stop, threads)`:

```java
    public java.util.Iterator<AlignedRead> iterReads(int start, int stop, int threads) {
        int n = readCount();
        int lo = Math.max(start, 0), hi = Math.min(stop, n);
        int nthreads = Math.max(1, threads);
        if (blockTable == null || nthreads <= 1 || lo >= hi) return iterReads(lo, hi);
        final int bFirst = blockTable.blockFor(lo), bLast = blockTable.blockFor(hi - 1);
        final Threads.PoolScope scope = Threads.pool(nthreads);
        final java.util.Map<Integer, java.util.concurrent.Future<GenomicRun>> pending = new java.util.HashMap<>();
        final java.util.function.IntConsumer submit = b -> {
            if (b <= bLast && !pending.containsKey(b)) {
                BlockView.Handle h = materialiseHandle(b);          // storage reads, this thread
                pending.put(b, scope.executor().submit(() -> warm(GenomicRun.readFrom(h.group(), name, resolverForViews()), h)));
            }
        };
        for (int b = bFirst; b <= Math.min(bLast, bFirst + nthreads - 1); b++) submit.accept(b);
        return new java.util.Iterator<>() {
            int i = lo, b = bFirst; GenomicRun view; int r0, bEnd;
            @Override public boolean hasNext() {
                if (i >= hi) { scope.close(); return false; }
                return true;
            }
            @Override public AlignedRead next() {
                if (i >= hi) throw new NoSuchElementException();
                if (view == null || i >= bEnd) {
                    try { view = pending.remove(b).get(); }
                    catch (Exception e) { scope.close(); throw new IllegalStateException(e); }
                    submit.accept(b + nthreads);
                    r0 = (int) blockTable.readStart[b];
                    bEnd = Math.min(r0 + (int) blockTable.nReads[b], hi);
                    b++;
                }
                return view.objectAtIndex(i++ - r0);
            }
        };
    }
```

with `materialiseHandle(b)` = the `BlockView.materialise(...)` call from `blockView` (name tables read first, on this thread) and `warm(view, handle)` = `if (view.readCount() > 0) view.readAt(0); return view;` (the handle is discarded when the view is closed by the iterator on advancing: keep the previous view/handle and close them when moving to the next block). `iterReads(int,int)` delegates to `iterReads(start, stop, Threads.resolve(null))`; the previous serial body stays as `iterReadsSerial(lo, hi)`.

`AcquisitionRun.channelRange(channel, start, count, threads)`: in the FDZ branch, when the range spans more than one block and `threads > 1`, read every block's bytes on this thread, submit `FloatDeltaZstd.decodeBlock(bytes, table, k)` per block to a `Threads.pool(threads)`, join in order, concatenate; the 3-arg form resolves `Threads.resolve(null)`. `iterSpectra(batch, threads)` passes `threads` down; `iterSpectra(batch)` resolves.

Exporters `BamWriter`/`FastqWriter`: where they call `run.iterReads(...)`, call the 3-arg form with `Threads.resolve(null)`.

- [ ] **Step 4: Run tests**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/java && mvn -q -o test -Dhdf5.native.path=/usr/local/lib:/home/toddw/TTI-O.worktrees/block-parallel/native/_build 2>&1 | grep -E "Tests run:.*Fail|BUILD|ERROR\]" | grep -v "class file" | tail -5`
Expected: `BUILD SUCCESS` (full Java suite).

- [ ] **Step 5: Commit**

```bash
git add java/src
git commit -m "java: SpectralStreamWriter pool, readers decode ahead"
```

---

### Task 8: ObjC knob, CLI flag and TTIOGenomicStreamWriter pool

**Files:**
- Create: `objc/Source/Support/TTIOThreads.h`, `objc/Source/Support/TTIOThreads.m` (add to `objc/Source/GNUmakefile` sources and headers; use the directory the makefile already lists for small helpers, e.g. `Support/` if present, else `ValueClasses/`)
- Modify: `objc/Tools/TtioEncode.m`, `objc/Tools/TtioExport.m` (`--threads N` → `setenv("TTIO_THREADS", N, 1)`)
- Modify: `objc/Source/Genomics/TTIOGenomicStreamWriter.h/.m`
- Modify: `objc/Source/Genomics/TTIOLazyReference.m` (`NSLock` around `objectForKey:` and `setMD5`)
- Test: `objc/Tests/TestThreads.m` (register in `Tests/GNUmakefile` and `TTIOTestRunner.m`), `objc/Tests/TestGenomicStreamWriter.m`

**Interfaces:**
- Produces: `+[TTIOThreads resolve:(NSNumber * _Nullable)explicit]` → `NSUInteger`; `TTIOThreadPool` (`+poolWithThreads:`, `@property (readonly, nullable) NSOperationQueue *queue` (nil when threads <= 1), `-close`), which sets `ttio_m94z_set_autotune_threads(1)` while any pool with threads > 1 exists (reference-counted under a static lock) and restores on close.
- Produces: `TTIOGenomicStreamWriterOptions.threads` (`NSUInteger`, 0 = resolve) and `TTIOGenomicStreamWriter.threads`; `+[TTIOGenomicStreamWriter registerBlockChromosomes:(TTIOWrittenGenomicRun *)block intoMap:(NSMutableDictionary<NSString *, NSNumber *> *)map]`.

- [ ] **Step 1: Write the failing tests**

`TestThreads.m`:

```objc
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Support/TTIOThreads.h"
#include <stdlib.h>
#include "ttio_rans.h"

void testThreads(void);
void testThreads(void)
{
    unsetenv("TTIO_THREADS");
    NSUInteger cores = (NSUInteger)[[NSProcessInfo processInfo] activeProcessorCount];
    PASS([TTIOThreads resolve:nil] == MAX(1u, cores > 8 ? cores - 8 : 1), "threads: default is cores minus 8, at least 1");
    setenv("TTIO_THREADS", "6", 1);
    PASS([TTIOThreads resolve:nil] == 6, "threads: TTIO_THREADS wins over the default");
    PASS([TTIOThreads resolve:@2] == 2, "threads: an explicit value wins");
    PASS([TTIOThreads resolve:@0] == 6, "threads: explicit 0 defers to the environment");
    setenv("TTIO_THREADS", "junk", 1);
    PASS([TTIOThreads resolve:nil] == 1, "threads: junk resolves to 1");
    unsetenv("TTIO_THREADS");
    int before = ttio_m94z_get_autotune_threads();
    TTIOThreadPool *p1 = [TTIOThreadPool poolWithThreads:1];
    PASS(p1.queue == nil && ttio_m94z_get_autotune_threads() == before, "threads: a one-thread pool has no queue and leaves the auto-tune alone");
    [p1 close];
    TTIOThreadPool *p4 = [TTIOThreadPool poolWithThreads:4];
    PASS(p4.queue != nil && p4.queue.maxConcurrentOperationCount == 4, "threads: a pool has a queue of its size");
    PASS(ttio_m94z_get_autotune_threads() == 1, "threads: the auto-tune stands down while a pool exists");
    [p4 close];
    PASS(ttio_m94z_get_autotune_threads() == before, "threads: restored at close");
}
```

`TestGenomicStreamWriter.m`: add `testGenomicStreamWriterThreadedIsByteIdentical` — build the same 60,000-read synthetic run as Python (a static helper in the test file: two 400 kb random references, every 97th read `@"*"` cigar with flag 0x5, every 13th a cross-chromosome mate, every 3rd `@"="`), write it twice with `options.threads = 1` and `options.threads = 6` (`blockReads 20000`, appended in slices of 7,001 reads via `+[TTIOGenomicBlocks sliceRun:from:to:]`), then compare the two files: for every object under `/study/genomic_runs` and `/study/references` (walk with the HDF5 C API `H5Ovisit`), every attribute's bytes and every dataset's raw bytes equal. Then open the threaded file and `PASS` on `readCount == 60000`, `blockCount == 3`, `[[run readAtIndex:96 error:NULL].cigar isEqualToString:@"*"]`. Also `testRegisterBlockChromosomesOrder`: the two-step map assertion from the Python test.

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/objc && ./build.sh 2>&1 | grep -E "error:" | grep -v "NSError" | head -3`
Expected: `'Support/TTIOThreads.h' file not found` (after adding the test to the makefile).

- [ ] **Step 3: Implement TTIOThreads**

```objc
// TTIOThreads.h
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/** The one thread knob of the SDK: TTIO_THREADS unset or 0 means
 *  max(1, cores - 8); 1 is the serial path with no queue; N is the pool. */
@interface TTIOThreads : NSObject
+ (NSUInteger)resolve:(nullable NSNumber *)explicit;
@end

/** A queue of N workers (nil when N <= 1) that stands the FQZCOMP
 *  auto-tune threads down while it exists. */
@interface TTIOThreadPool : NSObject
+ (instancetype)poolWithThreads:(NSUInteger)threads;
@property (nonatomic, readonly, nullable) NSOperationQueue *queue;
@property (nonatomic, readonly) NSUInteger threads;
- (void)close;
@end
NS_ASSUME_NONNULL_END
```

```objc
// TTIOThreads.m
#import "Support/TTIOThreads.h"
#include <pthread.h>
#include <stdlib.h>
#include "ttio_rans.h"

@implementation TTIOThreads
+ (NSUInteger)resolve:(NSNumber *)explicit
{
    if (explicit && explicit.integerValue > 0) return (NSUInteger)explicit.integerValue;
    const char *raw = getenv("TTIO_THREADS");
    long n = 0;
    if (raw && *raw) {
        char *end = NULL;
        n = strtol(raw, &end, 10);
        if (end == raw || (end && *end && *end != ' ')) return 1;
    }
    if (n <= 0) {
        long cores = (long)[[NSProcessInfo processInfo] activeProcessorCount];
        n = cores - 8 > 1 ? cores - 8 : 1;
    }
    return (NSUInteger)n;
}
@end

static pthread_mutex_t g_poolLock = PTHREAD_MUTEX_INITIALIZER;
static int g_poolDepth = 0;
static int g_savedAutotune = 3;

@implementation TTIOThreadPool {
    NSOperationQueue *_queue;
    NSUInteger _threads;
    BOOL _closed;
}
+ (instancetype)poolWithThreads:(NSUInteger)threads
{
    TTIOThreadPool *p = [self new];
    p->_threads = threads < 1 ? 1 : threads;
    if (p->_threads > 1) {
        p->_queue = [NSOperationQueue new];
        p->_queue.maxConcurrentOperationCount = (NSInteger)p->_threads;
        p->_queue.name = @"ttio-block";
        pthread_mutex_lock(&g_poolLock);
        if (g_poolDepth++ == 0) {
            g_savedAutotune = ttio_m94z_get_autotune_threads();
            ttio_m94z_set_autotune_threads(1);
        }
        pthread_mutex_unlock(&g_poolLock);
    }
    return p;
}
- (NSOperationQueue *)queue { return _queue; }
- (NSUInteger)threads { return _threads; }
- (void)close
{
    if (_closed || !_queue) { _closed = YES; return; }
    _closed = YES;
    [_queue waitUntilAllOperationsAreFinished];
    pthread_mutex_lock(&g_poolLock);
    if (--g_poolDepth == 0) ttio_m94z_set_autotune_threads(g_savedAutotune);
    pthread_mutex_unlock(&g_poolLock);
}
- (void)dealloc { [self close]; [super dealloc]; }   /* MRC: drop [super dealloc] under ARC */
@end
```

(Match the memory model the file's neighbours use: the ObjC tree is MRC in places — mirror `TTIOGenomicStreamWriter.m`'s conventions for `dealloc`.) CLI: `TtioEncode.m`/`TtioExport.m` argument loops: `else if (strcmp(a, "--threads") == 0 && i + 1 < argc) { setenv("TTIO_THREADS", argv[++i], 1); }` and the usage strings.

- [ ] **Step 4: Implement the pooled writer**

`TTIOGenomicStreamWriterOptions`: `@property (nonatomic) NSUInteger threads;` (0 = resolve). Writer ivars: `TTIOThreadPool *_pool; NSMutableArray *_inflight; NSCondition *_cond;` — an in-flight entry is a small object `TTIOInFlightBlock { TTIOWrittenGenomicRun *block; TTIOBlockBlobs *blobs; NSError *error; BOOL done; }`. In `initWithStudyGroup:...`: `_threads = [TTIOThreads resolve:opt.threads ? @(opt.threads) : nil]; _pool = [TTIOThreadPool poolWithThreads:_threads]; _cond = [NSCondition new]; _inflight = [NSMutableArray array];`. Property `threads`.

`flush:` after the embed step:

```objc
    [[self class] registerBlockChromosomes:block intoMap:_chromMap];
    TTIOGenomicWriteContext *ctx =
        [TTIOGenomicWriteContext contextWithChromNameToId:_chromMap referenceMD5:_referenceMD5];
    if (_pool.queue == nil) {
        TTIOBlockBlobs *blobs = [TTIOGenomicBlocks encodeBlock:block context:ctx error:error];
        if (!blobs) return NO;
        return [self _writeEncoded:block blobs:blobs error:error];
    }
    if (![self _drainUntil:_threads error:error]) return NO;
    TTIOInFlightBlock *f = [TTIOInFlightBlock new];
    f.block = block;
    [_inflight addObject:f];
    NSCondition *cond = _cond;
    [_pool.queue addOperationWithBlock:^{
        NSError *e = nil;
        TTIOBlockBlobs *b = [TTIOGenomicBlocks encodeBlock:block context:ctx error:&e];
        [cond lock];
        f.blobs = b; f.error = e; f.done = YES;
        [cond broadcast];
        [cond unlock];
    }];
    return YES;
```

```objc
- (BOOL)_drainUntil:(NSUInteger)blockUntil error:(NSError **)error
{
    while (_inflight.count > 0) {
        TTIOInFlightBlock *f = _inflight.firstObject;
        [_cond lock];
        if (_inflight.count <= blockUntil && !f.done) { [_cond unlock]; break; }
        while (!f.done) [_cond wait];
        [_cond unlock];
        [_inflight removeObjectAtIndex:0];
        if (!f.blobs) { if (error) *error = f.error; return NO; }
        if (![self _writeEncoded:f.block blobs:f.blobs error:error]) return NO;
    }
    return YES;
}
```

`_writeEncoded:blobs:error:` = the former tail of `flush:` from `_ensureLayout` to the two attribute writes. `registerBlockChromosomes:intoMap:`: own names in order (`'*'` included) then mate names that are not empty, `@"*"` or `@"="`, `map[name] = @(map.count)` when absent. `close:` calls `flush:` then `_drainUntil:0`, and `[_pool close]` on every exit path. `TTIOLazyReference`: an `NSLock` ivar around the cache lookup/insert in `objectForKey:` and around `setMD5`.

- [ ] **Step 5: Run the ObjC suite**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/objc && ./build.sh check > /tmp/c-bp.log 2>&1; echo EXIT=$?; grep -aE "build.sh:|Failed (test|set)" /tmp/c-bp.log | head; grep -a "threads:" /tmp/c-bp.log | head`
Expected: `build.sh: all tests passed`.

- [ ] **Step 6: Commit**

```bash
git add objc/Source objc/Tools objc/Tests
git commit -m "objc: TTIOThreads knob, --threads, TTIOGenomicStreamWriter encodes blocks on a queue"
```

---

### Task 9: ObjC SpectralStreamWriter queue and reader prefetch

**Files:**
- Modify: `objc/Source/Run/TTIOSpectralStreamWriter.h/.m`
- Modify: `objc/Source/Genomics/TTIOGenomicRun.h/.m` (`iterReadsFrom:to:threads:error:usingBlock:`; the 4-arg form resolves)
- Modify: `objc/Source/Run/TTIOAcquisitionRun.h/.m` (`channelRange:start:count:threads:error:`, `iterSpectraWithBatch:threads:error:usingBlock:`)
- Modify: `objc/Source/Export/TTIOBamWriter.m`, `TTIOFastqWriter.m` (call the threaded iterator with `[TTIOThreads resolve:nil]`)
- Test: `objc/Tests/TestSpectralStreamWriter.m`, `objc/Tests/TestGenomicBlocksReader.m`, `objc/Tests/TestStreamingImporters.m` or the acquisition-run lazy test

**Interfaces:**
- Produces: `TTIOSpectralStreamWriterOptions.threads`, `TTIOSpectralStreamWriter.threads`; `-[TTIOGenomicRun iterReadsFrom:to:threads:error:usingBlock:]`; `-[TTIOAcquisitionRun channelRange:start:count:threads:error:]`, `-iterSpectraWithBatch:threads:error:usingBlock:`.

- [ ] **Step 1: Write the failing tests**

`TestSpectralStreamWriter.m`: `spectralStreamWriterThreadedIsByteIdentical` — 40,000 synthetic spectra of 64 peaks, `batchSpectra 1000`, `threads 1` vs `threads 5`, walk `/study/ms_runs` with `H5Ovisit` and compare every attribute's and dataset's bytes.

`TestGenomicBlocksReader.m`: `iterReadsThreadedMatchesSerial` — write the 30,000-read synthetic run with `blockReads 5000` (`threads 1`), then collect `readName|sequence|cigar|mateChromosome` strings from `iterReadsFrom:0 to:n threads:1` and `threads:4` and `PASS` on equality, plus the sub-range `12345..17890` with `threads:3`.

Acquisition test: `channelRangeThreadedMatchesSerial` — 20,000 spectra written; `channelRange:@"mz" start:1000 count:n-2000 threads:1` vs `threads:4` equal `NSData`; per-spectrum intensity sums from `iterSpectraWithBatch:4096 threads:1` and `threads:4` equal.

- [ ] **Step 2: Run to verify failure**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/objc && ./build.sh 2>&1 | grep -E "error:" | grep -v NSError | head -3`
Expected: `no visible @interface ... declares the selector 'iterReadsFrom:to:threads:error:usingBlock:'`.

- [ ] **Step 3: Implement**

`TTIOSpectralStreamWriter`: `threads` option, `TTIOThreadPool *_pool`, per-channel `NSMutableArray` of in-flight FDZ blocks (`TTIOInFlightFdz { NSData *encoded; NSUInteger nValues; BOOL done; NSError *error; }`) with the same `NSCondition` pattern as Task 8; the FDZ emit method submits `[TTIOFloatDeltaZstd encodeBlock:values]` to the queue after draining the channel to `_threads`, appends encoded blocks in order; `close:` drains every channel to 0 before and after the tail block and before the FDZ1 header rewrite; `[_pool close]` on every exit path.

`TTIOGenomicRun`:

```objc
- (BOOL)iterReadsFrom:(NSUInteger)start to:(NSUInteger)stop threads:(NSUInteger)threads
                error:(NSError **)error usingBlock:(void (^)(TTIOAlignedRead *read, NSUInteger index, BOOL *stop))block
{
    NSUInteger n = [self readCount];
    stop = MIN(stop, n);
    NSUInteger nthreads = threads ? threads : [TTIOThreads resolve:nil];
    if (!_blockTable || nthreads <= 1 || start >= stop)
        return [self iterReadsFrom:start to:stop error:error usingBlock:block];
    TTIOThreadPool *pool = [TTIOThreadPool poolWithThreads:nthreads];
    NSUInteger bFirst = [_blockTable blockFor:start], bLast = [_blockTable blockFor:stop - 1];
    NSMutableDictionary<NSNumber *, TTIOInFlightView *> *pending = [NSMutableDictionary dictionary];
    NSCondition *cond = [NSCondition new];
    void (^submit)(NSUInteger) = ^(NSUInteger b) {
        if (b > bLast || pending[@(b)]) return;
        NSError *e = nil;
        TTIOBlockView *h = [self _materialiseHandle:b error:&e];    /* storage reads, this thread */
        TTIOInFlightView *f = [TTIOInFlightView new];
        pending[@(b)] = f;
        if (!h) { f.error = e; f.done = YES; return; }
        [pool.queue addOperationWithBlock:^{
            NSError *ie = nil;
            TTIOGenomicRun *v = [TTIOGenomicRun openFromGroup:h.group name:_name
                                            referenceResolver:[self _resolverForViews] error:&ie];
            if (v && [v readCount] > 0) [v readAtIndex:0 error:&ie];      /* warm every channel cache */
            [cond lock]; f.view = v; f.handle = h; f.error = ie; f.done = YES; [cond broadcast]; [cond unlock];
        }];
    };
    for (NSUInteger b = bFirst; b <= MIN(bLast, bFirst + nthreads - 1); b++) submit(b);
    BOOL halted = NO, ok = YES;
    NSUInteger i = start;
    for (NSUInteger b = bFirst; b <= bLast && i < stop && !halted; b++) {
        TTIOInFlightView *f = pending[@(b)];
        [cond lock]; while (!f.done) [cond wait]; [cond unlock];
        [pending removeObjectForKey:@(b)];
        if (!f.view) { if (error) *error = f.error; ok = NO; break; }
        submit(b + nthreads);
        NSUInteger r0 = (NSUInteger)[_blockTable readStartAt:b];
        NSUInteger bEnd = MIN(r0 + (NSUInteger)[_blockTable nReadsAt:b], stop);
        for (NSUInteger j = i; j < bEnd && !halted; j++) {
            NSError *re = nil;
            TTIOAlignedRead *r = [f.view readAtIndex:j - r0 error:&re];
            if (!r) { if (error) *error = re; ok = NO; halted = YES; break; }
            block(r, j, &halted);
        }
        [f.handle discard];
        i = bEnd;
    }
    [pool close];
    for (TTIOInFlightView *f in pending.allValues) { [cond lock]; while (!f.done) [cond wait]; [cond unlock]; [f.handle discard]; }
    return ok;
}
```

(`_materialiseHandle:error:` = the `TTIOBlockView materialiseBlock:...` call factored out of `_blockView:error:` together with the name-table read; `TTIOInFlightView` is a private class with `view`, `handle`, `error`, `done`.) The 4-arg `iterReadsFrom:to:error:usingBlock:` calls the 5-arg form with `threads:0`... no: it keeps its serial body, and the exporters call the threaded form with `[TTIOThreads resolve:nil]`; the threaded form falls back to the serial body when `nthreads <= 1`.

`TTIOAcquisitionRun`: `channelRange:start:count:threads:error:` — in the FDZ branch, when the range spans more than one block and `threads > 1`, read every block's bytes on this thread, decode each on the queue (`[TTIOFloatDeltaZstd decodeBlockBytes:table:index:]`), wait in order, concatenate; the 4-arg form resolves; `iterSpectraWithBatch:threads:error:usingBlock:` passes `threads` down.

- [ ] **Step 4: Run the ObjC suite**

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/objc && ./build.sh check > /tmp/c-bp2.log 2>&1; echo EXIT=$?; grep -aE "build.sh:|Failed (test|set)" /tmp/c-bp2.log | head`
Expected: `build.sh: all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add objc/Source objc/Tests
git commit -m "objc: SpectralStreamWriter queue, readers decode ahead"
```

---

### Task 10: Memory window test, timings, docs

**Files:**
- Modify: `python/tests/test_streaming_memory.py` (or the file holding the `-Dttio.slow`-style memory ceiling test; Python has `test_importers_stream_genomic.py::test_memory_ceiling` — extend that one)
- Modify: `CHANGELOG.md` (`[Unreleased]` / Changed), `docs/format-spec.md` (one sentence in 10.12: threads do not change the file), `python/src/ttio/genomic/stream_writer.py` and `spectral_stream_writer.py` docstrings (window and memory), `tools/perf/compression_suite/README.md` (the block working sets the window multiplies)
- Test: the memory test

- [ ] **Step 1: Memory window test**

Append to the Python memory test file:

```python
@pytest.mark.slow
def test_threaded_writer_memory_window(tmp_path):
    """RSS with threads=8 stays under 9 times the one-block working set."""
    import resource, subprocess, sys, textwrap
    from test_genomic_stream_writer import _big_synthetic_run
    script = textwrap.dedent('''
        import resource, sys
        sys.path.insert(0, "tests")
        from test_genomic_stream_writer import _big_synthetic_run, _write_with_threads
        from pathlib import Path
        run = _big_synthetic_run(n=200_000)
        _write_with_threads(Path(sys.argv[1]), run, int(sys.argv[2]), block_reads=20_000)
        print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    ''')
    def rss(threads):
        out = subprocess.run([sys.executable, "-c", script, str(tmp_path), str(threads)],
                             capture_output=True, text=True, check=True, cwd=str(Path(__file__).resolve().parents[0].parent))
        return int(out.stdout.strip().splitlines()[-1])
    one, eight = rss(1), rss(8)
    assert eight < 9 * one, (one, eight)
```

Run: `cd /home/toddw/TTI-O.worktrees/block-parallel/python && TTIO_RANS_LIB_PATH=... $PYT tests/test_importers_stream_genomic.py -q -k memory_window -m slow` (add `-o markers=slow` if the marker is not registered; check `pyproject.toml`'s pytest markers). Expected: pass, and note the two RSS numbers.

- [ ] **Step 2: Timings**

Run, from the worktree, with the worktree's native lib and `sys.path` pointing at the worktree's `python/src` (a one-line runner script `bench_threads.py` in `/tmp` that imports `ttio.tools.workbench_cli.main` after `sys.path.insert(0, "python/src")` and calls `encode` on `~/ttio-bench-data/prepared/na12878_chr22_lowcov/na12878.chr22.lean.mapped.11col.bam` with `--reference ~/ttio-bench-data/raw/reference/hs37d5.fa`, then `export` with `REF_PATH` set), for `--threads 1` and `--threads 24`, timing each with `/usr/bin/time -f "%e s %M KB"`. Do the same on the WES slice (`hg19.fa`) and the HG002 2x250 slice (`GRCh38_full_plus_hs38d1.fa`, 1.6 GB, expect minutes) — only if the compression benchmark in `/home/toddw/TTI-O` is not encoding at that moment (`pgrep -f suite.py`); otherwise time only the two small slices and say so.

Record: corpus, threads, encode s, decode s, peak RSS, and that the outputs are byte-identical (`cmp` the two `.tio` files after removing nothing: HDF5 files written by the same code with the same content are identical; if `cmp` differs, `h5diff` them and report only dataset/attribute differences, which must be none).

- [ ] **Step 3: Docs**

`CHANGELOG.md` under `[Unreleased]` / `### Changed`:

```markdown
- **Block-parallel encode and decode.** `GenomicStreamWriter`, `SpectralStreamWriter`
  and the sequential readers (`iter_reads`, exporters, `iter_spectra`, `channel_range`)
  in Python, Java and ObjC run codec work for several blocks at once: writers do
  the ordered work (chromosome ids, reference md5, sequence number) on the caller's
  thread, encode blocks on a pool of `TTIO_THREADS` workers (unset or 0 = cores
  minus 8, 1 = the serial path) with at most `threads + 1` blocks in flight, and
  append them in order from the caller's thread, so the file is byte for byte the
  serial writer's; readers decode the next `threads` blocks ahead. `threads=` on the
  writers and readers and `--threads` on the CLIs override the environment. While a
  pool exists the FQZCOMP auto-tune runs its candidates in sequence
  (`ttio_m94z_set_autotune_threads`). Measured on the chr22 slices: <numbers from
  Step 2>.
```

`docs/format-spec.md` 10.12.3, after the "Codec consequences" paragraph: "Blocks are independent, so writers may encode several at once; the file does not record thread counts and is identical whatever the count."

Docstrings: `GenomicStreamWriter` and `SpectralStreamWriter` class docstrings state the window and the memory rule (`(threads + 1)` × block working set; about 1.8 GB per 1 M-read block of 100 bp reads and 10 GB for 10.6 M reads of 250 bp, from the compression suite's smoke run).

Compression suite README, under "Smoke run": one sentence that TTI-O rows there ran with `TTIO_THREADS=1` (the suite's threads = 1 rule) and the block working sets it quotes are what the window multiplies.

- [ ] **Step 4: Full suites**

Run: Python `cd python && TTIO_RANS_LIB_PATH=... $PYT tests -q -x --ignore=tests/conformance --ignore=tests/validation` (the conformance/validation cells need the other SDKs' builds; run `tests/conformance/test_transport_v0_11_xlang.py -k GENOMIC_RUNS` too), Java `mvn -q -o test -Dhdf5.native.path=...`, ObjC `./build.sh check`, native `ctest`. Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add -A CHANGELOG.md docs python tools/perf/compression_suite/README.md
git commit -m "docs: block-parallel codecs, thread knob, window and timings"
```

Then push `block-parallel-codecs` and open the PR (five-part body under 200 words: what changed, the knob and window, byte identity, tests, timings) after rebasing onto main once #299 is merged.

---

## Self-review

- Spec §2 knob: Tasks 2 (Python), 6 (Java), 8 (ObjC): env, per-call argument, CLI flag, `cores - 8` default, `1` = serial; auto-tune stand-down: Task 1 setter, Tasks 2/6/8 pool scopes.
- Spec §3 writer pipeline: Tasks 3/4 (Python), 6/7 (Java), 8/9 (ObjC): ordered work first (register chromosomes helper — same order in all three, tested), submit, ordered drain, window `threads + 1`, caller-thread storage, `threads == 1` inline; MS writer per FDZ block; LazyReference lock.
- Spec §4 reader pipeline: Tasks 5, 7, 9: storage reads on the caller thread, decode on the pool, window `threads`, random access untouched.
- Spec §5 pools: per SDK, kernel API unchanged (Task 1 adds only the setter).
- Spec §6 verification: byte-identity tests in every writer task; reader equality tests; memory window (Task 10); knob round trips (Tasks 2/6/8); timings and CHANGELOG (Task 10); full suites (Task 10).
- Names: `resolve_threads`/`pool_context` (Py), `Threads.resolve`/`Threads.pool`/`PoolScope` (Java), `+[TTIOThreads resolve:]`/`TTIOThreadPool` (ObjC); `register_block_chromosomes` / `registerBlockChromosomes` / `registerBlockChromosomes:intoMap:`; `_drain(block_until)` / `drain(blockUntil)` / `_drainUntil:error:`; used consistently across tasks.
