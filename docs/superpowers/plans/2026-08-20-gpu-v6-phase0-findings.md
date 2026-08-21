
## P0.2 Coding-pattern microbenchmark

`tools/perf/gpu_spike` (throwaway) runs one sequential adaptive-coder
chain per invocation over a private context-model bank, doing per
symbol a context hash, a table read, an add-update write and a running
state multiply. No entropy coding, so every rate below is an upper
bound. Total work is fixed at 64 Mi symbols per row, ten dispatches per
row, best time reported. `proj_MBps` divides the symbol rate by three
to allow for real coder arithmetic, per the plan.

Two shapes are measured, because V6 is not symmetric:

- `encode`: the context sequence is derived from the input qualities
  and is therefore known before any model lookup, so the hardware can
  keep several model loads in flight.
- `decode`: each context depends on the symbol the coder has just
  produced, so every model load sits on the critical path.

`nsym` 48 is a small stand-in bank; `nsym` 256 is the real V6 alphabet,
whose bank is 2 MiB per chain at 2^12 contexts. The 256-symbol rows are
the ones that describe V6.

| mode | chains | wg | sym/chain | nsym | min ms | symbols/s | proj MB/s |
| --- | --- | --- | --- | --- | --- | --- | --- |
| encode | 256 | 256 | 262144 | 48 | 11.328 | 5.92e9 | 1975 |
| encode | 512 | 512 | 131072 | 48 | 6.683 | 1.00e10 | 3347 |
| encode | 2048 | 2048 | 32768 | 48 | 4.241 | 1.58e10 | 5274 |
| encode | 8192 | 8192 | 8192 | 48 | 3.942 | 1.70e10 | 5675 |
| decode | 256 | 256 | 262144 | 48 | 15.274 | 4.39e9 | 1465 |
| decode | 512 | 512 | 131072 | 48 | 8.778 | 7.65e9 | 2549 |
| decode | 2048 | 2048 | 32768 | 48 | 5.125 | 1.31e10 | 4365 |
| decode | 4096 | 4096 | 16384 | 48 | 4.824 | 1.39e10 | 4637 |
| decode | 8192 | 8192 | 8192 | 48 | 4.614 | 1.45e10 | 4848 |
| decode-lane | 2048 | 64 | 32768 | 48 | 3.453 | 1.94e10 | 6479 |
| decode-lane | 4096 | 128 | 16384 | 48 | 1.774 | 3.78e10 | 12608 |
| decode-lane | 8192 | 256 | 8192 | 48 | 0.947 | 7.09e10 | 23617 |
| decode-lane-striped | 8192 | 256 | 8192 | 48 | 0.950 | 7.06e10 | 23547 |
| encode-256sym | 512 | 512 | 131072 | 256 | 5.403 | 1.24e10 | 4140 |
| encode-256sym | 2048 | 2048 | 32768 | 256 | 3.341 | 2.01e10 | 6695 |
| decode-256sym | 512 | 512 | 131072 | 256 | 7.156 | 9.38e9 | 3126 |
| decode-256sym | 2048 | 2048 | 32768 | 256 | 4.126 | 1.63e10 | 5422 |
| encode-256sym-lane | 2048 | 64 | 32768 | 256 | 3.118 | 2.15e10 | 7175 |
| decode-256sym-lane | 2048 | 64 | 32768 | 256 | 3.169 | 2.12e10 | 7058 |

Host to device copy of the 64 MiB quality buffer: 5.467 ms, 12.27 GB/s.

The run is bracketed by a repeated control row. Across four runs the
control landed at 8.755, 8.784, 8.801 and 8.899 ms, a spread of 1.6%,
so the rows above are comparable. The first row of any run is 10 to 40%
slow while clocks ramp; it is a control row for that reason.

### Verdict: go

The relevant target is not the CPU rate itself. Qualities are about 73%
of encode CPU, so even a free qualities codec lifts the machine-wide
318 MB/s to at most 318 / 0.27, about 1.2 GB/s. The engine therefore
has to sustain roughly 1.2 GB/s for qualities to stop being the
bottleneck. The V6-shaped skeleton projects 7.1 GB/s after the 3x coder
discount, about six times the figure it has to beat, and the decode
shape is no longer slower than the encode shape once warps are packed.
There is enough headroom to absorb a real range coder.

### What the numbers change in the Phase 2 design

- One chain per workgroup wastes 31 of every 32 warp lanes. At 8192
  chains, packing 32 chains into a workgroup is 4.9x faster than the
  one-per-workgroup shape (0.947 ms against 4.614 ms), and on the
  V6-shaped 256-symbol rows it is worth 30% on decode (3.169 ms against
  4.126 ms). Chains must be packed one per lane; the plan's implicit
  one-workgroup-per-segment shape is wrong.
- Striping model banks across lanes is not worth doing. Striped and
  flat differ by 0.3%, inside the control spread.
- Model memory, not compute, sets the concurrency ceiling. A real bank
  is 2 MiB per chain at 2^12 contexts and 256 symbols, so the 2048
  chain rows already hold 4 GiB of models. The 8192 chain rows are only
  reachable with the 48-symbol stand-in and do not describe V6. Fewer
  context bits is the knob that buys concurrency, and it trades against
  the P1.5 ratio gate.
- Concurrency cannot come from one block. At the provisional 256 Ki
  segment a 64 Mi symbol block yields 256 chains, which measures 1.5 to
  2.0 GB/s, barely above the 1.2 GB/s target. Reaching the 2048 chain
  rows needs several blocks resident at once, and model memory bounds
  how many.
- Host transfer at 12.27 GB/s is not fatal at a projected 7 GB/s of
  compute, but it is within a factor of two, so transfer must overlap
  compute rather than alternate with it.

### Caveats on the projection

- The skeleton omits the range coder's serial state and its
  data-dependent renormalization and byte emission, which are branchy
  and will diverge across lanes. That is the largest untested risk in
  the projection and the first thing a Phase 2 spike should add.
- These rates are sensitive to how the driver schedules the loop rather
  than to arithmetic. An earlier revision of this same kernel, differing
  only in whether the symbol count was a literal or a specialization
  constant, measured seven times slower because the loads stopped being
  pipelined. Every row above therefore carries a checksum read back from
  the output buffer, and the harness fails if a row produces nothing.
- Nothing here measures compressed output, so nothing here bears on the
  ratio gate.


## Phase 2 spike: the real coder on the GPU

Phase 0 measured a skeleton with no entropy coding and projected
7.1 GB/s. This spike runs the actual V6 segment encoder: a line-by-line
GLSL port of `sm_encode` and `rc_cram_encode`, one chain per invocation,
checked against the shipped CPU coder byte for byte.
`tools/perf/gpu_spike/v6_ref_dump.c` dumps a fixture from the real
library (parameters, alphabet, seeds, read lengths, and the CPU's output
per segment); `v6_spike.c` runs the kernel and diffs the result.

### Byte-identity holds

Every configuration run produced output byte-identical to the CPU
coder: 8 to 4068 chains, segments of 16 Ki, 64 Ki and 256 Ki symbols,
and alphabets of 6 and 49 symbols. Zero length mismatches, zero byte
mismatches, across roughly twelve thousand chains in total. It worked on
the first run of the ported kernel.

That was the design's riskiest fixed decision, and it is now evidence
rather than assumption. It holds because the coder is entirely 32-bit
integer arithmetic with wraparound, which GLSL reproduces exactly; there
is no floating point anywhere in the model or the range coder.

### Throughput is conditional, and Phase 0 was optimistic

Measured on the RTX 4000 Ada, 64 Mi symbols per run, best of three.
The CPU reference is 318 MB/s machine-wide on the 50 GB corpus.

| Corpus | Alphabet | Segment | Chains | Encode |
| --- | --- | --- | --- | --- |
| lowcov | 49 | 256 Ki | 256 | 58.5 MB/s |
| lowcov | 49 | 64 Ki | 256 | 50.3 MB/s |
| lowcov | 49 | 64 Ki | 512 | 81.2 MB/s |
| lowcov | 49 | 64 Ki | 1024 | 140.3 MB/s |
| NovaSeq | 6 | 64 Ki | 256 | 242.9 MB/s |
| NovaSeq | 6 | 64 Ki | 1024 | 700.2 MB/s |
| NovaSeq | 6 | 16 Ki | 2048 | 484.2 MB/s |
| NovaSeq | 6 | 16 Ki | 4068 | 562.8 MB/s |

The best measured configuration is 2.2x the CPU. The worst is 0.44x,
slower than the CPU it is meant to relieve. Phase 0's 7.1 GB/s
projection is 10x optimistic against the best row and 50x against the
worst, so it should not be quoted again.

Three effects explain the spread:

- **Alphabet size dominates.** `sm_encode` finds a symbol by walking the
  frequency array from the front, so it costs on average half the
  alphabet in dependent loads per coded symbol, and the walk length
  varies per lane so a warp waits for its slowest member. Going from 49
  symbols to 6 is worth 5x at equal chain count and segment size. This
  is the single biggest lever and it is a property of the model, not of
  the range coder.
- **Model initialisation is a fixed cost per segment.** Every segment
  writes 2^C entries before coding anything, independent of how long the
  segment is, so short segments amortise it badly: at 16 Ki symbols the
  4068-chain run is slower than the 1024-chain run at 64 Ki. Segment
  size therefore has an optimum rather than being monotonic in either
  direction.
- **Model memory caps concurrency.** At C = 14 and a 49-symbol alphabet
  a chain needs 3.34 MB, so this 12 GB card runs out at roughly 1500
  chains. At 6 symbols it is 524 KB and 4068 chains fit in 2 GB.

### Other constraints found

- A display-attached GPU applies the Windows TDR watchdog: the
  2048-chain lowcov run was killed with `VK_ERROR_DEVICE_LOST` after
  about two seconds. Phase 2 must either bound per-dispatch work or run
  on a GPU with no display attached.
- Host-visible buffers were used throughout here, so these numbers
  include no separate upload step. Phase 0 measured host-to-device at
  12.27 GB/s, which is not the constraint at these rates.

### What this means for Phase 2

The engine is worth building only if the symbol search changes. A model
that costs O(1) or O(log A) per symbol instead of O(A) would lift the
large-alphabet corpora, which are exactly the ones the current design
loses on. That is a change to the coder itself, so the CPU and GPU
implementations have to change together and the wire changes with them
-- which is affordable precisely because V6 is new and unshipped, and
would stop being affordable once anything ships on it.

Failing that, the honest scope for a GPU engine is small-alphabet
corpora only, at a bit over 2x, which does not justify a Vulkan backend.


## Phase 2 spike, second pass: the symbol search was not the bottleneck

The first pass blamed `sm_encode` walking the frequency array, on the
evidence that a 6-symbol alphabet ran 5x faster than a 49-symbol one.
That inference was wrong, or at least incomplete: alphabet size drives
both the walk length and the model size, and it is the model size that
matters.

Replacing the walk with a Fenwick tree (`native/src/v6_model.h`,
O(log A) with a fixed step count) settles it:

| Corpus | Alphabet | Model per chain | sm_model | Fenwick |
| --- | --- | --- | --- | --- |
| NovaSeq | 6 | 0.5 MB | 700.2 MB/s | 565.8 MB/s |
| lowcov | 49 | 3.2 MB | 140.3 MB/s | 134.3 MB/s |
| HiFi | 92 | 5.9 MB | not measured | 82.7 MB/s at 512 chains |

On the GPU the change is a wash on large alphabets and a 19% loss on
the small one. The walk is sequential and hits few cache lines; the
tree walk is scattered and can touch more, and it trades an O(1) update
for an O(log A) one. Throughput instead tracks model bytes per chain
almost inversely, which is what pointed at the real lever.

On the CPU the same change is a clear win, because there the cost is
instruction count rather than scattered access: lowcov +20%, HiFi +8%,
2x250 +2%, NovaSeq -1.5%. It is kept for that reason, and because it is
ratio-neutral.

### Ratio neutrality, confirmed exactly

The range coder advances as `range = (range / tot) * freq`, which never
involves the cumulative frequency, so the interval widths and therefore
the renormalisation count are identical however symbols are ordered.
Only the byte values change. Measured on all four corpora at the same
parameters, the compressed totals are byte-for-byte identical between
the two models: 120456830, 41348162, 76077633 and 70859180.

### The real lever: context bits

Model size is `2^C * (2A + 2) * 2`, and C was the part nobody had
questioned. Holding chains at 1024 on lowcov:

| C | Model | GPU encode | Reference bytes |
| --- | --- | --- | --- |
| 14 | 3200 MiB | 131.6 MB/s | 27912957 |
| 12 | 800 MiB | 194.2 MB/s | 27636100 |
| 10 | 200 MiB | 266.6 MB/s | 26945290 |
| 8 | 50 MiB | 250.3 MB/s | 28908343 |

Smaller is better on both axes at once, down to about C = 10. The
reason is the same one segmentation runs into everywhere: a segment is
a few hundred thousand symbols, and spreading those across 2^14
contexts leaves each one too sparse to learn. V4 can afford a large
context space because it models a whole 64 MiB block.

The Phase 1 sweep never saw this because the plan specified
`Q in 8..12`, so `qbits = 6` was outside the grid from the start. The
default is now Q 6, C = 12, which improves or matches every corpus and
cuts model memory fourfold. See `docs/codecs/m94z_v6.md` section 6.1.

### Where that leaves a GPU engine

Still short. At the new default the GPU reaches roughly 194 MB/s on
lowcov against a CPU that does 318 MB/s machine-wide, and the CPU path
got faster too. C = 10 would reach 267 MB/s at a 1.3 point ratio cost
on NovaSeq, and is still below the CPU.

The remaining gap is per-segment model initialisation, which is a fixed
cost of 2^C entries paid before a segment codes anything, and the
scattered reads into that model during coding. Anything that shrinks
the resident model per chain helps both. Worth trying before committing
to an engine: sharing one model across several segments of the same
block, which would break segment independence and needs a design
decision rather than a spike.

## Phase 2: the engine as built

The engine is implemented and byte-identical on both a software
rasteriser and real hardware. Measured with the shipped defaults
(Q 6, qshift 7, P 4, pshift 4, D 1, seed 256, C = 11), 64 Mi symbols
per run, one chain per invocation, 32 per workgroup.

| Corpus | Alphabet | Chains | GPU encode | CPU encode, 24 threads |
| --- | --- | --- | --- | --- |
| lowcov chr22 | 49 | 256 | 90.1 MB/s | 623 MB/s |
| lowcov chr22 | 49 | 1024 | 228.6 MB/s | 623 MB/s |
| NovaSeq WGS | 6 | 256 | 199.2 MB/s | 522 MB/s |
| NovaSeq WGS | 6 | 1024 | 691.6 MB/s | 522 MB/s |

Every row was byte-identical to the CPU coder: zero length mismatches,
zero byte mismatches, on the RTX 4000 Ada and on lavapipe.

The verdict has not moved. On this machine the engine wins on NovaSeq
and loses by a factor of nearly three on low-coverage chr22, which is
the corpus shape that matters most. Under block-level spill it adds
capacity rather than replacing it, so it is not a regression to enable,
but it does not earn a Vulkan backend on this hardware alone.

What has changed is that the question is now cheap to answer elsewhere.
The engine is behind a knob that defaults to off, the byte-identity
contract is enforced by a CI gate rather than asserted, and running the
acceptance on a server GPU is a configuration change rather than a
project. Memory bandwidth is the variable to watch: the kernel is
model-memory-bound, this part has about 256 GB/s, and an L40S has
roughly 3.4x that.

## Phase 2 acceptance: the engine end to end on Windows

`libttio_rans` and the Vulkan module now build natively on Windows via
MSYS2 ucrt64, and `native/tools/v6_acceptance.c` encodes a corpus
through `ttio_m94z_qual_encode` exactly as a writer does, reporting a
checksum of every byte produced. Run with `TTIO_GPU=off` and again with
`force`, the checksums must match.

Corpus: 512 MB sampled from 70 GB into the real NovaSeq run
(SRR12898326), 6-symbol binned alphabet, nine 64 MiB blocks.

| | CPU | GPU |
| --- | --- | --- |
| encode | 285 MB/s | 171 MB/s |
| checksum | abd0fc856cb01826 | abd0fc856cb01826 |

Byte identity holds through the production path on real hardware, not
only in the fixture harness. Three interleaved rounds agreed to within
1%.

### Two defects the acceptance found that nothing else did

**The kernel hung the device.** The codec passes raw quality bytes in
the job and the CPU coder maps them to dense symbols inside its own
loop; the kernel assumed the mapping had already happened. The fixture
generator writes dense indices, so every earlier test agreed with the
kernel and none of them caught it. Fed a raw byte outside a 6-symbol
alphabet, the model returns a zero frequency, the range coder
multiplies its range by zero, and the renormalisation loop never
terminates: the GPU hangs, the watchdog fires, and the first block dies
with `VK_ERROR_DEVICE_LOST` after 19 seconds. The engine then marks
itself unhealthy and every later block silently goes to the CPU, which
is why the whole run still produced correct output at almost exactly
CPU speed. The kernel now applies the alphabet map itself and clamps
out-of-range symbols, which makes the hang unreachable rather than
merely unlikely.

**The model lived in host memory.** Every buffer was host-visible. The
model and its running totals are pure device-side scratch, touched two
or three times per coded symbol and never by the host, so that put a
PCIe round trip in the coder's inner loop. Making those two device-local
took kernel time from 12.0 s to 2.26 s for the same work, a factor of
5.3, and brought the end-to-end rate from 41.6 MB/s to 171 MB/s. The
remaining kernel time now matches the standalone microbenchmark, so the
engine is no longer paying anything the kernel does not.

### Where the numbers stand

On this machine the engine reaches 0.6x the CPU path. Under block-level
spill that is additive rather than competing, so it raises machine
throughput, but it does not relieve the CPU the way a GPU engine is
supposed to.

Two measurement lessons worth carrying forward. A microbenchmark that
sets up once and dispatches repeatedly hides per-block cost, and a
fixture built by the same assumptions as the code under test cannot
falsify them: both of those flattered the engine until this acceptance
ran. And an engine that fails silently and spills is indistinguishable
from one that works slowly, which is why the engine now records why it
declined.

## Phase 2 acceptance across all three read shapes

Same tool, same method, three interleaved rounds each, agreeing to
within 2%. Every checksum matched its CPU counterpart, and every block
encoded on the GPU (no silent spills).

| Corpus | Alphabet | Model per chain | CPU | GPU | GPU / CPU |
| --- | --- | --- | --- | --- | --- |
| NovaSeq WGS | 6 | 57 KB | 285 MB/s | 171 MB/s | 0.60x |
| lowcov chr22 | 49 | 410 KB | 217 MB/s | 84.8 MB/s | 0.39x |
| HiFi | 92 | 762 KB | 214 MB/s | 62.3 MB/s | 0.29x |

**The GPU is slower than the CPU on every corpus**, and the margin
widens exactly as the alphabet, and therefore the resident model, grows.
Model bytes per chain are `2^C * (2A + 2) * 2`, so a 92-symbol alphabet
carries thirteen times the model of a 6-symbol one, and the engine loses
roughly in proportion. The CPU degrades over the same range too, but
only from 285 to 214 MB/s, because its cost is instruction count rather
than memory traffic.

### The chain count is the remaining lever

The kernel microbenchmark reached 692 MB/s on NovaSeq, four times what
the acceptance measures, and the difference is not overhead: it ran 1024
chains where a production block yields 256. A 64 MiB block at the
default 256 Ki segment holds 256 segments, and 256 chains does not fill
this GPU.

Two ways to raise it, both already measured elsewhere in this document:
smaller segments give more chains per block but cost ratio (128 Ki was
about three points worse than 256 Ki), and several blocks in flight give
more chains at no ratio cost but need a scheduler the engine does not
have, since one queue and one command buffer mean submissions serialise
today.

Neither changes the conclusion on this hardware. Both are worth knowing
before anyone runs this on a server GPU, where the memory bandwidth that
the model traffic is bound by is three to thirteen times higher.

## Multiple blocks in flight, and a correction to every earlier ratio

The engine now carries per-slot resources: each concurrent block gets
its own buffers, descriptor set, command pool, command buffer and
fence. Submission to the single queue is serialised, but waiting is
not, so several blocks genuinely overlap on the device. The acceptance
tool was also changed, because a caller that encodes blocks one after
another cannot fill an engine with more than one slot no matter how
many slots it offers; it now keeps a configurable number of blocks
outstanding and checksums them in block order afterwards.

The engine improved, and saturates almost immediately:

| Corpus | 1 slot | 2 slots | 4 slots |
| --- | --- | --- | --- |
| NovaSeq WGS | 170 MB/s | 225 MB/s | 221 MB/s |
| lowcov chr22 | 84.5 MB/s | 94.7 MB/s | 94.0 MB/s |
| HiFi | 62.6 MB/s | 72.3 MB/s | 71.9 MB/s |

A second block in flight is worth 15 to 32%; a third and fourth are
worth nothing. Two blocks is 512 chains, and that fills this device.

### The correction

**Every GPU-to-CPU ratio quoted earlier in this document was measured
against a CPU encoding blocks sequentially, and is wrong.** Making the
caller concurrent helped the CPU far more than it helped the GPU:

| Corpus | CPU, 1 writer | CPU, 4 writers | GPU, best | GPU / CPU |
| --- | --- | --- | --- | --- |
| NovaSeq WGS | 284.5 MB/s | 879.6 MB/s | 225 MB/s | 0.26x |
| lowcov chr22 | 222.8 MB/s | 481.2 MB/s | 94.7 MB/s | 0.20x |
| HiFi | 206.6 MB/s | 445.6 MB/s | 72.3 MB/s | 0.16x |

The real gap is four to six times, not the 1.7 to 3.4 reported before.

The reason is worth stating plainly, because it is the opposite of what
the design assumed. **V6's segmentation helps the CPU more than it
helps the GPU.** The CPU turns independent segments into work for
however many cores it has, and pays nothing extra in memory traffic for
doing so. The GPU is bound by model bytes per chain, so it saturates at
about 512 chains and then stops improving, while the CPU keeps scaling.

### What this closes

Chain count is no longer the open question. It was the lever that looked
most promising, it has been implemented and measured, and it moves the
engine by under a third while moving the CPU by a factor of three. What
remains is memory traffic per chain: a smaller resident model, or a
device with several times this one's bandwidth. Nothing else measured so
far changes the picture.

## What the CPU actually does, and the reference number

Sweeping threads-per-block against blocks-in-flight, best of three,
same tool and same data:

| threads per block | 1 writer | 2 | 4 | 8 |
| --- | --- | --- | --- | --- |
| 4 | 283 MB/s | 522 | 849 | 1240 |
| 8 | 262 MB/s | 511 | 870 | 1247 |
| 24 | 262 MB/s | 377 | 651 | 948 |

Best measured per corpus:

| Corpus | Best CPU | Configuration | Blocks available |
| --- | --- | --- | --- |
| NovaSeq WGS | 1256 MB/s | 2 threads, 9 writers | 9 |
| HiFi | 616 MB/s | 4 threads, 4 writers | 5 |
| lowcov chr22 | 488 MB/s | 2 threads, 3 writers | 3 |

Two things to read from the table. Concurrency across blocks beats
threads within a block, and 24 threads per block is worse than 4:
that is oversubscription on a 32-thread machine, not a codec limit.
HiFi and lowcov peak lower only because the samples hold 5 and 3
blocks, so they run out of block-level concurrency before they run out
of cores.

**1256 MB/s is the CPU reference for V6 encode on this machine.** It is
a pure encode loop over in-memory data, with no parse, no I/O and no
writer, so it bounds the codec rather than describing a pipeline; the
318 MB/s machine-wide figure quoted elsewhere includes all of that.

Against it the engine's best is 225 MB/s, or 0.18x. Every time the CPU
has been given a fairer comparison it has pulled further ahead, because
segmentation is precisely what a many-core CPU exploits for free while
the GPU saturates on model memory traffic at about 512 chains. Closing
that would take roughly a fivefold improvement, and nothing measured
here offers one.

## Re-checking the thread split on a corpus with more blocks than cores

The earlier sweep used a 512 MB sample, which is nine 64 MiB blocks on a
32-thread machine. Block concurrency was therefore capped by the corpus,
not by the hardware, and the rule fitted to it was wrong. Repeating on a
2 GB sample, 33 blocks:

| writers | segment threads | product | encode |
| --- | --- | --- | --- |
| 2 | 8 | 16 | 489 MB/s |
| 4 | 8 | 32 | 869 MB/s |
| 8 | 4 | 32 | 1038 MB/s |
| 16 | 2 | 32 | 1109 MB/s |
| 24 | 2 | 48 | 1128 MB/s |
| 32 | 1 | 32 | 1487 MB/s |
| 32 | 2 | 64 | 1462 MB/s |
| 32 | 3 | 96 | 1328 MB/s |
| 32 | 4 | 128 | 1143 MB/s |

**`W = cores / 4` is wrong and is withdrawn.** It came from a corpus
where nine blocks was the ceiling, so it never saw what happens when
blocks are plentiful. Throughput keeps climbing with writers to about
one per core: 1487 MB/s at 32 writers against 1038 at the eight that
rule would have chosen, which is 44% left behind.

The corrected reading is simpler than the original. Total concurrency
wants to be near the core count, and the split between blocks and
segments matters much less than the total: 32 writers at one segment
thread and at two are within 2% of each other, while four times the core
count costs a quarter. Prefer writers, because per-block serial work
only overlaps across blocks, and use segment threads for the cores that
writers cannot reach.

An earlier claim in this document, that one segment thread per block is
inherently poor because it measured 663 MB/s, was also wrong. That
figure came from eight writers on a 32-thread machine: the loss was
under-subscription, not the thread count. At 32 writers, one segment
thread is the fastest setting measured.

### What is implemented

V6 now has its own segment-thread count, separate from the auto-tune
candidate count. They had been sharing a knob, which was a mistake: a
writer running blocks on a pool sets the auto-tune count to 1 so three
candidate encodes do not run per worker, and V6 was silently inheriting
that and encoding its segments one after another. The writer sets the
segment count from what the pool leaves spare.

The writer's own pool size still comes from `TTIO_THREADS`, whose
default is `cpu_count - 8`, or 24 here. That measures 1128 MB/s against
1487 at 32. Raising it would change behaviour for V4 and V5 as well as
V6, so it is left alone and flagged rather than adjusted here.

## The defaults, end to end

Both changes measured together: the writer default moving from
`cpu_count - 8` to `cpu_count - 2`, and V6 getting its own segment
thread count instead of inheriting the auto-tune knob that a pool pins
to 1. Best of two runs each, checksums unchanged throughout.

| Corpus | blocks | old: 24 writers, 1 segment thread | new: 30 writers, 2 segment threads | change |
| --- | --- | --- | --- | --- |
| NovaSeq 2 GB | 33 | 1122 MB/s | 1270 MB/s | +13% |
| NovaSeq 512 MB | 9 | 477 MB/s | 938 MB/s | +96% |
| HiFi | 5 | 262 MB/s | 604 MB/s | +131% |
| lowcov | 3 | 140 MB/s | 482 MB/s | +245% |

The gain is smallest where blocks are plentiful and largest where they
are scarce, which is the shape the change was aimed at. A corpus with 33
blocks could already keep 24 writers busy, so it gains only what six
more writers are worth. A corpus with three blocks could never use more
than three, and under the old policy those three had one thread each:
three cores of thirty-two, which is where the 140 MB/s came from.

Most real files sit closer to the small end than the large one, so the
headline is the two to threefold gain rather than the 13%.

The two causes are worth separating, because only one is a tuning
choice. Raising the writer default is a judgement about how much of the
machine to take. Giving V6 its own segment count is a defect fix: the
auto-tune knob means "how many candidate encodes race", a writer with a
pool correctly sets it to 1, and V6 has no candidates, so it was reading
a setting whose meaning did not apply to it and switching off its own
intra-block parallelism as a result.

## Disposition: the engine was not merged

The Vulkan engine described above works. It is byte-identical to the CPU
coder, it spills cleanly, and a CI gate held it to that on every change.
It is not in this tree. It is preserved at the tag
`m94z-v6-vulkan-engine`, together with the Phase 0 spike under
`tools/perf/gpu_spike/` that produced the microbenchmark numbers.

Against the thread defaults that shipped, the gap is wider than the
figures above, which were taken before them:

| Corpus | GPU best | CPU | GPU / CPU |
| --- | --- | --- | --- |
| NovaSeq WGS | 225 MB/s | 1270 MB/s | 0.18x |
| lowcov chr22 | 94.7 MB/s | 482 MB/s | 0.20x |
| HiFi | 72.3 MB/s | 604 MB/s | 0.12x |

The GPU column is not re-measured. The engine saturates at two slots, a
third and fourth were worth nothing, and both thread changes were on the
CPU side, so it does not move.

Three reasons, in order of weight.

**The kernel is bound by model bytes per chain**, which is structural
rather than a tuning miss. The margin widens as the alphabet grows, so
HiFi is the worst row and NovaSeq the best. Large alphabets are the
direction the codec is going, so the workloads that matter most are the
ones the GPU handles worst.

**The GLSL kernel is a second implementation of the bitstream.** Every
V6 change has to be made twice or the byte gate goes red, and V6 changed
four times while it was being written: the dense alphabet, C=11,
histogram seeding, the Fenwick model. That is a standing tax on the part
of the codec that is actually improving.

**It is encode only.** Decode was never built, so it was half a feature
in any case.

What would reopen it is a device with several times this one's memory
bandwidth, since model traffic is what binds. Worth weighing against
that: on a node that has a GPU at all, basecalling and alignment want it
first, and compression is the workload one would deliberately leave on
the CPU.

The engine interface, the `TTIO_GPU` selection and the block-level spill
stay in the tree. They cost nothing with one engine registered, and they
are where a second one would attach.

## Decode, and a correction to the reader change

Every figure above this section is an encode figure: the acceptance tool
encoded and checksummed, which measured half the codec. It now decodes
as well, checking that the qualities and the read lengths both return
identical. Thirty-six runs across four corpora, every one identical.

Decode runs at roughly 0.7 to 0.9 of encode, and is parallel the same
two ways: segments within a block, blocks in flight.

| Corpus | blocks | encode | decode | decode / encode |
| --- | --- | --- | --- | --- |
| lowcov chr22 | 3 | 539 MB/s | 391 MB/s | 0.73 |
| HiFi | 5 | 736 MB/s | 551 MB/s | 0.75 |
| NovaSeq 512 MB | 9 | 1397 MB/s | 1228 MB/s | 0.88 |
| NovaSeq 2 GB | 33 | 1630 MB/s | 1237 MB/s | 0.76 |

### The reader change is correct, and buys nothing measurable

`genomic_run` caps decode-ahead at four blocks and was passing the
uncapped thread count to `pool_context`, which sizes V6's segment
threads from the number of workers. On 32 cores that asked for 2
segment threads across 4 blocks. Passing the window instead asks for 8
across 4.

The thread count rises fourfold. **The throughput does not move.**
Best of six interleaved runs, with a control row that repeats the
before-configuration under a second name:

| Corpus | before | control | after | after vs before | control vs before |
| --- | --- | --- | --- | --- | --- |
| lowcov | 384.1 | 389.9 | 389.6 | +1.4% | +1.5% |
| NovaSeq 2 GB | 810.6 | 804.9 | 819.2 | +1.1% | -0.7% |

The effect is the same size as the drift between two runs of an
identical configuration, so it is not an effect. **Segment threads
beyond two do nothing for decode.** The change is still right — the
parameter means "how many workers", and four workers is what there are
— but it is a correctness fix, not a speed one, and it should not be
described as one.

⛔ A first sweep appeared to show +21% on lowcov. That was noise. On
that corpus the two configurations it compared were *identical* (3
blocks clamps both window values to 3 workers), and they differed by
21%: a control row disagreeing with itself. Single runs on this machine
spread 27 to 47%; only best-of-six brings the drift down to about 1.5%.

### What the window costs, and why it may not matter

Blocks in flight is the real lever, well clear of the noise:

| Corpus | blocks | window 4 | uncapped | gain |
| --- | --- | --- | --- | --- |
| HiFi | 5 | 539 MB/s | 551 MB/s | +2% |
| NovaSeq 512 MB | 9 | 854 MB/s | 1228 MB/s | +44% |
| NovaSeq 2 GB | 33 | 781 MB/s | 1237 MB/s | +58% |

That is not a reason to raise `_READ_AHEAD_BLOCKS`. The window exists
because each block in flight is a decoded block held resident, and
because the consumer is serial: decode-ahead only has to stay ahead of
whoever is reading. These numbers come from a tool that consumes at
memory speed, which no caller iterating reads in Python will do. The
cap binds here and probably does not bind there. Measuring that needs a
reader-level benchmark, not this one.

## The reader, measured: the decode-ahead window is a 3.6x regression

`ttio.tools.genomic_read_bench` iterates a blocks_v1 run end to end,
once per decode-ahead window, with a control row that repeats one
window under a second name. 1.5 M reads of 150 bases, 15 blocks.

| window | best | reads/s | qualities | peak RSS |
| --- | --- | --- | --- | --- |
| 1 | 10.0 s | 150,000 | 22.5 MB/s | 635 MB |
| **2** | **7.4 s** | **200,000** | **30.3 MB/s** | 1083 MB |
| 3 | 12.0 s | 125,000 | 18.7 MB/s | 1859 MB |
| 4 (shipped) | 26.8 s | 57,000 | 8.4 MB/s | 2544 MB |
| 6 | 34.2 s | 39,000 | 6.6 MB/s | 3359 MB |

Control drift 0.1%. **The shipped default is 3.6x slower than a window
of two, and holds 1.5 GB more while doing it.**

### What it is not

The obvious explanations are all measurable, and all wrong:

- **Not redundant work.** `_blocks_materialised` is exactly 15 at every
  window. The same blocks are decoded exactly once each.
- **Not the segment threads.** A window x threads grid over
  {1,2,3,4,6} x {2,4,8} moves by under 1% along the thread axis at
  every window. Native decode threads do not hold the GIL, so they
  cost the consumer nothing.
- **Not garbage collection.** `gc.disable()` for the pass changes
  window 4 by 1%. The memory involved is numpy and HDF5 buffers, which
  the cyclic collector does not walk.
- **Not GIL convoying.** A ten-fold longer `sys.setswitchinterval`
  recovers 8% of a 260% gap.
- **Not swapping.** 31 GB total, 29 free; peak is 3.4 GB.

### What it is

The cost tracks resident memory: **each block in flight costs 700 to
800 MB**, and the time follows that curve rather than any measure of
work. With the machine not swapping, the remaining explanation is
allocation churn — past one or two blocks the working set stops being
recycled by the allocator and every block pays fresh page faults. That
last step is inference; the residency itself is measured.

### Two things worth deciding

**The window should be 2, not 4.** A serial consumer runs at 30 MB/s
against a decoder that does 780 MB/s: one block of lookahead is already
26 times more than it can use. Everything past that is memory held for
nothing, and here it is worse than nothing.

**700 MB resident for a block holding 15 MB of qualities is a 45-fold
blowup**, and is the more interesting number. It is what makes the
window expensive at all. Whatever `materialise_block` builds is far
larger than the data it carries, and the corpus here uses 100 k-read
blocks against a 1 M-read default, so a default-sized block may cost
ten times this. That is worth looking at on its own, before tuning a
window around it.

### And the earlier reader change is confirmed neutral

Forcing `pool_context` to the pre-change and post-change values at the
shipped window, best of three: 26.82 s against 26.71 s, +0.4%. It
matches what `v6_acceptance` said with no consumer attached. The change
is right on its own terms and buys nothing measurable, exactly as
recorded above.
