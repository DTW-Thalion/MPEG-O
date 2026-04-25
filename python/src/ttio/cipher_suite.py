"""Cipher-suite catalog and algorithm-dispatched parameter helpers (v0.7 M48).

Pre-v0.7, encryption / signing / key-wrap APIs accepted an implicit
fixed algorithm (AES-256-GCM for bulk, HMAC-SHA256 for signatures,
AES-KW-style wrap for KEK). Key sizes and nonce lengths were
hardcoded module-level constants.

v0.7 M48 generalises the public API with an ``algorithm=`` keyword
parameter backed by this catalog. The intent was to shape the
parameter hole so M49's post-quantum binding is a pure plug-in — no
API change — once ML-KEM-1024 / ML-DSA-87 are ready.

v0.8 M49 activates the post-quantum entries. ``"ml-kem-1024"`` (FIPS
203) and ``"ml-dsa-87"`` (FIPS 204) transition from
``status="reserved"`` to ``status="active"``. Activation requires
the optional ``[pqc]`` extra (``pip install 'ttio[pqc]'`` pulls in
``liboqs-python``, which in turn needs a system liboqs 0.14+). Without
that extra, :mod:`ttio.pqc` import raises
:class:`~ttio.pqc.PQCUnavailableError` and all PQC entry points fail
cleanly — the catalog still lists the entries but the sign/wrap code
paths refuse to run.

``"shake256"`` remains reserved (no consumer yet in the protection
APIs; a v0.9 domain-separator primitive may activate it).

Design notes (binding decision 39):
* ``CipherSuite`` is a **static allow-list**, not a plugin registry.
  Adding a new algorithm is a source-code change. Runtime
  registration would let callers push FIPS-unapproved algorithms
  through production code; that complexity is deferred to v0.8+.

Cross-language equivalents:
* ObjC: ``TTIOCipherSuite`` (:file:`objc/Source/Protection/TTIOCipherSuite.h`)
* Java: ``com.dtwthalion.ttio.protection.CipherSuite``
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Literal


class UnsupportedAlgorithmError(ValueError):
    """Raised when a caller specifies an algorithm not in the static
    catalog — either misspelled, or reserved for a later milestone
    (e.g., ML-KEM-1024 prior to M49)."""


class InvalidKeyError(ValueError):
    """Raised when a key length does not match the selected algorithm."""


Category = Literal["AEAD", "KEM", "MAC", "Signature", "Hash", "XOF"]
Status = Literal["active", "reserved"]


@dataclass(frozen=True, slots=True)
class _Entry:
    algorithm: str
    category: Category
    key_size: int | None  # symmetric key or (for KEM/Signature) PUBLIC key length
    nonce_size: int
    tag_size: int  # for AEAD; signature size for signatures
    status: Status
    notes: str = ""
    private_key_size: int | None = None  # KEM / Signature only


# ── The catalog ─────────────────────────────────────────────────────

_CATALOG: dict[str, _Entry] = {
    # Bulk / AEAD
    "aes-256-gcm": _Entry(
        algorithm="aes-256-gcm",
        category="AEAD",
        key_size=32,
        nonce_size=12,
        tag_size=16,
        status="active",
        notes="Default for bulk encryption and envelope wrapping.",
    ),
    # KEM
    "ml-kem-1024": _Entry(
        algorithm="ml-kem-1024",
        category="KEM",
        key_size=1568,            # public-key size
        private_key_size=3168,    # ML-KEM-1024 decapsulation key
        nonce_size=0,
        tag_size=0,               # ciphertext length is 1568, handled at the blob layer
        status="active",
        notes="NIST FIPS 203 ML-KEM-1024. v0.8 M49; requires [pqc] extra "
              "(liboqs-python + liboqs ≥ 0.14). Java path is Bouncy Castle "
              "(org.bouncycastle:bcprov-jdk18on ≥ 1.79).",
    ),
    # MAC / Signature
    "hmac-sha256": _Entry(
        algorithm="hmac-sha256",
        category="MAC",
        key_size=None,    # up to 64 bytes; HMAC tolerates variable
        nonce_size=0,
        tag_size=32,
        status="active",
        notes="Default for v2 canonical signatures.",
    ),
    "ml-dsa-87": _Entry(
        algorithm="ml-dsa-87",
        category="Signature",
        key_size=2592,            # FIPS 204 ML-DSA-87 public key
        private_key_size=4896,    # FIPS 204 ML-DSA-87 signing key
        nonce_size=0,
        tag_size=4627,            # ML-DSA-87 signature size
        status="active",
        notes="NIST FIPS 204 ML-DSA-87. v0.8 M49; requires [pqc] extra on "
              "Python / ObjC (liboqs), Bouncy Castle on Java. Emits v3: "
              "signature-attribute prefix.",
    ),
    # Hash
    "sha-256": _Entry(
        algorithm="sha-256",
        category="Hash",
        key_size=0,
        nonce_size=0,
        tag_size=32,
        status="active",
        notes="Default hash primitive for canonical transcripts.",
    ),
    "shake256": _Entry(
        algorithm="shake256",
        category="XOF",
        key_size=0,
        nonce_size=0,
        tag_size=0,      # variable-length output
        status="reserved",
        notes="SHA-3 family extendable-output function; reserved for M49.",
    ),
}


# ── Public catalog API ──────────────────────────────────────────────


def is_supported(algorithm: str) -> bool:
    """Return True iff ``algorithm`` is a known catalog entry with
    ``status="active"``. Reserved entries return False."""
    entry = _CATALOG.get(algorithm)
    return entry is not None and entry.status == "active"


def is_registered(algorithm: str) -> bool:
    """Return True iff ``algorithm`` is listed in the catalog,
    including reserved entries. Useful for error messages that want
    to distinguish 'unknown' from 'not yet implemented'."""
    return algorithm in _CATALOG


def category(algorithm: str) -> Category:
    """Return the algorithm's category identifier."""
    _require(algorithm)
    return _CATALOG[algorithm].category


def key_length(algorithm: str) -> int | None:
    """Return the fixed key length for this algorithm, or ``None`` if
    the algorithm tolerates variable-length keys (HMAC)."""
    _require(algorithm)
    return _CATALOG[algorithm].key_size


def nonce_length(algorithm: str) -> int:
    """Return the nonce / IV length in bytes. Zero for non-AEAD
    primitives. Replaces the module-level ``AES_IV_LEN = 12``
    constant scattered through pre-v0.7 code."""
    _require(algorithm)
    return _CATALOG[algorithm].nonce_size


def tag_length(algorithm: str) -> int:
    """Return the authentication-tag or signature length in bytes.
    Zero for hashes and XOFs whose output size is variable."""
    _require(algorithm)
    return _CATALOG[algorithm].tag_size


def validate_key(algorithm: str, key: bytes) -> None:
    """Raise :class:`InvalidKeyError` if ``key`` does not match the
    algorithm's required length. Replaces inline ``len(key) == 32``
    checks.

    For algorithms with variable-length keys (HMAC), imposes a sanity
    minimum of 1 byte and logs when the key is unusually short (< 16
    bytes). For reserved-status algorithms, raises
    :class:`UnsupportedAlgorithmError` so callers don't silently run
    against stub code paths.

    Asymmetric algorithms (category KEM / Signature) have two key
    shapes — public and private. ``validate_key`` on a KEM / Signature
    algorithm raises :class:`InvalidKeyError` directing the caller to
    :func:`validate_public_key` or :func:`validate_private_key`; this
    keeps role confusion out of the symmetric-focused call sites.
    """
    entry = _require_active(algorithm)
    if entry.category in ("KEM", "Signature"):
        raise InvalidKeyError(
            f"{algorithm!r} is asymmetric — use validate_public_key "
            f"or validate_private_key instead of validate_key"
        )
    if entry.key_size is None:
        if len(key) == 0:
            raise InvalidKeyError(
                f"{algorithm}: key must be non-empty (got 0 bytes)"
            )
        return
    if len(key) != entry.key_size:
        raise InvalidKeyError(
            f"{algorithm}: key must be {entry.key_size} bytes "
            f"(got {len(key)})"
        )


def validate_public_key(algorithm: str, key: bytes) -> None:
    """Raise :class:`InvalidKeyError` if ``key`` is not the right length
    for ``algorithm``'s public key (KEM encapsulation / signature
    verification). Symmetric algorithms raise immediately — use
    :func:`validate_key`."""
    entry = _require_active(algorithm)
    if entry.category not in ("KEM", "Signature"):
        raise InvalidKeyError(
            f"{algorithm!r} is symmetric; use validate_key instead"
        )
    if len(key) != entry.key_size:
        raise InvalidKeyError(
            f"{algorithm}: public key must be {entry.key_size} bytes "
            f"(got {len(key)})"
        )


def validate_private_key(algorithm: str, key: bytes) -> None:
    """Raise :class:`InvalidKeyError` if ``key`` is not the right length
    for ``algorithm``'s private key (KEM decapsulation / signing).
    Symmetric algorithms raise immediately — use :func:`validate_key`."""
    entry = _require_active(algorithm)
    if entry.category not in ("KEM", "Signature"):
        raise InvalidKeyError(
            f"{algorithm!r} is symmetric; use validate_key instead"
        )
    if entry.private_key_size is None:
        raise InvalidKeyError(
            f"{algorithm}: private_key_size is not declared in the catalog"
        )
    if len(key) != entry.private_key_size:
        raise InvalidKeyError(
            f"{algorithm}: private key must be {entry.private_key_size} bytes "
            f"(got {len(key)})"
        )


def public_key_size(algorithm: str) -> int:
    """Return the asymmetric public-key length in bytes. Raises for
    symmetric algorithms."""
    entry = _require(algorithm)
    if entry.category not in ("KEM", "Signature"):
        raise UnsupportedAlgorithmError(
            f"{algorithm!r} is symmetric — no public key"
        )
    assert entry.key_size is not None
    return entry.key_size


def private_key_size(algorithm: str) -> int:
    """Return the asymmetric private-key length in bytes. Raises for
    symmetric algorithms."""
    entry = _require(algorithm)
    if entry.category not in ("KEM", "Signature"):
        raise UnsupportedAlgorithmError(
            f"{algorithm!r} is symmetric — no private key"
        )
    if entry.private_key_size is None:
        raise UnsupportedAlgorithmError(
            f"{algorithm!r} catalog entry is missing private_key_size"
        )
    return entry.private_key_size


def algorithms(*, status: Status | None = None) -> list[str]:
    """Return catalog entries, optionally filtered by status."""
    if status is None:
        return list(_CATALOG.keys())
    return [name for name, entry in _CATALOG.items()
            if entry.status == status]


# ── Internal ────────────────────────────────────────────────────────


def _require(algorithm: str) -> _Entry:
    entry = _CATALOG.get(algorithm)
    if entry is None:
        raise UnsupportedAlgorithmError(
            f"unknown algorithm: {algorithm!r} "
            f"(catalog: {sorted(_CATALOG.keys())})"
        )
    return entry


def _require_active(algorithm: str) -> _Entry:
    entry = _require(algorithm)
    if entry.status != "active":
        raise UnsupportedAlgorithmError(
            f"{algorithm!r} is in the catalog but has status "
            f"'{entry.status}' — this build does not ship the primitive. "
            f"(reserved algorithms activate in later milestones, "
            f"e.g. M49 for ml-kem-1024 / ml-dsa-87)"
        )
    return entry
