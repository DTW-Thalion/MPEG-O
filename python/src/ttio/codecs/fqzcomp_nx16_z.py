"""TTI-O M94.Z — CRAM-mimic FQZCOMP_NX16 (rANS-Nx16) reference codec.

This is a NEW codec module, parallel to (and independent from) the M94
v1 implementation in :mod:`ttio.codecs.fqzcomp_nx16`. M94.Z follows the
CRAM 3.1 ``rANS-Nx16`` discipline:

* **Static-per-block** frequency tables (built in a forward pre-pass
  over the input, normalised once to ``T = 4096``, held constant for
  the entire block).
* **L = 2^15**, **B = 16** (16-bit renormalisation chunks),
  ``b·L = 2^31``.
* **N = 4** interleaved rANS states.
* **Bit-pack context** (CRAM-style) — no SplitMix64 hash. Layout:
  12 bits ``prev_q`` | 2 bits position bucket | 1 bit revcomp.

The wire-format magic is ``M94Z`` (replaces M94 v1's ``FQZN``).

This is the **pure-Python prototype** for byte-exact algorithm
validation. Cython acceleration is a follow-on phase (M94.Z.2).

Spec: ``docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md``.

Public API:
    encode(qualities, read_lengths, revcomp_flags, *, params=None) -> bytes
    decode_with_metadata(blob, revcomp_flags=None) -> (qualities, read_lengths, revcomp_flags_used)
"""
from __future__ import annotations

import struct


# ── Wire-format constants ───────────────────────────────────────────────

MAGIC = b"M94Z"
# Legacy version bytes — retained ONLY so decode_with_metadata can detect
# and reject V1/V2/V3 blobs with a clear migration error (the encoders /
# decoders for those versions were removed in v1.0).
VERSION = 1
VERSION_V2_NATIVE = 2  # M94.Z V2: body produced by libttio_rans
VERSION_V3_ADAPTIVE = 3  # M94.Z V3: adaptive Range Coder
VERSION_V4_FQZCOMP = 4  # M94.Z V4: CRAM 3.1 fqzcomp_qual port (the only live version)


try:  # pragma: no cover — extension may be absent
    from ttio.codecs._fqzcomp_nx16_z import _fqzcomp_nx16_z as _ext
    _HAVE_C_EXTENSION = True
except ImportError:  # pragma: no cover
    _HAVE_C_EXTENSION = False
    _ext = None  # type: ignore[assignment]


# ── libttio_rans native library loader (Task 15) ────────────────────────
#
# Three-tier acceleration: native (libttio_rans via ctypes) → Cython
# (_fqzcomp_nx16_z) → pure Python. The native library implements the
# inner rANS hot loop with cpuid-dispatched scalar/SSE4.1/AVX2 kernels.
#
# IMPORTANT scope limits:
#   * The native library produces a SELF-CONTAINED V2 byte format with
#     embedded lane sizes that DOES NOT match the V1 wire format used by
#     the Cython / pure-Python paths. So we cannot simply swap the native
#     entrypoints into the V1 encode/decode dispatch — V1 streams remain
#     canonical and continue to flow through Cython/pure-Python.
#   * What this module currently exposes from the native lib:
#       - the loader (_HAVE_NATIVE_LIB flag, _native_lib handle)
#       - ctypes argtype/restype configuration for the public C API
#       - thin _encode_via_native / _decode_via_native helpers for callers
#         that want to use the V2 native path explicitly
#       - get_backend_name() introspection
#   * Wiring native acceleration into a V2-aware top-level dispatch is a
#     follow-on task once Task 14's V2 encoder/decoder is plumbed through
#     the Python wire layer.

import array  # noqa: E402
import ctypes  # noqa: E402  (kept here so lib loader stays close to flag)
import ctypes.util  # noqa: E402
import os  # noqa: E402

_native_lib = None


def _load_native_lib():
    """Locate and dlopen libttio_rans (.so/.dylib/.dll).

    Search order:
      1. $TTIO_RANS_LIB_PATH (full path or directory containing the lib)
      2. Bare names — letting the dynamic loader use LD_LIBRARY_PATH /
         DYLD_LIBRARY_PATH / PATH (Windows) / RPATH.
      3. ctypes.util.find_library("ttio_rans") as a last resort.

    Returns the CDLL handle on success, ``None`` on failure (caller
    treats absence as "no native acceleration available").
    """
    global _native_lib
    if _native_lib is not None:
        return _native_lib

    candidates: list[str] = []

    env_path = os.environ.get("TTIO_RANS_LIB_PATH")
    if env_path:
        if os.path.isdir(env_path):
            for name in (
                "libttio_rans.so",
                "libttio_rans.dylib",
                "ttio_rans.dll",
                "libttio_rans.dll",
            ):
                candidates.append(os.path.join(env_path, name))
        else:
            candidates.append(env_path)

    candidates.extend([
        "libttio_rans.so",
        "libttio_rans.dylib",
        "ttio_rans.dll",
        "libttio_rans.dll",
    ])

    for name in candidates:
        try:
            _native_lib = ctypes.CDLL(name)
            return _native_lib
        except OSError:
            continue

    path = ctypes.util.find_library("ttio_rans")
    if path:
        try:
            _native_lib = ctypes.CDLL(path)
            return _native_lib
        except OSError:
            pass
    return None


_HAVE_NATIVE_LIB = _load_native_lib() is not None

if _HAVE_NATIVE_LIB:
    _lib = _native_lib

    # int ttio_rans_encode_block(
    #     const uint8_t  *symbols,
    #     const uint16_t *contexts,
    #     size_t          n_symbols,
    #     uint16_t        n_contexts,
    #     const uint32_t (*freq)[256],
    #     uint8_t        *out,
    #     size_t         *out_len);
    _lib.ttio_rans_encode_block.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.c_size_t,
        ctypes.c_uint16,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _lib.ttio_rans_encode_block.restype = ctypes.c_int

    # int ttio_rans_decode_block(
    #     const uint8_t  *compressed,
    #     size_t          comp_len,
    #     const uint16_t *contexts,
    #     uint16_t        n_contexts,
    #     const uint32_t (*freq)[256],
    #     const uint32_t (*cum)[256],
    #     const uint8_t  (*dtab)[TTIO_RANS_T],
    #     uint8_t        *symbols,
    #     size_t          n_symbols);
    _lib.ttio_rans_decode_block.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.c_uint16,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
    ]
    _lib.ttio_rans_decode_block.restype = ctypes.c_int

    # int ttio_rans_build_decode_table(
    #     uint16_t        n_contexts,
    #     const uint32_t (*freq)[256],
    #     const uint32_t (*cum)[256],
    #     uint8_t        (*dtab)[TTIO_RANS_T]);
    _lib.ttio_rans_build_decode_table.argtypes = [
        ctypes.c_uint16,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.POINTER(ctypes.c_uint8),
    ]
    _lib.ttio_rans_build_decode_table.restype = ctypes.c_int

    # ttio_rans_pool *ttio_rans_pool_create(int n_threads);
    _lib.ttio_rans_pool_create.argtypes = [ctypes.c_int]
    _lib.ttio_rans_pool_create.restype = ctypes.c_void_p

    # void ttio_rans_pool_destroy(ttio_rans_pool *pool);
    _lib.ttio_rans_pool_destroy.argtypes = [ctypes.c_void_p]
    _lib.ttio_rans_pool_destroy.restype = None

    # int ttio_rans_encode_mt(
    #     ttio_rans_pool *pool,
    #     const uint8_t  *symbols,
    #     const uint16_t *contexts,
    #     size_t          n_symbols,
    #     uint16_t        n_contexts,
    #     size_t          reads_per_block,
    #     const size_t   *read_lengths,
    #     size_t          n_reads,
    #     uint8_t        *out,
    #     size_t         *out_len);
    _lib.ttio_rans_encode_mt.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.c_size_t,
        ctypes.c_uint16,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _lib.ttio_rans_encode_mt.restype = ctypes.c_int

    # int ttio_rans_decode_mt(
    #     ttio_rans_pool *pool,
    #     const uint8_t  *compressed,
    #     size_t          comp_len,
    #     uint8_t        *symbols,
    #     size_t         *n_symbols);
    _lib.ttio_rans_decode_mt.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _lib.ttio_rans_decode_mt.restype = ctypes.c_int

    # const char *ttio_rans_kernel_name(void);
    _lib.ttio_rans_kernel_name.argtypes = []
    _lib.ttio_rans_kernel_name.restype = ctypes.c_char_p

    # ttio_rans_context_resolver: uint16_t (*)(void *user_data, size_t i, uint8_t prev_sym)
    _TTIORansContextResolver = ctypes.CFUNCTYPE(
        ctypes.c_uint16,        # return: context
        ctypes.c_void_p,        # user_data
        ctypes.c_size_t,        # i
        ctypes.c_uint8,         # prev_sym
    )

    # int ttio_rans_decode_block_streaming(
    #     const uint8_t              *compressed,
    #     size_t                      comp_len,
    #     uint16_t                    n_contexts,
    #     const uint32_t            (*freq)[256],
    #     const uint32_t            (*cum)[256],
    #     const uint8_t             (*dtab)[TTIO_RANS_T],
    #     uint8_t                    *symbols,
    #     size_t                      n_symbols,
    #     ttio_rans_context_resolver  resolver,
    #     void                       *user_data);
    _lib.ttio_rans_decode_block_streaming.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),     # compressed
        ctypes.c_size_t,                     # comp_len
        ctypes.c_uint16,                     # n_contexts
        ctypes.POINTER(ctypes.c_uint32),    # freq[n_contexts][256] flat
        ctypes.POINTER(ctypes.c_uint32),    # cum[n_contexts][256] flat
        ctypes.POINTER(ctypes.c_uint8),     # dtab[n_contexts][T] flat
        ctypes.POINTER(ctypes.c_uint8),     # symbols
        ctypes.c_size_t,                     # n_symbols
        _TTIORansContextResolver,            # resolver
        ctypes.c_void_p,                     # user_data
    ]
    _lib.ttio_rans_decode_block_streaming.restype = ctypes.c_int

    class _TTIOM94ZParams(ctypes.Structure):
        _fields_ = [
            ("qbits", ctypes.c_uint32),
            ("pbits", ctypes.c_uint32),
            ("sloc",  ctypes.c_uint32),
        ]

    # int ttio_rans_decode_block_m94z(
    #     const uint8_t  *compressed, size_t comp_len,
    #     uint16_t n_contexts,
    #     const uint32_t (*freq)[256], const uint32_t (*cum)[256],
    #     const uint8_t (*dtab)[TTIO_RANS_T],
    #     const ttio_m94z_params *params, const uint16_t *ctx_remap,
    #     const uint32_t *read_lengths, size_t n_reads,
    #     const uint8_t *revcomp_flags,
    #     uint16_t pad_ctx_dense,
    #     uint8_t *symbols, size_t n_symbols);
    _lib.ttio_rans_decode_block_m94z.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),     # compressed
        ctypes.c_size_t,                     # comp_len
        ctypes.c_uint16,                     # n_contexts
        ctypes.POINTER(ctypes.c_uint32),    # freq[n_contexts][256] flat
        ctypes.POINTER(ctypes.c_uint32),    # cum[n_contexts][256] flat
        ctypes.POINTER(ctypes.c_uint8),     # dtab[n_contexts][T] flat
        ctypes.POINTER(_TTIOM94ZParams),    # params
        ctypes.POINTER(ctypes.c_uint16),    # ctx_remap (sparse->dense)
        ctypes.POINTER(ctypes.c_uint32),    # read_lengths
        ctypes.c_size_t,                     # n_reads
        ctypes.POINTER(ctypes.c_uint8),     # revcomp_flags
        ctypes.c_uint16,                     # pad_ctx_dense
        ctypes.POINTER(ctypes.c_uint8),     # symbols
        ctypes.c_size_t,                     # n_symbols
    ]
    _lib.ttio_rans_decode_block_m94z.restype = ctypes.c_int

    # ── L2 adaptive (V3) bindings — Task #82 Phase B.2 ──────────────────
    # int ttio_rans_encode_block_adaptive(
    #     const uint8_t *symbols, const uint16_t *contexts,
    #     size_t n_symbols, uint16_t n_contexts, uint16_t max_sym,
    #     uint8_t *out, size_t *out_len);
    _lib.ttio_rans_encode_block_adaptive.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.c_size_t,
        ctypes.c_uint16,
        ctypes.c_uint16,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _lib.ttio_rans_encode_block_adaptive.restype = ctypes.c_int

    # int ttio_rans_decode_block_adaptive_m94z(
    #     const uint8_t *compressed, size_t comp_len,
    #     uint16_t n_contexts, uint16_t max_sym,
    #     const ttio_m94z_params *params, const uint16_t *ctx_remap,
    #     const uint32_t *read_lengths, size_t n_reads,
    #     const uint8_t *revcomp_flags, uint16_t pad_ctx_dense,
    #     uint8_t *symbols, size_t n_symbols);
    _lib.ttio_rans_decode_block_adaptive_m94z.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
        ctypes.c_uint16,
        ctypes.c_uint16,
        ctypes.POINTER(_TTIOM94ZParams),
        ctypes.POINTER(ctypes.c_uint16),
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_uint16,
        ctypes.POINTER(ctypes.c_uint8),
        ctypes.c_size_t,
    ]
    _lib.ttio_rans_decode_block_adaptive_m94z.restype = ctypes.c_int

    # ── L2.X V4 (CRAM 3.1 fqzcomp_qual) bindings — Stage 2 Task 11 ──────
    # int ttio_m94z_v4_encode(
    #     const uint8_t  *qual_in, size_t n_qualities,
    #     const uint32_t *read_lengths, size_t n_reads,
    #     const uint8_t  *flags,
    #     int             strategy_hint,
    #     uint8_t         pad_count,
    #     uint8_t        *out, size_t *out_len);
    _lib.ttio_m94z_v4_encode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),     # qual_in
        ctypes.c_size_t,                     # n_qualities
        ctypes.POINTER(ctypes.c_uint32),    # read_lengths
        ctypes.c_size_t,                     # n_reads
        ctypes.POINTER(ctypes.c_uint8),     # flags
        ctypes.c_int,                        # strategy_hint
        ctypes.c_uint8,                      # pad_count
        ctypes.POINTER(ctypes.c_uint8),     # out
        ctypes.POINTER(ctypes.c_size_t),    # out_len
    ]
    _lib.ttio_m94z_v4_encode.restype = ctypes.c_int

    # int ttio_m94z_v4_decode(
    #     const uint8_t  *in, size_t in_len,
    #     uint32_t       *read_lengths, size_t n_reads,
    #     const uint8_t  *flags,
    #     uint8_t        *out_qual, size_t n_qualities);
    _lib.ttio_m94z_v4_decode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),     # in
        ctypes.c_size_t,                     # in_len
        ctypes.POINTER(ctypes.c_uint32),    # read_lengths (out)
        ctypes.c_size_t,                     # n_reads
        ctypes.POINTER(ctypes.c_uint8),     # flags
        ctypes.POINTER(ctypes.c_uint8),     # out_qual
        ctypes.c_size_t,                     # n_qualities
    ]
    _lib.ttio_m94z_v4_decode.restype = ctypes.c_int
else:
    _lib = None
    _TTIORansContextResolver = None
    _TTIOM94ZParams = None


def _native_kernel_name() -> str:
    """Return the native kernel name (``"scalar"``/``"sse4.1"``/``"avx2"``).

    Returns the empty string when the native library is not available.
    """
    if not _HAVE_NATIVE_LIB:
        return ""
    raw = _lib.ttio_rans_kernel_name()
    if raw is None:
        return ""
    return raw.decode("ascii", errors="replace")


def get_backend_name() -> str:
    """Return the active inner-loop backend.

    One of:
        ``"native-<kernel>"``  e.g. ``"native-avx2"``  (libttio_rans available)
        ``"cython"``           (Cython extension available)
        ``"pure-python"``      (fallback)

    Selection precedence is determined at module-import time. Note that
    the V1 M94.Z encode/decode top-level functions currently always
    dispatch via Cython/pure-Python regardless of native availability —
    this introspector just reports the *highest tier loaded*. A V2-aware
    encode/decode dispatch will use the native path in a follow-on task.
    """
    if _HAVE_NATIVE_LIB:
        kernel = _native_kernel_name() or "unknown"
        return f"native-{kernel}"
    if _HAVE_C_EXTENSION:
        return "cython"
    return "pure-python"


# SAM bit 4 = SAM_REVERSE; the V4 native API consumes SAM-compatible flag
# bytes. revcomp_flags inputs are 0/1 in this module — translate.
_SAM_REVERSE = 0x10


def _encode_v4_native(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    pad_count: int,
    strategy_hint: int = -1,
) -> bytes:
    """V4 (CRAM 3.1 fqzcomp_qual) encode via libttio_rans.

    Wraps :c:func:`ttio_m94z_v4_encode`. The native side handles header
    packing (magic, version, RLT deflate, cram_body_len) and body
    compression in one call.

    Args:
        qualities: concatenated Phred quality bytes (length must equal
            ``sum(read_lengths)``).
        read_lengths: per-read length list.
        revcomp_flags: parallel list of 0/1; translated to SAM_REVERSE
            (bit 4) for the native flags byte array.
        pad_count: 0..3 (V3 convention; carried in flags bits 4-5 of
            the V4 outer header).
        strategy_hint: -1 = auto-tune (default), 0..4 = preset.
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "_encode_v4_native called but libttio_rans is not available"
        )

    n_qualities = len(qualities)
    n_reads = len(read_lengths)
    if len(revcomp_flags) != n_reads:
        raise ValueError(
            f"revcomp_flags length {len(revcomp_flags)} != "
            f"read_lengths length {n_reads}"
        )

    # Marshal qual_in.
    if n_qualities:
        qual_buf = (ctypes.c_uint8 * n_qualities).from_buffer_copy(bytes(qualities))
    else:
        qual_buf = None

    # Marshal read_lengths as uint32.
    if n_reads:
        _rl = array.array('I', read_lengths)
        rl_buf = (ctypes.c_uint32 * n_reads).from_buffer(_rl)
        # SAM-style flag bytes: bit 4 = SAM_REVERSE.
        _flags = array.array('B', [
            (_SAM_REVERSE if (v & 1) else 0) for v in revcomp_flags
        ])
        flags_buf = (ctypes.c_uint8 * n_reads).from_buffer(_flags)
    else:
        rl_buf = None
        flags_buf = None

    # Output capacity: V4 outer header overhead (~30 bytes) + RLT (deflated,
    # bounded by 4*n_reads) + cram body (worst case ~ qualities + slack).
    out_cap = 64 + 4 * n_reads + n_qualities * 2 + 1024
    out_buf = (ctypes.c_uint8 * out_cap)()
    out_len = ctypes.c_size_t(out_cap)

    rc = _lib.ttio_m94z_v4_encode(
        qual_buf,
        ctypes.c_size_t(n_qualities),
        rl_buf,
        ctypes.c_size_t(n_reads),
        flags_buf,
        ctypes.c_int(strategy_hint),
        ctypes.c_uint8(pad_count & 0x3),
        out_buf,
        ctypes.byref(out_len),
    )
    if rc != 0:
        raise RuntimeError(f"ttio_m94z_v4_encode failed: rc={rc}")
    return bytes(out_buf[:out_len.value])


def _decode_v4_via_native(
    encoded: bytes,
    revcomp_flags: list[int] | None,
) -> tuple[bytes, list[int], list[int]]:
    """Decode a V4 (CRAM 3.1 fqzcomp_qual) M94.Z blob.

    Pipeline:
      1. Parse the V4 outer header inline (magic, version, num_qualities,
         num_reads, pad_count) — needed to size the output buffers.
      2. Allocate read_lengths[num_reads] (uint32) — the native call
         decompresses the RLT into this array.
      3. Translate revcomp_flags 0/1 → SAM_REVERSE bytes; default to
         all-zero if caller passed None.
      4. Allocate out_qual[num_qualities].
      5. Call :c:func:`ttio_m94z_v4_decode`.
    """
    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "_decode_v4_via_native called but libttio_rans is not available"
        )

    # Inline parse of the V4 outer header (fields per m94z_v4_wire.h):
    #   0..4   magic = "M94Z"
    #   4      version = 4
    #   5      flags  (bits 4-5 = pad_count)
    #   6..14  num_qualities (uint64 LE)
    #  14..22  num_reads     (uint64 LE)
    #  22..26  rlt_compressed_len (uint32 LE) — only needed by native
    if len(encoded) < 26:
        raise ValueError("M94Z V4: header truncated")
    if encoded[:4] != MAGIC:
        raise ValueError(
            f"M94Z V4 bad magic: {encoded[:4]!r}, expected {MAGIC!r}"
        )
    if encoded[4] != VERSION_V4_FQZCOMP:
        raise ValueError(
            f"M94Z V4: expected version {VERSION_V4_FQZCOMP}, got {encoded[4]}"
        )
    flags_byte = encoded[5]
    # pad_count occupies bits 4-5 of flags (matches V3 convention; see
    # m94z_v4_wire.h §header layout).
    _pad_count = (flags_byte >> 4) & 0x3  # noqa: F841 — informational only
    num_qualities = struct.unpack_from("<Q", encoded, 6)[0]
    num_reads = struct.unpack_from("<Q", encoded, 14)[0]

    if num_qualities > (1 << 40):
        raise ValueError(
            f"M94Z V4: implausible num_qualities {num_qualities}"
        )
    if num_reads > (1 << 32):
        raise ValueError(
            f"M94Z V4: implausible num_reads {num_reads}"
        )

    if revcomp_flags is None:
        revcomp_flags = [0] * num_reads
    elif len(revcomp_flags) != num_reads:
        raise ValueError(
            f"revcomp_flags length {len(revcomp_flags)} != "
            f"num_reads {num_reads}"
        )

    # Empty-run short-circuit (Phase 2c): the v1.0 encoder synthesises
    # a minimal 26-byte header for n_qualities==0; mirror that in
    # decode so we don't dispatch to the native fqzcomp_qual core
    # which rejects zero-length inputs.
    if num_qualities == 0 and num_reads == 0:
        return b"", [], list(revcomp_flags)

    in_buf = (ctypes.c_uint8 * len(encoded)).from_buffer_copy(bytes(encoded))
    out_buf = (ctypes.c_uint8 * num_qualities)()

    if num_reads:
        _rl = array.array('I', [0] * num_reads)
        rl_buf = (ctypes.c_uint32 * num_reads).from_buffer(_rl)
        _flags = array.array('B', [
            (_SAM_REVERSE if (v & 1) else 0) for v in revcomp_flags
        ])
        flags_buf = (ctypes.c_uint8 * num_reads).from_buffer(_flags)
    else:
        _rl = array.array('I')
        rl_buf = None
        flags_buf = None

    rc = _lib.ttio_m94z_v4_decode(
        in_buf,
        ctypes.c_size_t(len(encoded)),
        rl_buf,
        ctypes.c_size_t(num_reads),
        flags_buf,
        out_buf,
        ctypes.c_size_t(num_qualities),
    )
    if rc != 0:
        raise RuntimeError(f"ttio_m94z_v4_decode failed: rc={rc}")

    read_lengths = list(_rl) if num_reads else []
    return bytes(out_buf), read_lengths, list(revcomp_flags)


def encode(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    *,
    v4_strategy_hint: int = -1,
    # Legacy keyword arguments accepted but ignored (Phase 2c: V1/V2/V3
    # encoders deleted; only V4 remains). Surface a deprecation message
    # below to make the removal visible to callers.
    context_params: object | None = None,
    prefer_native: bool | None = None,
    prefer_v3: bool | None = None,
    prefer_v4: bool | None = None,
) -> bytes:
    """Top-level M94.Z encoder — V4 (CRAM 3.1 fqzcomp_qual port) only.

    v1.0 reset (Phase 2c): the V1 (pure-Python static rANS), V2
    (native-body) and V3 (adaptive Range Coder) encoder paths were
    removed. V4 is the only encoded version. The native libttio_rans
    library is required.

    Empty-run case: V4 native rejects n_qualities==0 (the htscodecs
    fqzcomp_qual core requires at least one symbol); when there are
    no qualities, the encoder returns a minimal V4-tagged blob with
    a zero-length body so readers can still dispatch by version byte.

    Args:
        qualities: concatenated Phred quality byte stream.
        read_lengths: per-read length list (sum must equal
            len(qualities)).
        revcomp_flags: parallel list of 0/1.
        v4_strategy_hint: -1 = auto-tune (default), 0..4 = preset for
            the V4 fqzcomp_qual encoder.
        context_params, prefer_native, prefer_v3, prefer_v4: accepted
            for backward-compatible call sites only — the encoder
            always emits V4 in v1.0.

    Returns:
        On-wire byte stream tagged with version byte 4
        (``VERSION_V4_FQZCOMP``).
    """
    if not isinstance(qualities, (bytes, bytearray, memoryview)):
        raise TypeError("qualities must be bytes-like")
    qualities = bytes(qualities)
    if len(read_lengths) != len(revcomp_flags):
        raise ValueError(
            f"read_lengths ({len(read_lengths)}) != revcomp_flags "
            f"({len(revcomp_flags)})"
        )
    total = sum(read_lengths)
    if total != len(qualities):
        raise ValueError(
            f"sum(read_lengths) ({total}) != len(qualities) "
            f"({len(qualities)})"
        )

    if not _HAVE_NATIVE_LIB:
        raise RuntimeError(
            "FQZCOMP_NX16_Z V4 encode requires libttio_rans (set "
            "TTIO_RANS_LIB_PATH or install the native library). The "
            "V1/V2/V3 fallbacks were removed in v1.0."
        )

    n = len(qualities)
    pad_count = (-n) & 3

    if n == 0:
        # Empty run: synthesise a minimal V4 outer header so the
        # reader can still detect the version byte. Layout per
        # m94z_v4_wire.h: magic(4) + version(1) + flags(1)
        # + num_qualities(8) + num_reads(8) + rlt_compressed_len(4)
        # + (RLT body, empty here) + (cram body, empty here).
        flags_byte = (pad_count & 0x3) << 4
        return (
            MAGIC
            + bytes([VERSION_V4_FQZCOMP, flags_byte])
            + struct.pack("<Q", 0)   # num_qualities
            + struct.pack("<Q", 0)   # num_reads
            + struct.pack("<I", 0)   # rlt_compressed_len
        )

    return _encode_v4_native(
        qualities, list(read_lengths), list(revcomp_flags),
        pad_count, strategy_hint=v4_strategy_hint,
    )



def decode_with_metadata(
    encoded: bytes,
    revcomp_flags: list[int] | None = None,
) -> tuple[bytes, list[int], list[int]]:
    """Decode an M94.Z V4 blob.

    v1.0 reset (Phase 2c): only V4 (CRAM 3.1 fqzcomp_qual port) is
    decoded. The V1 (pure-Python static rANS), V2 (native-body) and
    V3 (adaptive Range Coder) reader header dispatches were removed
    — files written with those version bytes surface a clear
    migration error pointing at V4.

    ``revcomp_flags`` must match the encoder's trajectory; ``None``
    is treated as all-zero by V4.
    """
    if len(encoded) < 5:
        raise ValueError("M94Z: encoded too short to read magic+version")
    if encoded[:4] != MAGIC:
        raise ValueError(
            f"M94Z bad magic: {encoded[:4]!r}, expected {MAGIC!r}"
        )
    if encoded[4] == VERSION_V4_FQZCOMP:
        if not _HAVE_NATIVE_LIB:
            raise RuntimeError(
                "M94Z V4 decode requires libttio_rans (set "
                "TTIO_RANS_LIB_PATH or install the native library)"
            )
        return _decode_v4_via_native(encoded, revcomp_flags)

    if encoded[4] in (VERSION, VERSION_V2_NATIVE, VERSION_V3_ADAPTIVE):
        raise ValueError(
            f"FQZCOMP_NX16_Z V{encoded[4]} (M94Z version byte = "
            f"{encoded[4]}) is no longer supported in v1.0; only V4 "
            "(CRAM 3.1 fqzcomp_qual port) is decoded. Re-encode with "
            "v1.0+."
        )
    raise ValueError(
        f"M94Z: unknown version byte {encoded[4]} (only V4 = "
        f"{VERSION_V4_FQZCOMP} is supported in v1.0)"
    )


__all__ = [
    "encode",
    "decode_with_metadata",
    "get_backend_name",
    "MAGIC",
    "VERSION_V4_FQZCOMP",
]
