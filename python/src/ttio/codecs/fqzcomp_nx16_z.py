"""TTI-O M94.Z (``FQZCOMP_NX16.Z``) quality-score codec front-end.

This module is a thin Python wrapper over the native ``libttio_rans``
CRAM 3.1 ``fqzcomp_qual`` core. It speaks a single wire format, **V4**
(version byte ``4``, magic ``M94Z``); the earlier V1 (pure-Python static
rANS), V2 (native-body) and V3 (adaptive Range Coder) formats were
removed in the v1.0 reset.

The native library is **required** — there is no pure-Python or Cython
fallback for top-level encode/decode:

* :func:`encode` (``qualities, read_lengths, revcomp_flags, *,
  v4_strategy_hint=-1, ...``) emits only V4 and raises ``RuntimeError``
  when ``libttio_rans`` is not loaded.
* :func:`decode_with_metadata` (``encoded, revcomp_flags=None``) decodes
  V4 blobs and rejects legacy v1/v2/v3 blobs with a clear migration error.

The legacy version-byte constants are retained only so the decoder can
recognise and reject old blobs.
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
VERSION_V4_FQZCOMP = 4  # M94.Z V4: CRAM 3.1 fqzcomp_qual port
VERSION_V5_SEQCTX = 5   # M94.Z V5: sequence-context body; emitted only
                        # when it beats V4 by exact size (spec at
                        # docs/superpowers/specs/2026-08-16-qualities-v5-design.md)


# ── libttio_rans native library loader ──────────────────────────────────
#
# The native libttio_rans library (loaded via ctypes) implements the
# CRAM 3.1 fqzcomp_qual core behind the V4 wire format, with the inner
# rANS hot loop using cpuid-dispatched scalar/SSE4.1/AVX2 kernels. It is
# REQUIRED for top-level encode/decode — there is no pure-Python or
# Cython fallback (those V1/V2/V3 paths were removed in the v1.0 reset).
#
# What this module exposes from the native lib:
#   * the loader (_HAVE_NATIVE_LIB flag, _native_lib handle)
#   * ctypes argtype/restype configuration for the public C API
#   * the V4 encode/decode helpers used by encode()/decode_with_metadata()
#   * get_backend_name() introspection

import array  # noqa: E402
import ctypes  # noqa: E402  (used below for argtype/restype wiring)

from ttio.codecs._native_loader import load_ttio_rans  # noqa: E402

# Single source of truth for native-library discovery. The other v2 codecs
# (ref_diff_v2, mate_info_v2, name_tokenizer_v2) re-import _native_lib /
# _HAVE_NATIVE_LIB from this module, so the loader lives here only.
_native_lib = load_ttio_rans()
_HAVE_NATIVE_LIB = _native_lib is not None

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

    # ── Qualities V5 umbrella (V4 presets + S5/S6 by exact size) ────────
    # int ttio_m94z_qual_encode(
    #     const uint8_t  *qual_in, size_t n_qualities,
    #     const uint32_t *read_lengths, size_t n_reads,
    #     const uint8_t  *flags, const uint8_t *seq_in,
    #     int strategy_hint, uint8_t pad_count,
    #     uint8_t *out, size_t *out_len);
    _lib.ttio_m94z_qual_encode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),     # qual_in
        ctypes.c_size_t,                     # n_qualities
        ctypes.POINTER(ctypes.c_uint32),    # read_lengths
        ctypes.c_size_t,                     # n_reads
        ctypes.POINTER(ctypes.c_uint8),     # flags
        ctypes.POINTER(ctypes.c_uint8),     # seq_in (NULL = V4 only)
        ctypes.c_int,                        # strategy_hint
        ctypes.c_uint8,                      # pad_count
        ctypes.POINTER(ctypes.c_uint8),     # out
        ctypes.POINTER(ctypes.c_size_t),    # out_len
    ]
    _lib.ttio_m94z_qual_encode.restype = ctypes.c_int

    # int ttio_m94z_qual_decode(
    #     const uint8_t *in, size_t in_len,
    #     uint32_t *read_lengths, size_t n_reads,
    #     const uint8_t *flags, const uint8_t *seq_in,
    #     uint8_t *out_qual, size_t n_qualities);
    _lib.ttio_m94z_qual_decode.argtypes = [
        ctypes.POINTER(ctypes.c_uint8),     # in
        ctypes.c_size_t,                     # in_len
        ctypes.POINTER(ctypes.c_uint32),    # read_lengths (out)
        ctypes.c_size_t,                     # n_reads
        ctypes.POINTER(ctypes.c_uint8),     # flags
        ctypes.POINTER(ctypes.c_uint8),     # seq_in (required for V5)
        ctypes.POINTER(ctypes.c_uint8),     # out_qual
        ctypes.c_size_t,                     # n_qualities
    ]
    _lib.ttio_m94z_qual_decode.restype = ctypes.c_int
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
        ``"pure-python"``      (fallback)

    Selection precedence is determined at module-import time; this
    introspector reports the *highest tier loaded*. Top-level V4
    encode/decode require the native library (``"native-<kernel>"``);
    the pure-Python tier, if present, is reported here for diagnostics only.
    """
    if _HAVE_NATIVE_LIB:
        kernel = _native_kernel_name() or "unknown"
        return f"native-{kernel}"
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
    sequences: bytes | None = None,
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

    # Marshal sequences (V5 candidates; None = V4-only behaviour).
    if sequences is not None and len(sequences):
        seq_buf = (ctypes.c_uint8 * len(sequences)).from_buffer_copy(
            bytes(sequences))
    else:
        seq_buf = None

    # Output capacity: V4 outer header overhead (~30 bytes) + RLT (deflated,
    # bounded by 4*n_reads) + cram body (worst case ~ qualities + slack).
    out_cap = 64 + 4 * n_reads + n_qualities * 2 + 1024
    out_buf = (ctypes.c_uint8 * out_cap)()
    out_len = ctypes.c_size_t(out_cap)

    rc = _lib.ttio_m94z_qual_encode(
        qual_buf,
        ctypes.c_size_t(n_qualities),
        rl_buf,
        ctypes.c_size_t(n_reads),
        flags_buf,
        seq_buf,
        ctypes.c_int(strategy_hint),
        ctypes.c_uint8(pad_count & 0x3),
        out_buf,
        ctypes.byref(out_len),
    )
    if rc != 0:
        raise RuntimeError(f"ttio_m94z_qual_encode failed: rc={rc}")
    return bytes(out_buf[:out_len.value])


def _decode_v4_via_native(
    encoded: bytes,
    revcomp_flags: list[int] | None,
    sequences: bytes | None = None,
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
    if encoded[4] not in (VERSION_V4_FQZCOMP, VERSION_V5_SEQCTX):
        raise ValueError(
            f"M94Z: expected version {VERSION_V4_FQZCOMP} or "
            f"{VERSION_V5_SEQCTX}, got {encoded[4]}"
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

    if encoded[4] == VERSION_V5_SEQCTX:
        if sequences is None:
            raise ValueError(
                "M94Z V5 stream requires sequences: pass a "
                "sequences_provider to decode_with_metadata (the "
                "sequence-context model decodes against the run's "
                "decoded sequences channel)"
            )
        if len(sequences) != num_qualities:
            raise ValueError(
                f"M94Z V5: sequences length ({len(sequences)}) != "
                f"num_qualities ({num_qualities})"
            )

    in_buf = (ctypes.c_uint8 * len(encoded)).from_buffer_copy(bytes(encoded))
    out_buf = (ctypes.c_uint8 * num_qualities)()
    if sequences is not None and num_qualities:
        seq_buf = (ctypes.c_uint8 * num_qualities).from_buffer_copy(
            bytes(sequences))
    else:
        seq_buf = None

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

    rc = _lib.ttio_m94z_qual_decode(
        in_buf,
        ctypes.c_size_t(len(encoded)),
        rl_buf,
        ctypes.c_size_t(num_reads),
        flags_buf,
        seq_buf,
        out_buf,
        ctypes.c_size_t(num_qualities),
    )
    if rc != 0:
        raise RuntimeError(f"ttio_m94z_qual_decode failed: rc={rc}")

    read_lengths = list(_rl) if num_reads else []
    return bytes(out_buf), read_lengths, list(revcomp_flags)


def encode(
    qualities: bytes,
    read_lengths: list[int],
    revcomp_flags: list[int],
    *,
    v4_strategy_hint: int = -1,
    sequences: bytes | None = None,
    # Legacy keyword arguments accepted but ignored, for backward
    # compatibility with old call sites (Phase 2c: V1/V2/V3 encoders
    # deleted; only V4 remains, so these no longer affect the output).
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
        v4_strategy_hint: -1 = auto-tune (default), 0..4 = V4 preset,
            5..6 = forced V5 sequence strategy (requires
            ``sequences``).
        sequences: base bytes parallel to ``qualities`` position for
            position. When supplied (and the channel is at least
            ``TTIO_M94Z_V5_MIN_QUALITIES`` bytes, or the hint forces
            it), the encoder also tries the S5/S6 sequence-context
            strategies and keeps the smallest stream; the output is
            then version 5 only when a sequence strategy won. ``None``
            keeps the V4-only behaviour byte for byte.
        context_params, prefer_native, prefer_v3, prefer_v4: accepted
            for backward-compatible call sites only.

    Returns:
        On-wire byte stream tagged with version byte 4
        (``VERSION_V4_FQZCOMP``) or 5 (``VERSION_V5_SEQCTX``).
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
    if sequences is not None:
        sequences = bytes(sequences)
        if len(sequences) != len(qualities):
            raise ValueError(
                f"sequences length ({len(sequences)}) != qualities "
                f"length ({len(qualities)}); the V5 sequence context "
                "needs one base per quality"
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
        sequences=sequences,
    )



def decode_with_metadata(
    encoded: bytes,
    revcomp_flags: list[int] | None = None,
    sequences_provider=None,
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
    if encoded[4] in (VERSION_V4_FQZCOMP, VERSION_V5_SEQCTX):
        if not _HAVE_NATIVE_LIB:
            raise RuntimeError(
                "M94Z V4/V5 decode requires libttio_rans (set "
                "TTIO_RANS_LIB_PATH or install the native library)"
            )
        sequences = None
        if encoded[4] == VERSION_V5_SEQCTX:
            if sequences_provider is None:
                raise ValueError(
                    "M94Z V5 stream requires sequences: pass a "
                    "sequences_provider callable returning the run's "
                    "decoded sequences bytes"
                )
            sequences = bytes(sequences_provider())
        return _decode_v4_via_native(encoded, revcomp_flags,
                                     sequences=sequences)

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
    "VERSION_V5_SEQCTX",
]
