"""Packed reference storage — codec round-trip, writer dispatch, and
reader fallback to the legacy raw layout."""
from __future__ import annotations

from pathlib import Path

import pytest

from ttio.genomic import packed_reference as pr
from ttio.genomic.reference_import import ReferenceImport, compute_reference_md5


CASES = {
    "empty": b"",
    "pure_acgt": b"ACGTACGTACGT",
    "all_n": b"N" * 1000,
    "n_runs_both_ends": b"N" * 507 + b"ACGT" * 250 + b"N" * 33,
    "iupac_mixed": b"ACGTRYSWKMBDHVNacgt" * 97,
    "single_base": b"G",
    "single_exception": b"n",
    "trailing_partial_byte": b"ACGTA",
    "alternating_exceptions": b"ANANANANAN" * 55,
}


class TestCodecRoundTrip:
    @pytest.mark.parametrize("name", sorted(CASES))
    def test_round_trip(self, name: str) -> None:
        data = CASES[name]
        assert pr.decode(pr.encode(data)) == data

    def test_n_runs_cost_run_entries_not_bytes(self) -> None:
        # A megabase N run costs one 8-byte run entry + its bytes in
        # the run body — the reason this layout exists instead of
        # BASE_PACK's 5-bytes-per-exception mask.
        data = b"N" * 1_000_000 + b"ACGT" * 1000
        enc = pr.encode(data)
        assert len(enc) < len(data) + 100

    def test_version_gate(self) -> None:
        bad = bytes([0x7F]) + pr.encode(b"ACGT")[1:]
        with pytest.raises(ValueError, match="version"):
            pr.decode(bad)

    def test_truncated_stream_raises(self) -> None:
        enc = pr.encode(b"ACGT" * 100)
        with pytest.raises(ValueError):
            pr.decode(enc[: len(enc) - 3])

    def test_golden_stream_bytes(self) -> None:
        # Byte-exact pin shared with Java's PackedReferenceTest — both
        # languages must produce this exact stream for this input.
        data = b"N" * 7 + b"ACGTACGTGG" + b"n" + b"TTT"
        golden = bytes.fromhex(
            "010000001500000002000000000000000700000011000000"
            "014e4e4e4e4e4e4e6e1b1bafc0"
        )
        assert pr.encode(data) == golden
        assert pr.decode(golden) == data

    def test_packable_fraction(self) -> None:
        assert pr.packable_fraction(b"") == 1.0
        assert pr.packable_fraction(b"ACGT") == 1.0
        assert pr.packable_fraction(b"acgt") == 0.0
        assert pr.packable_fraction(b"AANN") == 0.5


def _write_and_reopen(tmp_path: Path, ref: ReferenceImport):
    from ttio.spectral_dataset import SpectralDataset

    p = tmp_path / "ref.tio"
    SpectralDataset.write_minimal(p, title="", isa_investigation_id="", runs={})
    with SpectralDataset.open(p, writable=True) as ds:
        ref.write_to_dataset(ds)
    return SpectralDataset.open(p)


class TestWriterDispatch:
    def test_acgt_reference_round_trips_packed(self, tmp_path: Path) -> None:
        seqs = [b"N" * 64 + b"ACGT" * 4096 + b"N" * 32, b"GATTACA" * 1024]
        names = ["chr1", "chr2"]
        ref = ReferenceImport(
            uri="packed-v1", chromosomes=names, sequences=seqs,
            md5=compute_reference_md5(names, seqs),
        )
        ds = _write_and_reopen(tmp_path, ref)
        try:
            back = ds.references["packed-v1"]
            assert back.chromosome("chr1") == seqs[0]
            assert back.chromosome("chr2") == seqs[1]
            # The on-disk layout is the packed one.
            grp = ds.provider.root_group() \
                .open_group("study").open_group("references") \
                .open_group("packed-v1").open_group("chromosomes") \
                .open_group("chr1")
            assert grp.has_child("data_packed")
            assert not grp.has_child("data")
        finally:
            ds.close()

    def test_softmasked_reference_falls_back_to_raw(self, tmp_path: Path) -> None:
        seqs = [b"acgt" * 4096]     # fully soft-masked: packing loses
        names = ["chrS"]
        ref = ReferenceImport(
            uri="soft-v1", chromosomes=names, sequences=seqs,
            md5=compute_reference_md5(names, seqs),
        )
        ds = _write_and_reopen(tmp_path, ref)
        try:
            back = ds.references["soft-v1"]
            assert back.chromosome("chrS") == seqs[0]
            grp = ds.provider.root_group() \
                .open_group("study").open_group("references") \
                .open_group("soft-v1").open_group("chromosomes") \
                .open_group("chrS")
            assert grp.has_child("data")
            assert not grp.has_child("data_packed")
        finally:
            ds.close()
