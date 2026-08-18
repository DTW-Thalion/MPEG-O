# Block-parallel encode and decode in the stream writers and readers

> **Status (2026-08-18).** Design approved. Implementation follows the plan
> at `docs/superpowers/plans/2026-08-18-block-parallel-codecs.md`.

> **Out of scope:** the transport wire codec (it has its own pool),
> moving the SAM/FASTQ text parsers to C, speculative prefetch for random
> access, SIMD work in the kernels (rANS and REF_DIFF_V2 are 2 percent
> each of the profile).

## 0. Why

A py-spy profile of the NA12878 chr22 low-coverage import (46 s, one
thread) puts 58 percent of the wall time in the FQZCOMP quality coder
and 47 percent of the export in the same coder; rANS, REF_DIFF_V2 and
the name tokenizer are 2 percent each. Those kernels are bit-serial and
cannot be vectorised, but under `blocks_v1` (format-spec 10.12) every
codec restarts per block, so blocks are independent units of work. The
writers and readers in all three SDKs still process them one after the
other on the caller's thread. Encoding and decoding blocks concurrently
gives byte-identical files and identical exports; only the wall clock
changes.

## 1. Goal

`GenomicStreamWriter`, `SpectralStreamWriter` and the sequential read
paths (`iter_reads`, exporters, `iter_spectra`, `channel_range`) in
Python, Java and ObjC run codec work for several blocks at once, with a
documented memory bound, a single knob, and output that is byte for byte
what the one-thread path produces.

## 2. Knob

- `TTIO_THREADS`: unset or `0` means `max(1, cores - 8)` (24 on a
  32-thread machine; the writer leaves cores for the parser, the
  reference reads and the rest of the machine); `1` is the serial path
  the SDKs run today; any other value is the pool size.
- Overridable per call: `threads=` on `GenomicStreamWriter`,
  `SpectralStreamWriter`, `iter_reads`, `iter_spectra`, `channel_range`
  and the BAM/FASTQ/mzML exporters; `--threads N` on `ttio encode`,
  `ttio export`, `TtioEncode`, `TtioExport`, `EncodeCli`, `ExportCli`.
  Same names in all three SDKs; the value resolves once at construction.
- The FQZCOMP auto-tune runs its three candidates on its own threads
  (#299); inside a pool that is oversubscription. The kernel gains
  `ttio_m94z_set_autotune_threads(int)` (process-global, default 3, `1`
  runs the candidates in sequence; the `TTIO_M94Z_SEQUENTIAL` variable
  keeps working as the initial value), with a ctypes, JNI and ObjC
  binding. A writer or reader that opens a pool of more than one worker
  sets it to 1 for the life of the pool and restores it at close; the
  serial path leaves the auto-tune threads on.

## 3. Writer pipeline (genomic and MS, every SDK)

Accumulation into the pending block is unchanged and stays on the
caller's thread. At a block boundary the caller does the ordered work
first, on its own thread:

1. assigns chromosome ids in the shared first-seen map for every name
   the block introduces (`_chrom_map`, `chromNameToId`, the ObjC map);
2. computes the reference md5 once, on the first block (cached sidecar
   since #299);
3. takes the next block sequence number;

then submits `encode_block(block, meta, chrom_map_snapshot, md5)` to the
pool and returns to the caller. The encoders read the chromosome map
(never write it) and the LazyReference; the LazyReference guards its
LRU cache with a lock, since two blocks on the same chromosome read the
same sequence.

Completed blocks are appended to the extendable datasets and the block
index in sequence order, by the caller thread only: on every flush the
writer first drains the completed prefix of the in-flight window, and
`close` drains everything. HDF5 (and the storage providers) therefore see
one thread, and the file is byte for byte the serial writer's output.

Bounded window: at most `threads + 1` blocks are pending or encoding
(one being filled by the caller plus `threads` in the pool). When the
window is full the caller waits on the oldest block, writes it, then
submits. Memory is `(threads + 1)` times the block working set; the
README of the compression suite records the working set per block size
(about 1.8 GB for a 1 M-read block of 100 bp reads, 10 GB for 10.6 M
reads of 250 bp), and the writers' docstrings say so.

`threads == 1` bypasses the pool: flush encodes and writes inline, as
today, so the serial path is the same code with no executor.

The MS writer follows the same shape per FDZ block (`fdz.encode_block`
of 4096 spectra); its ordered work is the running spectrum count and the
FDZ1 header rewritten at close.

## 4. Reader pipeline

Sequential scans decode ahead: `iter_reads(start, stop)`, the BAM/FASTQ
exporters that use it, `iter_spectra` and `channel_range` read the raw
blob bytes of blocks `k+1 .. k+threads` on the caller thread (HDF5 and
the providers stay single-threaded), submit `decode_block(bytes, meta)`
to the pool, and consume the results in order; the window is `threads`.
The decoded block is the same materialised group the serial reader
builds today, so `run[i]` semantics and the codec context (own
chromosome ids from `mate_info/chrom_names`) are untouched.

Random access (`run[i]`, `reads_in_region`, `spectrum(i)`) stays
on-demand with the one-block cache it has now.

## 5. Pools

- Python: `concurrent.futures.ThreadPoolExecutor(threads)`. The codec
  calls are ctypes calls and release the GIL; the block assembly around
  them and the SAM/FASTQ text parsing stay serial, so the expected gain
  is about 3.5 times at 8 threads on the chr22 encode (Amdahl on the
  profile's 15 percent Python share), more once the parser is native.
- Java: `ExecutorService` fixed pool, futures drained in order.
- ObjC: `NSOperationQueue` with `maxConcurrentOperationCount = threads`,
  `NSBlockOperation` per block, results handed back through a
  sequence-ordered array guarded by a lock and a semaphore for the
  window; the writer thread does every HDF5 call.

The C kernel keeps its one-block API; `threadpool.c` is not used here.

## 6. Verification

- Byte identity: the m87 fixture, the 2 M-read synthetic FASTQ and the
  golden mzML written with `threads=1` and `threads=8` are identical
  files (`h5diff` clean, blob md5 equal) in each SDK; the same for
  exports; the golden fixture still decodes; the xlang matrix runs
  unchanged.
- Memory: RSS with `threads=8` on the 1 M-read synthetic stays under
  9 times the measured one-block working set (the window holds).
- Knob: `TTIO_THREADS`, `threads=` and `--threads` each round trip
  through the CLI in every SDK; `threads=1` takes the inline path.
- Timing on the chr22 slices (low coverage, WES, 2x250) recorded in the
  CHANGELOG, one thread against the default.

## 7. Open questions

None at approval time.
