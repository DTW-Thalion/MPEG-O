# GPU spike (throwaway)

Phase 0 microbenchmark for the M94.Z V6 GPU engine. **Nothing here is
production code.** It is not built by `native/CMakeLists.txt`, is not
run by any test or CI job, and is expected to be deleted once Phase 2
has a real engine. Its only product is the numbers recorded in
`docs/superpowers/plans/2026-08-20-gpu-v6-phase0-findings.md`.

`chain.comp` models the access pattern that dominates V6 encode: one
sequential adaptive-coder chain per invocation, a private context-model
bank per chain, and per symbol a context hash, a table read, an
add-update write and a running-state multiply. There is no entropy
coding, so the throughput it reports is an upper bound.

## Build and run

Phase 0 established that the only Vulkan hardware path on this machine
is native Windows (WSL exposes lavapipe only), so build there. With
MSYS2 ucrt64:

    pacman -S --needed mingw-w64-ucrt-x86_64-vulkan-headers \
        mingw-w64-ucrt-x86_64-vulkan-loader

    gcc -O2 -Wall -o spike.exe spike.c -lvulkan-1
    ./spike.exe

SPIR-V is host independent, so the shader is compiled in WSL and the
generated header copied over:

    glslangValidator -V chain.comp --vn chain_spv -o chain_spv.h

The MSYS2 `mingw-w64-ucrt-x86_64-glslang` package does not run on this
machine: it exits with STATUS_ENTRYPOINT_NOT_FOUND against the ucrt64
runtime, and installing it pulled newer packages onto an older base.
Ubuntu's `glslang-tools` works and produces the same SPIR-V.

The generated `chain_spv.h` and `spike.exe` are build products; do not
commit them.

Output is CSV on stdout: mode, local size, chain count, workgroup
count, symbols per chain, striping flag, best and median wall time over
ten dispatches, symbols per second, and a projected encode rate that
divides the symbol rate by three to allow for real coder arithmetic.
Total work is fixed at 64 Mi symbols for every row so the rows compare
directly. The first and last rows are the same configuration; if they
disagree the machine was not quiet and the run is unusable.

Rows vary three things. The `encode` and `decode` modes select whether
the context sequence is known ahead of the model lookups (encode) or
depends on the value just loaded (decode); `nsym` selects a 48-symbol
stand-in bank or the real 256-symbol V6 alphabet; and `-lane` rows pack
32 chains into a workgroup instead of one, with `-striped` interleaving
the model banks across lanes.
