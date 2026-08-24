#!/usr/bin/env python3
"""M97 Phase 0 spec-proof: the REF_DIFF_V2 slice policy is writer-only.

The codec's outer container carries a slice index (per-slice body
offset, body length, read count); the decoder walks that index and
never assumes how the writer chose the boundaries. If that is true at
the byte level, a `slice_bytes` byte-budget writer needs no decoder,
wire-format, or fixture change — the policy is the writer's alone.

Two-part proof, both against the UNMODIFIED native codec:

P1 (reassembler fidelity). Encode a run whole with
    ``reads_per_slice = R``; separately encode each R-read chunk on
    its own and reassemble the container by hand (rebuilt header +
    rebuilt slice index + concatenated slice bodies). The two blobs
    must be byte-identical. This proves slice bodies depend only on
    their own reads and that the reassembler is faithful.

P2 (decoder indifference). Reassemble the same reads under a BYTE
    budget — non-uniform read counts per slice, boundaries the native
    writer cannot currently produce — and decode with the unmodified
    decoder. Sequences and offsets must equal the whole-run baseline
    decode and the original input.

Inputs: a real short-read corpus (chr22 lean mapped BAM via samtools)
and synthetic aligned ultra-long reads against the same reference.

Usage:
    slice_bytes_proof.py <chr22.bam> <chr22.fa> [n_short_reads]
"""
import hashlib
import struct
import subprocess
import sys
import random

import numpy as np

from ttio.codecs import ref_diff_v2 as rdv2

FIXED = 38
IDX_ENTRY = 32


def load_reference(fa_path):
    chrom, seq = None, []
    with open(fa_path) as f:
        for line in f:
            if line.startswith(">"):
                if chrom is not None:
                    break
                chrom = line[1:].split()[0]
            else:
                seq.append(line.strip())
    ref = "".join(seq).upper().encode()
    return chrom, ref


def load_bam_reads(bam, n):
    """(positions 1-based, cigars, sequences concat, offsets) of the
    first n mapped, non-empty-SEQ reads."""
    out = subprocess.run(
        ["samtools", "view", "-F", "0x904", bam],
        capture_output=True, check=True)
    positions, cigars, chunks, offsets = [], [], [], [0]
    for line in out.stdout.splitlines():
        f = line.split(b"\t", 11)
        if f[9] == b"*" or f[5] == b"*":
            continue
        positions.append(int(f[3]))
        cigars.append(f[5].decode())
        chunks.append(f[9])
        offsets.append(offsets[-1] + len(f[9]))
        if len(positions) >= n:
            break
    seqs = np.frombuffer(b"".join(chunks), dtype=np.uint8).copy()
    return (np.asarray(positions, dtype=np.int64), cigars, seqs,
            np.asarray(offsets, dtype=np.uint64))


def synth_ul_reads(ref, n_reads, rng):
    """Aligned synthetic UL reads: reference substrings 30-200 kb with
    ~1% SNPs, occasional insertions and soft clips, honest CIGARs."""
    positions, cigars, chunks, offsets = [], [], [], [0]
    bases = b"ACGT"
    for _ in range(n_reads):
        rlen = rng.randint(30_000, 200_000)
        pos = rng.randint(1, len(ref) - rlen - 1000)
        body = bytearray(ref[pos - 1:pos - 1 + rlen])
        for _ in range(rlen // 100):                     # ~1% SNPs
            i = rng.randrange(rlen)
            body[i] = rng.choice([b for b in bases if b != body[i]])
        cig = []
        read = bytearray()
        sc = rng.choice([0, 0, 0, 500])                  # occasional clip
        if sc:
            read += bytes(rng.choice(bases) for _ in range(sc))
            cig.append(f"{sc}S")
        half = rlen // 2
        read += body[:half]
        cig.append(f"{half}M")
        ins = rng.choice([0, 0, 40])                     # occasional insert
        if ins:
            read += bytes(rng.choice(bases) for _ in range(ins))
            cig.append(f"{ins}I")
        read += body[half:]
        cig.append(f"{rlen - half}M")
        positions.append(pos)
        cigars.append("".join(cig))
        chunks.append(bytes(read))
        offsets.append(offsets[-1] + len(read))
    seqs = np.frombuffer(b"".join(chunks), dtype=np.uint8).copy()
    return (np.asarray(positions, dtype=np.int64), cigars, seqs,
            np.asarray(offsets, dtype=np.uint64))


def split_container(blob):
    """(header_bytes, [(body_offset, body_len, first, last, n), ...],
    bodies_region_start)."""
    n_slices = int.from_bytes(blob[8:12], "little")
    uri_len = int.from_bytes(blob[36:38], "little")
    hdr_len = FIXED + uri_len
    entries = []
    for i in range(n_slices):
        e = blob[hdr_len + i * IDX_ENTRY: hdr_len + (i + 1) * IDX_ENTRY]
        entries.append(struct.unpack("<QIQQI", e))
    return blob[:hdr_len], entries, hdr_len + n_slices * IDX_ENTRY


def reassemble(chunks_encoded, header_template, total_reads):
    """Rebuild one multi-slice container from single-run encodes."""
    bodies, index = [], []
    running = 0
    for blob in chunks_encoded:
        hdr, entries, bodies_at = split_container(blob)
        for (b_off, b_len, first, last, n) in entries:
            body = blob[bodies_at + b_off: bodies_at + b_off + b_len]
            index.append(struct.pack("<QIQQI", running, b_len, first, last, n))
            bodies.append(body)
            running += b_len
    hdr = bytearray(header_template)
    hdr[8:12] = struct.pack("<I", len(index))
    hdr[12:20] = struct.pack("<Q", total_reads)
    return bytes(hdr) + b"".join(index) + b"".join(bodies)


def budget_boundaries(offsets, slice_bytes):
    """Greedy byte-budget slicing: cut when the pending slice would
    exceed slice_bytes (every slice keeps >= 1 read)."""
    cuts, start = [], 0
    n = len(offsets) - 1
    for i in range(1, n + 1):
        if int(offsets[i] - offsets[start]) > slice_bytes and i - 1 > start:
            cuts.append((start, i - 1))
            start = i - 1
    cuts.append((start, n))
    return cuts


def encode_chunks(boundaries, positions, cigars, seqs, offsets,
                  ref, md5, uri, per_slice=None):
    out = []
    for (i0, i1) in boundaries:
        sub_off = (offsets[i0:i1 + 1] - offsets[i0]).astype(np.uint64)
        sub_seq = seqs[int(offsets[i0]):int(offsets[i1])]
        rps = per_slice if per_slice is not None else (i1 - i0)
        out.append(rdv2.encode(sub_seq, sub_off, positions[i0:i1],
                               cigars[i0:i1], ref, md5, uri,
                               reads_per_slice=rps))
    return out


def prove(tag, positions, cigars, seqs, offsets, ref, uniform_r,
          slice_bytes):
    md5 = hashlib.md5(ref).digest()
    uri = "phase0://chr22"
    n = len(positions)
    total = int(offsets[-1])

    whole = rdv2.encode(seqs, offsets, positions, cigars, ref, md5, uri,
                        reads_per_slice=uniform_r)
    base_seq, base_off = rdv2.decode(whole, positions, cigars, ref, n, total)
    assert bytes(base_seq) == bytes(seqs), f"{tag}: baseline decode mismatch"

    # P1 — uniform chunks, reassembled, must equal the native blob.
    uni = [(i, min(i + uniform_r, n)) for i in range(0, n, uniform_r)]
    reasm = reassemble(
        encode_chunks(uni, positions, cigars, seqs, offsets, ref, md5, uri,
                      per_slice=uniform_r),
        split_container(whole)[0], n)
    p1 = reasm == whole
    print(f"[{tag}] P1 reassembler fidelity: "
          f"{'byte-identical' if p1 else 'MISMATCH'} "
          f"({len(whole):,} B, {len(uni)} slices)")

    # P2 — byte-budget boundaries, unmodified decoder.
    cuts = budget_boundaries(offsets, slice_bytes)
    sizes = [int(offsets[b] - offsets[a]) for a, b in cuts]
    frank = reassemble(
        encode_chunks(cuts, positions, cigars, seqs, offsets, ref, md5, uri),
        split_container(whole)[0], n)
    got_seq, got_off = rdv2.decode(frank, positions, cigars, ref, n, total)
    p2 = bytes(got_seq) == bytes(seqs) and np.array_equal(got_off, base_off)
    print(f"[{tag}] P2 decoder indifference at slice_bytes="
          f"{slice_bytes:,}: {'byte-exact' if p2 else 'MISMATCH'} "
          f"({len(cuts)} slices, bases/slice min={min(sizes):,} "
          f"max={max(sizes):,}; default-policy unit would be "
          f"{total if n <= 10_000 else 'n/a'} bases in "
          f"{max(1, (n + 9_999) // 10_000)} slice(s))")
    return p1 and p2


def main():
    bam, fa = sys.argv[1], sys.argv[2]
    n_short = int(sys.argv[3]) if len(sys.argv) > 3 else 20_000
    _, ref = load_reference(fa)

    ok = True
    positions, cigars, seqs, offsets = load_bam_reads(bam, n_short)
    print(f"short-read corpus: {len(positions):,} reads, "
          f"{int(offsets[-1]):,} bases")
    ok &= prove("short", positions, cigars, seqs, offsets, ref,
                uniform_r=3_000, slice_bytes=1 << 20)

    rng = random.Random(20260824)
    positions, cigars, seqs, offsets = synth_ul_reads(ref, 2_000, rng)
    print(f"synthetic UL corpus: {len(positions):,} reads, "
          f"{int(offsets[-1]):,} bases")
    ok &= prove("ul", positions, cigars, seqs, offsets, ref,
                uniform_r=500, slice_bytes=8 << 20)

    print("PHASE0:", "WRITER-ONLY CONFIRMED" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
