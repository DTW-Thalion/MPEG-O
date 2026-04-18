"""``FeatureFlags`` — the registry of format feature strings used by a file.

The actual on-disk read/write lives in :mod:`mpeg_o._hdf5_io`; this module
provides a thin value object and the canonical list of reserved feature
names documented in ``docs/feature-flags.md``.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable

# v0.2 features (required unless prefixed with ``opt_``)
BASE_V1 = "base_v1"
COMPOUND_IDENTIFICATIONS = "compound_identifications"
COMPOUND_QUANTIFICATIONS = "compound_quantifications"
COMPOUND_PROVENANCE = "compound_provenance"
OPT_COMPOUND_HEADERS = "opt_compound_headers"
OPT_NATIVE_2D_NMR = "opt_native_2d_nmr"
OPT_NATIVE_MSIMAGE_CUBE = "opt_native_msimage_cube"
OPT_DATASET_ENCRYPTION = "opt_dataset_encryption"
OPT_DIGITAL_SIGNATURES = "opt_digital_signatures"

# Reserved for v0.3
OPT_CANONICAL_SIGNATURES = "opt_canonical_signatures"
COMPOUND_PER_RUN_PROVENANCE = "compound_per_run_provenance"

# v0.4 (M25): envelope encryption + rotatable KEK wrapping the DEK.
OPT_KEY_ROTATION = "opt_key_rotation"

# v0.4 (M28): file has been through the anonymization pipeline.
OPT_ANONYMIZED = "opt_anonymized"

# v0.8 (M49): file uses post-quantum crypto — ML-KEM-1024 key wrapping
# and/or ML-DSA-87 (v3:) signatures. Set whenever either primitive is
# used. Opt-flag (reader without PQC can still open the file and read
# unencrypted datasets; it just cannot verify v3: signatures or unwrap
# ML-KEM-wrapped DEKs).
OPT_PQC_PREVIEW = "opt_pqc_preview"


@dataclass(frozen=True, slots=True)
class FeatureFlags:
    """Immutable set of format feature strings with a version label."""

    version: str = "1.1"
    features: tuple[str, ...] = field(default_factory=tuple)

    @classmethod
    def from_iterable(cls, version: str, features: Iterable[str]) -> "FeatureFlags":
        return cls(version=version, features=tuple(features))

    def has(self, name: str) -> bool:
        return name in self.features

    def required(self) -> tuple[str, ...]:
        """Features whose absence should cause a reader to refuse the file."""
        return tuple(f for f in self.features if not f.startswith("opt_"))
