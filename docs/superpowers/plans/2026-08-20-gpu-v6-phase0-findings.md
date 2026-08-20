# GPU V6 Phase 0 findings

Environment probe for the Phase 2 Vulkan compute engine. Throwaway
measurements; the verdict lines are what Phase 2 planning consumes.

## P0.1 Vulkan dev loop

Probed 2026-08-20 on the development laptop (RTX 4000 Ada Laptop,
12 GB, driver 596.58).

| Environment | Loader | Devices reported | Verdict |
| --- | --- | --- | --- |
| WSL2 Ubuntu 24.04 | libvulkan1 1.3.275 | GPU0 `llvmpipe (LLVM 20.1.2, 256 bits)`, `DRIVER_ID_MESA_LLVMPIPE`, `PHYSICAL_DEVICE_TYPE_CPU`, Mesa 25.2.8, apiVersion 1.4.318 | software only |
| Windows 11 | `vulkan-1.dll` 1.4.321.0 | GPU0 Intel RaptorLake-S Mobile Graphics, `DRIVER_ID_INTEL_PROPRIETARY_WINDOWS`, apiVersion 1.4.323; GPU1 `NVIDIA RTX 4000 Ada Generation Laptop GPU`, `DRIVER_ID_NVIDIA_PROPRIETARY`, driver 596.58, apiVersion 1.4.329, conformance 1.4.3.3 | hardware |

**Verdict: kernel development happens on native Windows.**

No Dozen. `mesa-vulkan-drivers` 25.2.8 on Ubuntu 24.04 ships
asahi, gfxstream, intel, intel_hasvk, lvp, nouveau, radeon and virtio
ICDs; there is no `dzn_icd.json` and no `libvulkan_dzn.so` in the
package, so the D3D12 mapping layer is not reachable even though
`/usr/lib/wsl/lib` provides `libd3d12.so` and `libd3d12core.so`. The
NVIDIA WSL driver package exposes CUDA, NVENC, NVDEC and OptiX into
the container but no Vulkan ICD. WSL Vulkan is therefore CPU emulation
through lavapipe, useful for API correctness and validation layers,
useless for throughput.

Consequences for Phase 2:

- Kernel authoring, profiling and the throughput gates run on Windows
  against the NVIDIA ICD.
- Device selection must skip integrated GPUs by default: on this
  machine an unqualified `vkEnumeratePhysicalDevices` returns the
  Intel iGPU first.
- The Vulkan loader is already installed system-wide by the NVIDIA
  driver, so the LunarG SDK is not a runtime prerequisite. Build-time
  prerequisites are the Vulkan headers, an import library for
  `vulkan-1`, and a GLSL to SPIR-V compiler.
- A WSL build of the engine can still be exercised for correctness
  under lavapipe; it cannot be used for any timing claim.
