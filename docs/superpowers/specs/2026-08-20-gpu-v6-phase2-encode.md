# Phase 2: Vulkan qualities encode

Date: 2026-08-20. Status: draft for review.
Umbrella: `2026-08-20-gpu-engine-v6-design.md`.
Phase 1 (CPU V6) is complete and on branch `gpu-engine-v6`, PR #307,
held as a draft.

Scope decided with Todd: **encode only**, and the engine is used only on
**explicit opt-in**.

## 1. What the spike already settled

`tools/perf/gpu_spike` ran the real V6 segment encoder on the GPU, a
GLSL port of `v6_model.h` and `rc_cram.c`, diffed against the shipped
CPU coder.

- **Byte identity holds.** Identical output in every configuration
  tried: 8 to 4068 chains, segments of 16 Ki to 256 Ki symbols, quality
  alphabets of 6, 49 and 92 symbols. The coder is entirely 32-bit
  integer arithmetic with wraparound, which GLSL reproduces exactly.
  This was the umbrella's riskiest fixed decision and it is now
  evidence. Phase 2 inherits a proven kernel, not a hypothesis.
- **Throughput on this machine does not.** Encoder to encoder at the
  shipped defaults, 1024 chains: 226 MB/s on low-coverage chr22 against
  623 MB/s from 24 CPU threads, and 692 MB/s on NovaSeq against 560.
  The GPU loses on three of four corpora.

Phase 2 proceeds anyway, on a different rationale than the umbrella's:
the engine is selectable, so a machine where the GPU loses simply does
not use it. What Phase 2 ships is a correct, proven-identical encode
path plus the machinery to turn it on where it wins. It does not ship a
throughput claim.

## 2. Corrections to the umbrella spec

Measurement has overtaken several statements in the umbrella. Phase 2
supersedes them:

| Umbrella | Superseded by |
| --- | --- |
| 3.4 writer pins V6 "when the GPU engine is available" | Presence is not benefit. This laptop has a real GPU and using it would produce both larger files and slower encodes. Selection is explicit opt-in (section 3). |
| 5 "One workgroup per segment" | One chain per invocation, warps packed. One-thread workgroups idle 31 of 32 lanes; Phase 0 measured 4.9x from packing. |
| 8 ratio gate "within 2% of V4/V5" | Not met and not meetable: V6 is +5.99% to +6.66% against V4 at the shipped defaults. Comparator re-based to V4 (V5 wins lowcov via a sequence channel V6 does not have). Recorded, accepted, not a Phase 2 gate. |
| 8 throughput gate "must project a gain before Phase 2 proceeds" | The Phase 0 projection it refers to was 10 to 50x optimistic. Taken literally this gate blocks Phase 2. It is replaced by section 8: Phase 2 gates on correctness and records throughput without gating on it. |
| 6 "Decode mirrors encode" | Decode is Phase 3. Phase 2 is encode only. |

## 3. Selection policy

The engine is off unless asked for.

    TTIO_GPU=off      default. No probe, no dlopen, no log line.
    TTIO_GPU=force    initialise the engine; use it if it comes up.
    TTIO_GPU_DEVICE=n physical device index override.
    TTIO_GPU_SLOTS=n  concurrent block slots override.

`force` means force. It does not measure whether the GPU is faster than
the local CPU path, because the caller has asserted that it is. This is
also how the engine gets benchmarked.

**The writer pins V6 only when the engine actually initialised.** If
`TTIO_GPU=force` is set but the library, device or memory is missing,
the run logs one informational line, writes V4 or V5 exactly as today,
and does not fail. Writing V6 with no engine is the worst of both
outcomes: larger files and no speed.

An automatic mode that probes the local machine and enables itself only
when it wins is deliberately out of scope. It needs a probe, a cache
and an invalidation policy, and it should be designed once there is
hardware where the engine is known to win.

### 3.1 The cost that selection does not cover

Mode is per machine; the wire variant is permanent. A machine that
writes V6 produces files 6 to 6.7% larger for every consumer of those
files, forever, and a reader cannot fall back on bytes already written.
Turning the engine on is therefore a storage decision as much as a
throughput one, and the documentation must say so where the knob is
described.

## 4. Engine API

In `native/include/ttio_rans.h`, narrowed from the umbrella's section 4
to encode only:

    typedef struct ttio_engine ttio_engine;

    const ttio_engine *ttio_engine_cpu(void);
    const ttio_engine *ttio_engine_gpu(void);   /* NULL unless forced
                                                 * and healthy */
    const char *ttio_engine_name(const ttio_engine *e);

    struct ttio_engine {
        const char *name;              /* "cpu", "vulkan:<device>" */
        int  (*slots)(void);
        int  (*try_acquire)(void);     /* nonblocking; 1 = got a slot */
        void (*release)(void);
        int  (*qual_v6_encode)(const ttio_v6_job *job);
    };

`ttio_v6_job` carries what `ttio_m94z_v6_encode` already computes: the
qualities, the read-length table, the segment plan, the alphabet and
seed table, the parameters, and the output buffer. The segment plan is
derived identically on both engines from the read lengths and S, so the
GPU never re-derives it differently.

`m94z_qual.c` picks the engine per block. Nothing above it knows a GPU
exists, and the three SDKs need no new code beyond one accessor
reporting the active engine name.

## 5. Vulkan backend

- Separate shared library `libttio_gpu_vk.so` / `ttio_gpu_vk.dll`.
  `libttio_rans` dlopens it on first use under `TTIO_GPU=force` only.
  Absence, load failure or an unhealthy device yields
  `ttio_engine_gpu() == NULL` and one log line. Deployments that do not
  set the knob ship nothing extra and behave exactly as today.
- One GLSL compute kernel, compiled to SPIR-V at build time and
  embedded. It is the spike kernel promoted, not a rewrite.
- **One chain per invocation, 32 per workgroup.** Occupancy comes from
  segments per block times blocks in flight.
- Device selection: first discrete device exposing a compute queue,
  overridable. Integrated GPUs are skipped by default; on this machine
  an unqualified enumeration returns the Intel iGPU first.
- **Per-dispatch work must be bounded.** A display-attached GPU applies
  the platform timeout watchdog: the spike lost a device to
  `VK_ERROR_DEVICE_LOST` after about two seconds. The backend splits a
  block into as many dispatches as needed to keep each one under a
  configurable ceiling, defaulting to roughly half a second of measured
  work, and treats device loss as a spill to CPU rather than an error.
- Slot sizing from the measured working set per in-flight block:

      qualities_in + chains_out + N * 2^C * (2A + 2) * 2

  where A is the block's alphabet size. Model memory dominates and is
  the binding constraint: at C = 11 it is 0.06 MB per segment at A = 6
  and 0.40 MB at A = 49. Slots are `floor(usable VRAM / working set)`,
  never fewer than 1, overridable.

## 6. Scheduling

Per block the writer calls `try_acquire` on the GPU engine; failure
means the CPU engine takes that block immediately. Nothing queues, so
machine throughput is GPU plus all CPU cores, and a saturated or absent
GPU degrades to today's behaviour rather than stalling.

Mixed engines within one file are byte-equivalent by construction,
which section 1 established rather than assumed. Cross-process
fairness is left to the driver; each process caps itself at its own
slot count and no broker exists.

## 7. Build and CI

- The backend builds only when Vulkan headers and a loader are present,
  and is off by default in the standard build. Nothing in the existing
  build gains a Vulkan dependency.
- **Byte identity is a CI gate, not a manual check.** CI runners have no
  GPU, so the kernel runs under a software rasteriser (lavapipe, already
  present in the WSL image) and its output is diffed against the CPU
  coder on fixture blocks. Slow but exact, and it catches a kernel that
  drifts from the CPU model.
- The spike's `v6_ref_dump.c` becomes the fixture generator for that
  gate, which is the one piece of the throwaway spike that survives.

## 8. Gates

Phase 2 ships correctness and records speed. It does not gate on speed,
because the only hardware available is hardware where the engine loses.

1. **Byte identity.** GPU output equals CPU output for every block of
   every reference corpus, and across repeated runs. This gate ships or
   blocks Phase 2.
2. **Fallback.** `TTIO_GPU=off`, missing library, missing device,
   VRAM exhaustion mid-run, and device loss mid-dispatch each produce a
   correct file through the CPU path with no user-visible error, and
   without writing V6 when no engine came up.
3. **Cross-SDK.** A file written with the GPU engine decodes identically
   in Python, Java and Objective-C on a machine with no GPU.
4. **Acceptance.** The 50 GB corpus encodes correctly under
   `TTIO_GPU=force`, byte-identical to the same corpus encoded CPU-only
   with V6. Throughput is recorded in the findings document whatever it
   turns out to be.
5. **Existing suites** stay green: Python, Java, ObjC and the native
   binaries, at the Phase 1 baselines.

## 9. Risks and open questions

- **The engine may never pay off.** Every throughput number comes from a
  laptop RTX 4000 Ada with roughly 256 GB/s of memory bandwidth, and the
  kernel is model-memory-bound. An L40S is about 3.4x that bandwidth, an
  H100 about 13x. Whether the engine wins anywhere is unmeasured, and
  Phase 2 does not answer it. The first server GPU that runs the
  acceptance test answers it.
- **Model memory, not compute, is the ceiling.** Anything that shrinks
  the resident model per chain buys throughput directly. The unexplored
  lever is sharing one model across several segments of a block, which
  would break segment independence and needs its own decision.
- **The ratio cost is permanent per file** (section 3.1).
- Phase 3 remains decode, sequences rANS, and the multi-user soak.

## 10. Out of scope

GPU decode; sequences rANS kernels; an automatic selection mode; any
change to V4 or V5, which are shipped formats and byte-frozen; any
change to the V6 wire format, which Phase 1 settled.
