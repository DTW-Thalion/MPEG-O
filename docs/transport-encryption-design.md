# MPEG-O Transport Encryption — Design Proposal

**Status:** Draft for review (v0.10 blocker).

This document proposes how the streaming transport format
(`docs/transport-spec.md`) should carry encrypted data. It is not
yet normative — v0.10 ships without the encrypted round-trip while
this design is reviewed and implemented.

## 1. Problem

The existing encryption subsystem (see `docs/format-spec.md` §10
and `mpeg_o/encryption.py`, `MPGOEncryptionManager`,
`com.dtwthalion.mpgo.protection.EncryptionManager`) encrypts at
**channel granularity**:

- A single AES-256-GCM operation covers the entire
  `intensity_values` channel of a run (hundreds of MB for a
  60-minute LC-MS acquisition).
- The ciphertext is stored in `<channel>_values_encrypted`, with
  a single 12-byte IV and a single 16-byte GCM tag.
- The tag authenticates the whole ciphertext; a receiver cannot
  decrypt or validate any subset without holding the entire
  channel.

The transport format is **per-Access-Unit**. Each AU carries one
spectrum's channel data. This is the "Access Unit = one spectrum"
binding decision (HANDOFF binding decision 55) and is load-bearing
for:

- **Selective access.** Server-side filtering evaluates per-AU
  headers; filtered streams deliver only matching AUs.
- **Real-time acquisition** (M69). The simulator emits one AU per
  scan at wall-clock rate; a server-driven live acquisition has
  no notion of a "complete channel" until the run ends.
- **Multiplexing.** AUs from different runs may be interleaved on
  the wire.

These two models are not compatible. A single AES-GCM block
covering a whole channel cannot be partially delivered, and a
filtered stream that omits spectra produces ciphertext the
receiver cannot validate — the tag covers the bytes that weren't
sent.

## 2. Options

### 2.1 Per-AU encryption (recommended)

Each AU's channel data is independently encrypted with its own IV
and tag. One wrapped DEK is shared across the whole run (the key
doesn't need rotation per spectrum), but each encryption operation
produces a fresh IV.

**Wire:**

- `ProtectionMetadata` packet emitted once per stream, carrying
  `cipher_suite`, `kek_algorithm`, `wrapped_dek`,
  `signature_algorithm`, `public_key`.
- Each encrypted AU sets `PacketFlag.ENCRYPTED` on its packet
  header.
- Each encrypted `ChannelData` prefixes its bytes with `[IV (12)]
  [TAG (16)]` followed by ciphertext. Wire layout:

  ```
  channel_name_len: uint16
  channel_name:     bytes[channel_name_len]
  precision:        uint8   # same enum as plaintext
  compression:      uint8   # matches pre-encryption codec; decryption produces compressed bytes
  n_elements:       uint32  # plaintext element count
  data_length:      uint32  # 28 + ciphertext_bytes
  data:             bytes[12 IV || 16 TAG || ciphertext]
  ```

- AU header's filter-key fields (RT, MS level, polarity,
  precursor m/z, ion mobility, base peak intensity) remain **plaintext**
  so server-side filtering works without keys. The design
  assumes these scalar fields are not considered PHI; if they
  are, a future revision can introduce an encrypted-headers mode.

**File format change:** introduce `opt_per_au_encryption` feature
flag. New files use the per-AU layout:

- `signal_channels/<channel>_values_encrypted` is replaced by
  `<channel>_encrypted_segments` — a compound dataset with
  columns `offset: u64`, `length: u32`, `iv: [u8; 12]`,
  `tag: [u8; 16]`, `ciphertext: VL[u8]`.
- One row per spectrum (or per chunk for large spectra if
  needed later).
- `@<channel>_algorithm`, `@<channel>_wrapped_dek` attributes
  remain at the channel group.

Existing files (channel-granularity encryption) remain readable;
the transport layer refuses to stream them without transcoding
authorization (see §3 for the boundary).

**Pros:**
- Wire format stays simple; no new packet types.
- Selective access preserved (filter evaluates plaintext AU
  header; filtered stream still produces a valid encrypted
  output file).
- Real-time streaming viable.
- MPEG-G style (per-Access-Unit crypto) — matches the spec's
  conceptual model.
- ~28 bytes overhead per spectrum per channel (negligible — a
  10k-spectrum run gains ~560KB of IV+tag data).

**Cons:**
- Requires a new encryption mode in Python/Java/ObjC encryption
  managers.
- New file format flag — back-compat for existing encrypted
  files (channel-granularity) is read-only at the transport
  boundary; writers writing new encrypted files opt into per-AU.

### 2.2 Transport-level run-blob packet

Add `EncryptedChannelBlob` as a new packet type (0x09). Carries
`dataset_id`, `channel_name`, `iv`, `tag`, `ciphertext` for an
entire run's channel. Emit once per encrypted channel, before
AUs. AUs remain plaintext in structure but signal channel data
is empty / a reference to the blob.

**Pros:**
- No change to encryption subsystem.
- File format unchanged.

**Cons:**
- Selective access becomes all-or-nothing: if any spectrum is
  filtered out, the blob's ciphertext is useless (the tag covers
  the whole channel, including the filtered scans).
- Real-time streaming impossible — must know the whole channel
  before emitting.
- Breaks HANDOFF binding decision 55 ("AU = one spectrum").
- Receiver must buffer the entire blob before any spectrum is
  accessible.

### 2.3 Transcode (decrypt → re-encrypt)

Server holds the key, decrypts on the way out, re-encrypts per-AU
on the way in.

**Pros:**
- Works with existing file format.

**Cons:**
- **Violates the spec's non-negotiable rule** (`docs/transport-spec.md`
  §6.2: "receiver MUST NOT decode channel payloads unless the
  target container demands a different encoding").
- Server needs the key — eliminates the encrypted-at-rest threat
  model where the server is untrusted.
- Key management becomes a deployment nightmare (who provisions
  the server's key? rotates it?).
- Rejected.

## 3. Recommended Approach

**Option 2.1 — per-AU encryption.** It's the only design that
satisfies all three of: streaming contract, selective access, and
the untrusted-server threat model.

Introduced as a new file-format feature flag
`opt_per_au_encryption` (v1.1 of the on-disk format). Transport
refuses to stream channel-granularity-encrypted files without an
explicit `--transcode` flag (which requires the server to hold
the key and logs the transcode in `ProvenanceRecord`). Default
behavior: error out with "source uses channel-granularity
encryption; re-encrypt with `--per-au` mode or enable
`--transcode`".

## 4. Wire format details

### 4.1 ProtectionMetadata packet — no change from M71

Already defined in `docs/transport-spec.md` §4.4 and implemented
in M71 across all three languages. No schema change.

### 4.2 AU header — no change

`PacketFlag.ENCRYPTED` (bit 0) already reserved and round-trips
through the codec in all three languages (covered by M71 tests).

### 4.3 ChannelData — encrypted variant

When `PacketFlag.ENCRYPTED` is set on the enclosing AU, every
`ChannelData` payload is laid out as:

```
[IV: 12 bytes] [TAG: 16 bytes] [CIPHERTEXT: data_length - 28 bytes]
```

`n_elements` and `precision` describe the plaintext array. After
decryption, the plaintext is the same bytes that a plaintext AU
would carry (same `compression` applied post-decrypt). `compression`
field describes the codec applied to the **plaintext**; the
ciphertext itself is never recompressed.

Rationale: putting IV + tag inline keeps the codec simple (no new
packet type, no sidechannel). 28 bytes per channel per spectrum
is acceptable overhead.

### 4.4 Ordering

- `ProtectionMetadata` MUST precede any encrypted AU of the same
  `dataset_id`.
- One `ProtectionMetadata` per dataset_id is allowed if different
  runs in one stream use different keys.

## 5. API surface (per-language)

Each language adds:

- `encrypt_per_au(key)` — new method on `SpectralDataset` /
  `MPGOSpectralDataset` / `SpectralDataset` (Java) that encrypts
  channels in the new per-AU layout, setting
  `opt_per_au_encryption`.
- Writer detection: `TransportWriter` checks if the source
  dataset has `opt_per_au_encryption`; if so, reads encrypted
  segments directly from the compound dataset and packages them
  into encrypted `ChannelData`.
- Reader materialization: `TransportReader` detects
  `ProtectionMetadata` + encrypted AUs, writes the per-AU
  layout into the target file with the same wrapped DEK.
- Transcode path: `TransportWriter(transcode_key=key)` decrypts
  a channel-granularity-encrypted source, re-encrypts per-AU on
  the way out. Logs to `ProvenanceRecord`. Explicit, guarded.

## 6. Migration & back-compat

- **Existing encrypted files** (`opt_dataset_encryption` without
  `opt_per_au_encryption`): readable by the existing subsystem,
  not streamable through transport except via `--transcode`.
- **New encrypted files** (opt-in via `encrypt_per_au`): streamable
  directly, selective access works, real-time compatible.
- **Readers** ignore unknown opt features; a reader without
  per-AU support reading a per-AU-encrypted file falls back to
  whole-channel decryption if a legacy compatibility path is
  provided, or errors out.
- **Signature subsystem** needs review: v0.2's `v2:` signature
  covers canonical plaintext bytes. Per-AU encryption doesn't
  change signature semantics (the plaintext is still canonical).

## 7. Open questions

1. **Does `opt_per_au_encryption` also change the file format
   layout** (new `<channel>_encrypted_segments` compound), or
   can we keep the existing `<channel>_values_encrypted` layout
   and concatenate per-spectrum ciphertext+IV+tag rows?
   *Preference:* new compound layout for clarity; old layout
   becomes "legacy channel-grained" encryption.
2. **Granularity below per-spectrum?** For 100K-point spectra
   (e.g. ion-mobility), per-spectrum crypto is still one AES-GCM
   op over ~800KB. That's fine for current workloads; if future
   cases need finer chunks, we can extend to per-chunk with an
   extra `chunk_offset` column.
3. **Header encryption.** The AU header fields (RT, MS level,
   precursor m/z) are plaintext in this design so filtering works
   keyless. If those fields are considered sensitive, a future
   `opt_encrypted_au_headers` can introduce a keyed header
   envelope. Out of scope for v1.0.
4. **Key rotation** during a run? Current encryption has a
   run-level wrapped DEK. Per-AU doesn't change this; the DEK is
   still one per run.
5. **Cipher suite migration.** ML-KEM-1024 + ML-DSA-87 (PQC,
   M49) works unchanged — the KEM wraps the DEK, the DEK drives
   per-AU AES-GCM.

## 8. Implementation sizing

Per language, rough LOC estimate (non-test):

- Encryption module extension (new per-AU mode): ~200–300 LOC
  (compound read/write, IV generation, per-AU encrypt/decrypt
  primitives).
- `encrypt_per_au` entry point on SpectralDataset + HDF5 schema
  plumbing: ~150 LOC.
- TransportWriter encrypted path (detect + package): ~100 LOC.
- TransportReader encrypted path (unpack + materialize): ~150
  LOC.
- Tests: ~200 LOC each (per-AU encrypt → transport → decrypt
  round-trip; cross-provider matrix; PQC variant).

Total per language: ~800–900 LOC. Three languages plus
cross-language conformance tests (Python drives): ~3000 LOC of
implementation work, ~600 LOC of tests. Roughly two
concentrated sessions if done per language sequentially.

## 9. Proposed plan

1. Review + sign off on this document (current step).
2. Update `docs/format-spec.md` with the
   `<channel>_encrypted_segments` layout and the
   `opt_per_au_encryption` flag.
3. Update `docs/transport-spec.md` §4.3 with the encrypted
   ChannelData variant (`[IV][TAG][ciphertext]`), §5 with the
   ProtectionMetadata-precedes-encrypted-AUs ordering rule
   (already implicit, make it explicit), and add a §6.4
   "encrypted round-trip contract".
4. Python reference implementation (encrypt_per_au +
   transport read/write paths + tests).
5. ObjC port.
6. Java port.
7. Cross-language conformance tests (Python drives JVM + ObjC
   subprocesses).
8. Tag v0.10.0.

## 10. Not in scope for this design

- LZ4 / Numpress-delta on the wire (separate v1.0 item, same
  pattern as ZLIB which landed in M71.5).
- Ion-mobility importer-specific transport integration.
- Chromatogram packet round-trip (stub exists; integration
  test deferred).
- Encryption of the AU header fields (deferred to v1.x
  `opt_encrypted_au_headers`).
