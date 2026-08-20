
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
