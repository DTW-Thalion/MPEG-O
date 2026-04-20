# MPEG-O Transport Encryption — Design Proposal

**Status:** APPROVED 2026-04-19. Ready for implementation (v1.0
design freeze on this area).

**Signed off (user feedback 2026-04-19):**
1. New compound layout; backward compatibility with v0.x
   channel-grained encryption is **not** required.
2. `opt_encrypted_au_headers` is in-scope for v1.0.
3. `--transcode` opt-in is acceptable for migration scenarios.

This document is the normative reference for how the streaming
transport format (`docs/transport-spec.md`) carries encrypted
data. Implementation follows in §9.

## 1. Problem

The v0.x encryption subsystem encrypts at **channel granularity**:
one AES-256-GCM operation covers the entire `intensity_values`
channel of a run; storage is `<channel>_values_encrypted` with a
single shared IV + tag.

This is incompatible with the v0.10 transport format, which is
per-Access-Unit:

- **Selective access** evaluates per-AU headers; filtering out
  scans would break a whole-channel MAC.
- **Real-time streaming** (M69 simulator, live acquisition) has
  no notion of "complete channel" until the run ends.
- **Multiplexing** — AUs from different runs may interleave.

v1.0 introduces **per-AU encryption** as a clean cut.
v0.x-encrypted files are readable only via the legacy
decryption path and cannot be streamed through transport without
explicit transcoding (see §6).

## 2. Options considered

Detailed in the v1 draft of this document (see commit 32963eb).
Summary:

- **Per-AU encryption** — recommended, adopted below.
- **Run-blob transport packet** — rejected: breaks selective
  access and real-time streaming.
- **Server-side transcoding** — rejected as a default mode
  (violates the spec's "MUST NOT decode payloads" rule); kept
  as an explicit `--transcode` opt-in for migration (see §6).

## 3. Adopted design

Two independent, composable encryption modes:

- **`opt_per_au_encryption`** — channel data is AES-256-GCM
  encrypted per Access Unit. One wrapped DEK per run; a fresh
  IV per AU per channel. AU filter-header fields remain
  plaintext; server-side filtering works keyless.
- **`opt_encrypted_au_headers`** — the AU's semantic filter
  fields are also AES-256-GCM encrypted per AU. Server-side
  filtering is disabled when this flag is set; clients download
  the full stream and filter locally after decryption.

Both flags may be set simultaneously. `opt_encrypted_au_headers`
without `opt_per_au_encryption` is **not** a legal combination
(channel data must be encrypted if headers are).

Rationale for separate flags: many deployments want channel-data
confidentiality but need server-side filtering for bandwidth. A
smaller but important subset (clinical PHI, competitive research)
needs total opacity even at the cost of full-stream transfer.

## 4. Wire format

### 4.1 ProtectionMetadata packet — unchanged from M71

Already shipped in all three languages. See
`docs/transport-spec.md` §4.4. The `cipher_suite` field names
`aes-256-gcm`; the `kek_algorithm` names the DEK-wrapping
algorithm (e.g. `rsa-oaep-sha256`, `ml-kem-1024`).

### 4.2 AU packet header flags

Bit assignments on `PacketHeader.flags` for encrypted transport:

| Bit | Name                          | Meaning                                   |
|----:|-------------------------------|-------------------------------------------|
| 0   | `ENCRYPTED`                   | Channel data in this AU is encrypted      |
| 2   | `HAS_CHECKSUM`                | (existing) CRC-32C follows payload        |
| 3   | `ENCRYPTED_HEADER`            | AU semantic header is also encrypted      |

Bit 1 (`COMPRESSED`) is reserved for a future packet-level
compression flag, unused today. Readers MUST reject `ENCRYPTED_HEADER`
without `ENCRYPTED`.

### 4.3 AU payload — plaintext header, plaintext channel

(Today's format, reproduced for completeness.)

```
spectrum_class:      uint8
acquisition_mode:    uint8
ms_level:            uint8
polarity:            uint8
retention_time:      float64
precursor_mz:        float64
precursor_charge:    uint8
ion_mobility:        float64
base_peak_intensity: float64
n_channels:          uint8
channels × n_channels  (ChannelData as in §4.3 of transport-spec)
pixel_x / pixel_y / pixel_z: uint32  (if spectrum_class == 4)
```

### 4.4 AU payload — plaintext header, encrypted channel (`ENCRYPTED` only)

```
spectrum_class:      uint8   ┐
acquisition_mode:    uint8   │
ms_level:            uint8   │
polarity:            uint8   │
retention_time:      float64 │ plaintext filter header (38 bytes)
precursor_mz:        float64 │ — server filters on these
precursor_charge:    uint8   │
ion_mobility:        float64 │
base_peak_intensity: float64 │
n_channels:          uint8   ┘
channels × n_channels:
    channel_name_len: uint16     ┐
    channel_name:     bytes      │ plaintext channel framing
    precision:        uint8      │
    compression:      uint8      │
    n_elements:       uint32     ┘
    data_length:      uint32     # 28 + ciphertext_bytes
    data:             bytes[data_length]
          = IV[12] || TAG[16] || ciphertext(plaintext-of-length n_elements*precision_size)
pixel_x / pixel_y / pixel_z: uint32  (if spectrum_class == 4, plaintext)
```

The AES-GCM authenticated data for each channel's
encrypt/decrypt operation covers:
- the channel's plaintext `channel_name` bytes
- the `dataset_id` and `au_sequence` from the enclosing
  PacketHeader (binds ciphertext to its stream position;
  prevents cut-and-paste attacks)

### 4.5 AU payload — encrypted header + encrypted channel (`ENCRYPTED | ENCRYPTED_HEADER`)

```
spectrum_class:      uint8         # plaintext — needed for dispatch
n_channels:          uint8         # plaintext — needed for parsing
IV_header:           bytes[12]
TAG_header:          bytes[16]
encrypted_semantic_header: bytes[36]
    # 36 = 1+1+1+8+8+1+8+8
    = AES-GCM(plaintext = acquisition_mode || ms_level || polarity ||
                          retention_time || precursor_mz ||
                          precursor_charge || ion_mobility ||
                          base_peak_intensity)
channels × n_channels:
    (as in §4.4 — encrypted channel layout)
if spectrum_class == 4:
    IV_pixel:  bytes[12]
    TAG_pixel: bytes[16]
    encrypted_pixel_xyz: bytes[12]   = AES-GCM(pixel_x || pixel_y || pixel_z)
```

Rationale for `spectrum_class` + `n_channels` staying plaintext:
the reader must be able to parse the packet without the key
(dispatch on spectrum_class, iterate through n_channels). These
are structural framing bytes, not semantic PHI.

When `ENCRYPTED_HEADER` is set the `PacketHeader`'s own filter
hints (`dataset_id`, `au_sequence`) remain plaintext — they're
routing metadata, not payload. Clients that require total
dataset_id opacity use separate connections per dataset.

### 4.6 Integrity binding

Every AES-GCM operation in an encrypted AU uses the
authenticated-data (AAD) parameter to bind ciphertext to
context:

- Channel encryption AAD = `dataset_id (u16 LE) || au_sequence
  (u32 LE) || channel_name_utf8`.
- Header encryption AAD = `dataset_id (u16 LE) || au_sequence
  (u32 LE) || b"header"`.
- Pixel encryption AAD = `dataset_id (u16 LE) || au_sequence
  (u32 LE) || b"pixel"`.

This prevents:
- Swapping a channel's ciphertext into another AU with a
  different sequence number.
- Treating the pixel block as a header envelope or vice versa.

### 4.7 Ordering

- `ProtectionMetadata` MUST precede any encrypted AU for its
  `dataset_id`.
- Exactly one `ProtectionMetadata` per `dataset_id` is required
  before encrypted AUs. Different `dataset_id`s MAY use
  different keys; emit one ProtectionMetadata per key.
- If neither `ENCRYPTED` nor `ENCRYPTED_HEADER` is set on a
  given AU, the AU is plaintext and the ProtectionMetadata's
  key is not required for that AU.

## 5. File format (v1.0 on-disk layout)

### 5.1 Feature flags

- `opt_per_au_encryption` — indicates the file uses per-AU
  encrypted channel segments.
- `opt_encrypted_au_headers` — indicates the file additionally
  encrypts AU semantic headers.

Both are **optional** features (`opt_` prefix); readers that
don't understand them may skip the file without failing, per the
feature-flag convention in `docs/feature-flags.md`.

### 5.2 Per-run encrypted channel layout

Replaces the v0.x `<channel>_values_encrypted` / `<channel>_iv`
/ `<channel>_tag` / `@<channel>_ciphertext_bytes` / `@<channel>_algorithm`
layout with a single compound dataset per channel:

```
signal_channels/
    <channel>_segments      compound dataset, one row per spectrum:
        offset:     uint64   — index into the plaintext (decompressed) flat stream
        length:     uint32   — plaintext element count
        iv:         uint8[12]
        tag:        uint8[16]
        ciphertext: VL[uint8]
    @<channel>_algorithm    string  "aes-256-gcm"
    @<channel>_wrapped_dek  VL[uint8]   wrapped via @kek_algorithm
    @<channel>_kek_algorithm string    e.g. "ml-kem-1024"
```

When `opt_encrypted_au_headers` is set, the `/spectrum_index`
group is also encrypted per-spectrum:

```
spectrum_index/
    au_header_segments      compound dataset, one row per spectrum:
        iv:  uint8[12]
        tag: uint8[16]
        ciphertext: uint8[36]   fixed 36-byte plaintext (1+1+1+8+8+1+8+8)
    @wrapped_dek           same key as channels (or separate key
                           for header-only decryption, see §7)
```

The plaintext `/spectrum_index/*` arrays that M57 defined
(offsets, lengths, retention_times, etc.) are **omitted** when
`opt_encrypted_au_headers` is set. Readers without the key
cannot enumerate the index. Readers with the key decrypt
`au_header_segments` to reconstruct the index arrays.

### 5.3 No v0.x backward compatibility

v0.x-encrypted files (`@encrypted="aes-256-gcm"` at the root
or run level, channel-grained `<channel>_values_encrypted`
layout) are not readable by v1.0 encryption paths. They remain
readable by the v0.x legacy decryption code, which stays in
each language's codebase for migration, but does not participate
in streaming.

## 6. Transcode migration path

`--transcode <key>` on the transport writer decrypts v0.x
channel-grained ciphertext on the way out using the provided
key and re-encrypts per-AU with a fresh IV per spectrum per
channel, using the **same** DEK (wrapped against the same KEK).

The transcoded output:
- Sets `opt_per_au_encryption` (and optionally
  `opt_encrypted_au_headers` if requested).
- Logs a `ProvenanceRecord` with `software =
  "mpgo-transport-transcode v1.0"`, `input_refs = [old_file_sha]`,
  `output_refs = [new_file_sha]`, `timestamp_unix = now`.
- Carries the original `wrapped_dek` in `ProtectionMetadata`;
  the receiver writes a v1.0 per-AU file with the same DEK so
  existing key escrow continues to work.

The server running the transcode holds the key for the duration
of the operation. This is documented as an explicit opt-in with
security implications, not a streaming-time default.

## 7. Open items resolved

1. ✅ **File layout**: new compound dataset; v0.x layout not
   supported in v1.0.
2. ✅ **AU header sensitivity**: `opt_encrypted_au_headers`
   lands in v1.0. Server-side filtering is disabled when set.
3. ✅ **`--transcode`**: acceptable migration opt-in with
   provenance logging.
4. 🟡 **Header-only decryption key**. Do we want a separate
   wrapped DEK for the header segments so a filter server can
   be granted header-only read without payload access? My read
   is no — complexity outweighs the benefit, and users who
   want that tier can run a proxy with full keys. **Proposed:
   single DEK per run covers both header and channel
   segments.** Flag for later if usage demands.
5. 🟡 **Sub-spectrum crypto granularity**. For ion-mobility
   spectra with >100K points, per-spectrum AES-GCM is one op
   over ~800KB. Fine for current workloads. Leave
   `<channel>_segments.chunk_offset: uint32` as a reserved
   nullable column for a later extension; v1.0 writes one row
   per full spectrum.
6. ✅ **PQC composition**. ML-KEM-1024 + ML-DSA-87 (M49) works
   unchanged: the KEM wraps the DEK, the DEK drives per-AU
   AES-GCM.

## 8. Implementation plan

### 8.1 Spec updates (non-code)

- [ ] `docs/format-spec.md` — add §5.5 "Per-AU encrypted
  channel layout" documenting `<channel>_segments` and
  `spectrum_index/au_header_segments`.
- [ ] `docs/transport-spec.md` — add §4.5 (plaintext-header
  encrypted-channel AU), §4.6 (fully-encrypted AU), §4.7
  (AAD binding rule). Update §3.2 flag table.
- [ ] `docs/feature-flags.md` — register
  `opt_per_au_encryption` and `opt_encrypted_au_headers`.
- [ ] `docs/pqc.md` — add section "Transport encryption
  composition" describing the DEK-driven per-AU path.

### 8.2 Reference implementation (Python, first)

- [ ] `mpeg_o.encryption.encrypt_per_au(dataset, key)` — new
  writer path, emits `<channel>_segments` and
  `au_header_segments` compounds. Deterministic ciphertext
  given (plaintext, key, IV).
- [ ] `mpeg_o.encryption.decrypt_per_au_channel` /
  `decrypt_per_au_header` — reader counterparts.
- [ ] `mpeg_o.transport.codec.TransportWriter` — detect
  `opt_per_au_encryption` and `opt_encrypted_au_headers`;
  package encrypted segments into `ChannelData.data` bytes
  with AAD binding.
- [ ] `mpeg_o.transport.codec.TransportReader` — honor
  encrypted variants, materialize target file with the same
  flags and same DEK.
- [ ] Tests: per-AU encrypt → stream → decrypt round-trip;
  encrypted-headers round-trip; AAD tamper detection;
  ProtectionMetadata preservation; PQC variant.
- [ ] Cross-backend (HDF5, SQLite, Zarr) encrypted round-trips.

### 8.3 ObjC port

- [ ] `MPGOEncryptionManager` — add `encryptPerAUWithKey:`.
- [ ] `MPGOTransportWriter` / `MPGOTransportReader` — detect
  flags and handle the three AU variants.
- [ ] Tests: mirror Python coverage in `TestEncryptedTransport.m`.

### 8.4 Java port

- [ ] `com.dtwthalion.mpgo.protection.EncryptionManager` —
  add `encryptPerAU(key)`.
- [ ] `TransportWriter` / `TransportReader` updates.
- [ ] Tests: mirror Python coverage in
  `EncryptedTransportTest.java`.

### 8.5 Cross-language conformance

- [ ] Python drives Java+ObjC subprocesses: encrypt in one
  language, stream, materialize in another, decrypt, verify
  values.
- [ ] PQC cross-language variant.

### 8.6 Release

- [ ] `--transcode` migration path shipped and documented.
- [ ] `CHANGELOG.md` v0.10.0 entry.
- [ ] Tag v0.10.0 (user-gated per binding decision).

## 9. Sizing

Per language, rough estimate (non-test):

- Encryption module extension (per-AU mode for channel + header):
  ~300 LOC.
- `encrypt_per_au` HDF5 / provider plumbing: ~150 LOC.
- TransportWriter encrypted paths (three variants):
  ~150 LOC.
- TransportReader encrypted paths:
  ~200 LOC.
- `--transcode` path: ~100 LOC.
- Tests: ~300 LOC.

**Total per language: ~1200 LOC.** Three languages + cross-language
conformance: ~4000 LOC across roughly three concentrated
sessions.

## 10. Not in scope

- LZ4 / Numpress-delta wire codecs (same opt-in pattern as
  M71.5's ZLIB; scheduled for a follow-up).
- Ion-mobility + MSImage importer-specific encrypted-transport
  integration tests (write the tests when the importers
  themselves encrypt; deferred to v1.1).
- Chromatogram packet encryption (chromatograms are run-scoped
  aggregates; revisit when chromatogram packets ship with real
  data instead of stubs).
