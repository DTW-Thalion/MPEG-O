# GPU Engine and M94.Z V6 Design

Date: 2026-08-20. Status: approved direction (Todd, 2026-08-20);
constants marked "Phase 1 fixes" are measured against the gates in
section 8 before any GPU code is written. Planning model: Fable 5;
implementation resumes under Opus 5.

## 1. Problem

Encode and decode are CPU-bound on the qualities codec. Post-sticky
profile (3.7 GB HiFi FASTQ, 24 threads, 211.8 MB/s): the V4 qualities
codec takes ~73% of CPU (ttio_fqzcomp_qual_compress 50.9%,
rc_cram_encode 11.8%, pass-1 stats ~10%), sequences order-1 rANS 13.1%,
parse ~4%. The V4/V5 coders are adaptive: one range-coder state chain
per block, so a 64 MiB block cannot be split across compute units.
Servers will run many users' encodes and decodes concurrently; machines
with GPUs should use them, machines without must run unchanged.

## 2. Decisions (fixed)

- A new wire variant is acceptable; GPU and CPU implementations of the
  new variant must produce identical bytes. Today's V4/V5 formats are
  not GPU targets.
- Vendor-neutral GPU backend from day 1: Vulkan compute (SPIR-V).
  Every Linux GPU vendor ships conformant Vulkan; macOS via MoltenVK
  if ever needed. CUDA-only and SYCL were rejected (vendor lock-in;
  toolchain weight in a plain-C library). Development hardware: RTX
  4000 Ada Laptop (12 GB, driver 596.58), visible from Windows and
  WSL2.
- Compression budget for the new variant: within 1-2% of V4/V5 output
  per corpus class.
- Contention policy: block-level spill. A block encodes on the GPU if
  a slot is free, else on the CPU path; both paths produce the same
  bytes.

## 3. M94.Z V6: segmented adaptive qualities

Outer wire: the existing M94Z container (magic "M94Z", version byte 6,
flags, num_qualities, num_reads, compressed RLT) through m94z_pack_any /
m94z_unpack_any. Decoders dispatch on the version byte as today.

Body layout:

    u8  body_version      (1)
    u8  reserved          (0)
    u16 segment_count     N
    u32 segment_symbols   S (qualities per segment; last segment short)
    u8  model_config[8]   (context-model parameters, section 3.2)
    u32 seg_len[N]        (compressed byte length of each chain)
    ...N independent chain bodies, back to back...

### 3.1 Segmentation

A block's qualities are split into N contiguous segments of S symbols.
Each segment is one independent adaptive range-coder chain: own model,
own coder state, no cross-segment references. Contiguous segments (not
symbol striping) keep the context model local; the only ratio cost is
N model warm-ups per block. seg_len[] makes every chain independently
addressable, so:

- GPU encode/decode: one workgroup per segment.
- CPU encode/decode: one task per segment on the existing pools — V6
  parallelises WITHIN a block on CPU-only machines too.
- Random access improves: a reader can decode only the segments
  covering a slice.

Default S targets ~256 Ki symbols per segment (N = 256 for a 64 MiB
block). Phase 1 fixes S and N against the ratio gate.

### 3.2 Context model

A slimmed V4 model, parameterised by model_config: quality context bits
Q, position bits P, delta bits D (Q+P+D = total context bits C). V4
uses up to 16 context bits; V6 defaults smaller because per-segment
model memory times concurrent segments must fit the device budget:

    model bytes per segment  = 2^C * n_symbols * 2 (u16 stats)
    device envelope          <= 512 MB per in-flight block

C = 12 with 48 symbols is ~0.4 MB per segment, ~100 MB at N = 256.
Phase 1 fixes C/Q/P/D by measuring ratio on the four reference corpora
(HiFi, NovaSeq WGS, 2x250 chr22, lowcov chr22) and stops when the
worst class is within budget. The coder is the existing rc_cram range
coder, unchanged; only the model shrinks and the chain shortens.

### 3.3 Sequences (Phase 3)

The sequences channel gets the same segmentation over the existing
static order-1 rANS: per-segment frequency tables are already
GPU-shaped (DietGPU demonstrates GPU ANS at >100 GB/s). Same body
layout with its own body_version. No new modeling work.

### 3.4 Strategy integration

- Strategy hint 8 forces V6 (kernel + all three SDK hint paths, next
  free value after HINT_V4_AUTO = 7).
- ttio_m94z_qual_stream_strategy returns 8 for a V6 stream.
- Writer policy: when the GPU engine is available the writer pins V6
  for the run (engine-driven, not size-driven — V6 never beats V4 on
  size, so it must not enter the auto-tune size race). Without a GPU
  the default behaviour is exactly today's; V6 on CPU is available by
  explicit hint for machines that want intra-block CPU parallelism.
- TTIO_M94Z_EXHAUSTIVE semantics unchanged.

## 4. Engine API

A small C interface in native/ (declared in ttio_rans.h):

    typedef struct ttio_engine ttio_engine;
    const ttio_engine *ttio_engine_cpu(void);
    const ttio_engine *ttio_engine_gpu(void);   /* NULL if unavailable */

    struct ttio_engine {
        const char *name;                        /* "cpu", "vulkan:<dev>" */
        int  (*slots)(void);                     /* concurrent block slots */
        int  (*try_acquire)(void);               /* nonblocking; 1 = got slot */
        void (*release)(void);
        int  (*qual_v6_encode)(const ttio_v6_desc *in, uint8_t *out,
                               size_t *out_len);
        int  (*qual_v6_decode)(const uint8_t *in, size_t in_len,
                               const ttio_v6_desc *out);
    };

ttio_v6_desc carries the flat buffers (qualities, read_lengths, flags,
optional sequences) plus S/N/model_config. The CPU implementation runs
segments on a pool honouring the existing autotune/threads knobs. The
codec layer (m94z_qual.c) picks the engine per block; nothing above it
knows GPUs exist.

## 5. Vulkan backend

- Separate shared library libttio_gpu_vk.so. libttio_rans dlopens it
  on first probe; absence, load failure, or an unhealthy device probe
  yields ttio_engine_gpu() == NULL and one informational log line.
  Servers without GPUs deploy nothing extra and run unchanged.
- Kernels authored in GLSL compute, compiled to SPIR-V at build time,
  embedded in the .so. One encode kernel and one decode kernel for
  qualities V6 (Phase 3 adds rANS kernels). One workgroup per segment;
  the adaptive chain is sequential within a workgroup, so occupancy
  comes from N segments x in-flight blocks.
- Byte identity with the CPU reference is a hard build gate: the same
  segment bytes in, the same chain bytes out, validated on every
  corpus in CI (software rasterizer lavapipe runs the SPIR-V kernels
  on CPU-only CI runners; slow but exact).
- Device selection: first discrete device with compute queue, override
  TTIO_GPU_DEVICE=index.
- Slot count: floor(usable VRAM / block working set) where the working
  set is qualities in + chains out + N models; override TTIO_GPU_SLOTS.
- Dev-loop note: WSL2 exposes this laptop's NVIDIA device to CUDA but
  Vulkan inside WSL goes through Mesa Dozen (Vulkan-on-D3D12). Phase 0
  measures whether Dozen is usable for kernel development; the
  fallback dev loop is building native/ on native Windows
  (ttio_rans.dll is already a supported loader name).

## 6. Scheduling and multi-user behaviour

- Per block, the writer (or reader) calls try_acquire on the GPU
  engine; failure means the CPU engine takes the block immediately.
  Total machine throughput is GPU + all CPU cores; nobody queues.
- Mixed engines within one file are byte-equivalent by construction.
- Cross-process fairness: each process caps itself at its slot count;
  device-level arbitration between processes is the driver's. No
  broker daemon.
- Decode mirrors encode: V6 streams try the GPU first, spill to CPU.
  V4/V5 streams are CPU-only forever.

## 7. SDK integration

No per-SDK GPU code. The engine lives in libttio_rans; ObjC calls it
directly, Python via ctypes, Java via JNI, exactly like the existing
codec entry points. New FFI surface: hint 8 passes through the
existing hint plumbing (shipped 2026-08-19); stream_strategy already
returns whatever the kernel reports; one new probe function
(ttio_engine_gpu_name()) so SDKs can report which engine is active.

## 8. Gates

- Byte identity: GPU V6 output == CPU V6 output for every block of
  every reference corpus, and across repeated runs. This is the gate
  that ships or blocks Phase 2.
- Ratio: V6 size within 2% of the sticky-tuned V4/V5 size per corpus
  class (target 1%; hard fail at 2%).
- Throughput: Phase 0 microbenchmark must project a per-machine encode
  gain over the 318 MB/s CPU baseline before Phase 2 proceeds; the
  Phase 2 acceptance reruns the 50 GB corpus.
- Fallback: TTIO_GPU=off, missing .so, missing device, and
  VRAM-exhaustion mid-run all produce correct files through the CPU
  path with no user-visible error.
- Cross-SDK: files written with GPU V6 decode identically in Python,
  Java and ObjC on machines with no GPU.
- Contention soak: 4+ concurrent processes encoding and decoding on
  one GPU finish with correct output and no starvation (every process
  makes progress through CPU spill).

## 9. Phases

- Phase 0 — spike (throwaway code): Vulkan dev loop on this machine
  (WSL Dozen vs native Windows), plus a GPU interleaved-rANS
  microbenchmark to project throughput. Output: numbers and a go/no-go.
- Phase 1 — CPU-only V6 (ships standalone): wire format, slimmed model,
  CPU reference engine, segment-parallel encode/decode on the existing
  pools, hint 8 plumbing, ratio validation fixing S/N/C on the four
  corpora, decoders in all three SDKs.
- Phase 2 — Vulkan qualities encode: engine API, libttio_gpu_vk.so,
  encode kernel, byte-identity gate, block-level spill scheduler,
  writer pin policy, 50 GB acceptance.
- Phase 3 — GPU decode + sequences rANS kernels + multi-user soak.

Each phase is its own spec-plan-execute cycle with review between
phases; this document is the umbrella. Phase boundaries are also safe
stopping points: nothing in Phase 1 depends on a GPU existing.

## 10. Rejected alternatives

- CUDA-only: fastest to build, excluded by the vendor-neutral
  requirement.
- SYCL/AdaptiveCpp: C++ toolchain and per-vendor runtimes inside a
  plain-C library; deployment weight without a ratio or speed win.
- WebGPU (wgpu/Dawn): simpler than Vulkan but young for sustained
  compute and weaker kernel-level control (subgroups, memory model).
- Symbol-striped interleaving: destroys context locality; segmented
  chains cost only model warm-up.
- GPU-accelerating today's V4/V5 bytes: a single adaptive chain per
  64 MiB block has no parallelism to expose; matching bytes would
  require emulating the exact serial chain, which is the CPU path.
- Broker daemon for GPU fairness: more moving parts than block-level
  spill; revisit only if driver-level arbitration proves unfair in the
  Phase 3 soak.
