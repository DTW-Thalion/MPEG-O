/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_TRANSPORT_WRITER_H
#define TTIO_TRANSPORT_WRITER_H

#import <Foundation/Foundation.h>
#import "TTIOTransportPacket.h"
#import "TTIOAccessUnit.h"

@class TTIOSpectralDataset;
@class TTIOAcquisitionRun;
@class TTIOGenomicRun;
@class TTIOReferenceImport;
@class TTIOProvenanceRecord;
@class TTIOMSImage;
@class TTIORamanImage;
@class TTIOIRImage;
@class TTIOIdentification;
@class TTIOQuantification;
@class TTIOSubject;
@class TTIOSample;

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject (informal)</p>
 * <p><em>Declared In:</em> Transport/TTIOTransportWriter.h</p>
 *
 * <p>Sink protocol for <code>TTIOTransportWriter</code>. Abstracts
 * the byte destination so callers can plug in arbitrary streaming
 * consumers (e.g. a WebSocket send queue) without intermediate
 * buffering. Symmetric with Python's
 * <code>BinaryIO</code> sink and Java's
 * <code>OutputStream</code>.</p>
 *
 * <p>The writer calls <code>-writeData:</code> once per encoded
 * packet (one StreamHeader, one DatasetHeader, one AccessUnit, one
 * EndOfDataset, one EndOfStream, etc.). Implementations should
 * forward synchronously — the writer does not buffer or coalesce
 * between calls.</p>
 */
@protocol TTIOTransportWriterSink <NSObject>
/**
 * Forward one encoded packet to the underlying byte destination.
 *
 * Called once per emitted packet by ``TTIOTransportWriter``. The
 * implementation should forward synchronously — the writer does
 * not coalesce or retry between calls.
 *
 * @param data The fully-encoded packet bytes (header + payload + optional CRC).
 */
- (void)writeData:(NSData *)data;
@end

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject),
 *    <code>TTIOTransportWriterSink</code></p>
 *
 * <p>Default in-memory sink — accumulates every emitted packet onto
 * an <code>NSMutableData</code> buffer. Used internally by
 * <code>-[TTIOTransportWriter initWithMutableData:]</code> and
 * exposed as a public class so callers can pass it directly to the
 * sink-based initialiser without writing their own wrapper.</p>
 */
@interface TTIOMutableDataSink : NSObject <TTIOTransportWriterSink>
/** The underlying mutable buffer that received every emitted packet. */
@property (nonatomic, readonly) NSMutableData *data;

/**
 * Create a sink backed by a fresh empty ``NSMutableData``.
 *
 * @return A new sink ready to receive packets.
 */
+ (instancetype)sink;

/**
 * Create a sink backed by a caller-owned mutable buffer.
 *
 * Packets are appended to ``data`` in emission order.
 *
 * @param data Buffer to append into. Must not be ``nil``.
 * @return Initialised sink instance.
 */
- (instancetype)initWithData:(NSMutableData *)data;
@end

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOTransportWriter.h</p>
 *
 * <p>Serialises a <code>TTIOSpectralDataset</code> as a transport
 * byte stream. Walks <code>msRuns</code>, emits StreamHeader &#8594;
 * DatasetHeaders &#8594; AccessUnits &#8594; EndOfDataset &#8594;
 * EndOfStream. A fine-grained API is also exposed for callers that
 * synthesise streams packet-by-packet
 * (<code>TTIOAcquisitionSimulator</code>,
 * <code>TTIOEncryptedTransport</code>).</p>
 *
 * <p>Three sink modes:</p>
 * <ul>
 *  <li><code>-initWithOutputPath:</code> &#8594; writes to a file.</li>
 *  <li><code>-initWithMutableData:</code> &#8594; appends to a
 *      caller-owned <code>NSMutableData</code> (back-compat alias
 *      for <code>-initWithSink:[TTIOMutableDataSink sink]</code>).</li>
 *  <li><code>-initWithSink:</code> &#8594; arbitrary
 *      <code>TTIOTransportWriterSink</code> implementation; the
 *      writer calls <code>-writeData:</code> once per packet. Use
 *      for streaming consumers (WebSocket send queue, pipe, etc.).</li>
 * </ul>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.transport.codec.TransportWriter</code><br/>
 * Java:
 * <code>global.thalion.ttio.transport.TransportWriter</code></p>
 */
@interface TTIOTransportWriter : NSObject

/** Whether each packet's payload is followed by a CRC-32C checksum
 *  (sets TTIOTransportPacketFlagHasChecksum). Default NO. */
@property (nonatomic) BOOL useChecksum;

/** Compress each channel's float64 bytes with zlib on the wire,
 *  setting ``TTIOCompressionZlib`` on the ChannelData. The reader
 *  decompresses automatically regardless of this flag. Default NO. */
@property (nonatomic) BOOL useCompression;

/** Phase 2c-T: when YES, probe each genomic run for v2 codec blobs
 *  and emit BlobV2* packets carrying them verbatim. Allows the
 *  receiver to skip the v2 codec encode pass on the receiver side
 *  and preserves blob byte-identity across deterministic codecs.
 *  See docs/transport-spec.md §6.4. Default NO. */
@property (nonatomic) BOOL useBulkMode;

/**
 * Initialise a writer that emits packets to a file on disk.
 *
 * The file is opened (creating or truncating) and closed by
 * ``-close``. Each emitted packet is appended in order.
 *
 * @param path Filesystem path of the ``.tis`` file to write.
 * @return Initialised writer instance.
 */
- (instancetype)initWithOutputPath:(NSString *)path;

/**
 * Initialise a writer that appends packets to a caller-owned buffer.
 *
 * Convenience over ``-initWithSink:`` that wraps ``data`` in a
 * fresh ``TTIOMutableDataSink``. The buffer is borrowed; the
 * writer never reads from or shrinks it.
 *
 * @param data Mutable buffer to append packets into.
 * @return Initialised writer instance.
 */
- (instancetype)initWithMutableData:(NSMutableData *)data;

/**
 * Designated streaming initialiser.
 *
 * The writer calls ``-[sink writeData:]`` once per encoded packet.
 * Use this for WebSocket / pipe / custom sinks where intermediate
 * buffering is undesirable.
 *
 * @param sink Conforming sink to forward packets to. Borrowed.
 * @return Initialised writer instance.
 */
- (instancetype)initWithSink:(id<TTIOTransportWriterSink>)sink;

/**
 * Walk ``dataset`` and emit the complete transport packet sequence.
 *
 * Emits ``StreamHeader``, the optional v0.11 prelude (encryption
 * algorithm, dataset provenance, subjects, samples, reference
 * groups, image cubes, identifications, quantifications), then
 * per-dataset ``DatasetHeader`` + access units + ``EndOfDataset``,
 * finishing with ``EndOfStream``. Spectral runs are emitted with
 * dataset ids ``1..N`` and genomic runs with ``N+1..N+M``.
 *
 * @param dataset Source container to serialise. Borrowed.
 * @param error   On failure, populated with an ``NSError``
 *                describing the cause. May be ``NULL``.
 *
 * @return ``YES`` on success, ``NO`` on failure (and ``*error`` is
 *         set if non-NULL).
 */
- (BOOL)writeDataset:(TTIOSpectralDataset *)dataset
               error:(NSError * _Nullable *)error;

// --- Fine-grained API ---

/**
 * Emit the leading ``StreamHeader`` packet.
 *
 * Must be the first packet on the wire (transport-spec §5.4).
 * The ``features`` list declares opt-in wire-format extensions
 * present in the stream (e.g. ``BULK_MODE_V2_BLOBS_FEATURE``).
 *
 * @param formatVersion     Container format version string (e.g.
 *                          ``@"1.2"``).
 * @param title             Free-form container title.
 * @param isaInvestigation  ISA-Tab investigation identifier (may
 *                          be empty).
 * @param features          Feature flag strings.
 * @param nDatasets         Number of dataset blocks the stream
 *                          contains.
 * @param error             On failure, populated with an
 *                          ``NSError``. May be ``NULL``.
 *
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)writeStreamHeaderWithFormatVersion:(NSString *)formatVersion
                                      title:(NSString *)title
                           isaInvestigation:(NSString *)isaInvestigation
                                   features:(NSArray<NSString *> *)features
                                 nDatasets:(uint16_t)nDatasets
                                      error:(NSError * _Nullable *)error;

/**
 * Emit a ``DatasetHeader`` packet announcing a dataset's schema.
 *
 * One ``DatasetHeader`` precedes every dataset's access units;
 * the packet declares the dataset's identity, schema, and
 * instrument metadata so the reader can allocate per-dataset
 * buffers before AU ingest.
 *
 * @param datasetId        1-based dataset identifier within the
 *                         stream (``uint16``).
 * @param name             Dataset (run) name.
 * @param acquisitionMode  Wire encoding of the acquisition mode.
 * @param spectrumClass    ObjC class name for the spectrum type
 *                         (e.g. ``@"TTIOMassSpectrum"``).
 * @param channelNames     Ordered signal-channel names.
 * @param instrumentJSON   JSON-encoded instrument config or
 *                         genomic-run metadata.
 * @param expectedAUCount  Total AU count for the dataset; ``0``
 *                         when unknown.
 * @param error            On failure, populated with an
 *                         ``NSError``. May be ``NULL``.
 *
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)writeDatasetHeaderWithDatasetId:(uint16_t)datasetId
                                    name:(NSString *)name
                         acquisitionMode:(uint8_t)acquisitionMode
                           spectrumClass:(NSString *)spectrumClass
                            channelNames:(NSArray<NSString *> *)channelNames
                          instrumentJSON:(NSString *)instrumentJSON
                        expectedAUCount:(uint32_t)expectedAUCount
                                   error:(NSError * _Nullable *)error;

/**
 * Emit one ``ACCESS_UNIT`` packet.
 *
 * The ``TTIOAccessUnit`` is serialised via its own ``toBytes``
 * routine and framed with the dataset id + AU sequence in the
 * packet header.
 *
 * @param au          Access unit to emit.
 * @param datasetId   Owning dataset id (matches the prior
 *                    ``DatasetHeader``).
 * @param auSequence  0-based monotonically increasing AU index
 *                    within the dataset.
 * @param error       On failure, populated with an ``NSError``.
 *                    May be ``NULL``.
 *
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)writeAccessUnit:(TTIOAccessUnit *)au
              datasetId:(uint16_t)datasetId
             auSequence:(uint32_t)auSequence
                  error:(NSError * _Nullable *)error;

/**
 * Emit an ``END_OF_DATASET`` sentinel packet.
 *
 * Terminates a dataset's access-unit run. The reader uses
 * ``finalAUSequence`` to verify it observed every expected AU.
 *
 * @param datasetId        Owning dataset id.
 * @param finalAUSequence  One past the last ``au_sequence``
 *                         emitted for the dataset (i.e. the AU
 *                         count).
 * @param error            On failure, populated with an
 *                         ``NSError``. May be ``NULL``.
 *
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)writeEndOfDatasetWithDatasetId:(uint16_t)datasetId
                       finalAUSequence:(uint32_t)finalAUSequence
                                  error:(NSError * _Nullable *)error;

/**
 * Phase 2c-T: emit a ``BLOB_V2_MATE_INFO`` packet (transport-spec §4.10).
 *
 * Carries the verbatim ``mate_info/inline_v2`` blob plus its
 * accompanying chromosome-name table so the reader can write the
 * blob back without re-running the v2 codec encoder. Emitted only
 * in bulk mode (``useBulkMode == YES``) for runs whose source has
 * a v2 ``mate_info`` group.
 *
 * @param datasetId   Genomic dataset id the blob belongs to.
 * @param chromNames  Chromosome names ordered by row index.
 * @param blob        Verbatim mate-info blob bytes.
 * @param error       On failure, populated with an ``NSError``.
 *                    May be ``NULL``.
 *
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)writeBlobV2MateInfoWithDatasetId:(uint16_t)datasetId
                              chromNames:(NSArray<NSString *> *)chromNames
                                    blob:(NSData *)blob
                                    error:(NSError * _Nullable *)error;

/**
 * Phase 2c-T: emit a ``BLOB_V2_REF_DIFF`` packet (transport-spec §4.11).
 *
 * Carries the verbatim ``sequences/refdiff_v2`` blob keyed by its
 * source reference URI so the reader can rebuild the per-AU
 * sequences without re-encoding.
 *
 * @param datasetId     Genomic dataset id.
 * @param referenceUri  Source reference URI for the diff blob.
 * @param blob          Verbatim ref-diff blob bytes.
 * @param error         On failure, populated with an ``NSError``.
 *                      May be ``NULL``.
 *
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)writeBlobV2RefDiffWithDatasetId:(uint16_t)datasetId
                            referenceUri:(NSString *)referenceUri
                                    blob:(NSData *)blob
                                    error:(NSError * _Nullable *)error;

/**
 * Phase 2c-T: emit a ``BLOB_V2_NAME_TOK`` packet (transport-spec §4.12).
 *
 * Carries the verbatim tokenised-read-names blob so the reader can
 * write the blob back without re-running the v2 name codec encoder.
 *
 * @param datasetId  Genomic dataset id.
 * @param blob       Verbatim name-tok blob bytes.
 * @param error      On failure, populated with an ``NSError``.
 *                   May be ``NULL``.
 *
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)writeBlobV2NameTokWithDatasetId:(uint16_t)datasetId
                                    blob:(NSData *)blob
                                    error:(NSError * _Nullable *)error;

/**
 * v0.11 Stage 1 / Task 3.2: emit a <code>TTIOReferenceImport</code>
 * as the packet sequence
 * <code>REFERENCE_GROUP_HEADER (0x10) -&gt; N x REFERENCE_CHROMOSOME
 * (0x11) -&gt; END_OF_REFERENCE_GROUP (0x12)</code>.
 *
 * <p>Wire layout matches transport-spec §4.13-§4.15. All multi-byte
 * integers are LITTLE-ENDIAN (spec §1.7). The chromosome index rides
 * in the packet header's <code>auSequence</code> field (0-based). The
 * MD5 hex string from
 * <code>-[TTIOReferenceImport md5Hex]</code> is emitted verbatim as
 * 32 ASCII bytes.</p>
 *
 * <p>The encoding byte on each chromosome record is 0 (uncompressed
 * UINT8) when the raw sequence is shorter than 4 KiB, otherwise 1
 * (zlib via <code>compress2</code> with the default compression
 * level).</p>
 *
 * <p>Reader-side materialisation is added by Task 3.3; this method
 * only emits the wire bytes. Java parity:
 * <code>TransportWriter.writeReferenceGroup(ReferenceImport)</code>
 * (commit <code>622aa8bd</code>). Python parity:
 * <code>TransportWriter.write_reference_group</code> (commit
 * <code>ec529a8b</code>).</p>
 */
- (BOOL)writeReferenceGroup:(TTIOReferenceImport *)ref
                       error:(NSError * _Nullable *)error;

/**
 * v0.11 Task 3.4: emit an <code>ENCRYPTION_ALGORITHM</code> (0x1B)
 * packet carrying the dataset-level <code>@encrypted</code> algorithm
 * identifier (e.g. <code>@"aes-256-gcm"</code>). Wire layout per
 * transport-spec §4.23:
 *
 * <pre>
 * algorithm_length:  uint16
 * algorithm_utf8:    bytes[algorithm_length]
 * </pre>
 *
 * <p>All multi-byte integers LITTLE-ENDIAN per spec §1.7. Per-AU key
 * material continues to ride on <code>ProtectionMetadata</code> (0x04);
 * this packet conveys only the algorithm-name string.</p>
 *
 * <p>Java parity:
 * <code>TransportWriter.writeEncryptionAlgorithm</code> (commit
 * <code>530a5833</code>). Python parity:
 * <code>TransportWriter.write_encryption_algorithm</code> (commit
 * <code>bf38bdc9</code>).</p>
 */
- (BOOL)writeEncryptionAlgorithm:(NSString *)algorithm
                            error:(NSError * _Nullable *)error;

/**
 * v0.11 Task 3.5: emit a <code>DATASET_PROVENANCE</code> (0x18) packet
 * carrying the dataset-level provenance chain (format-spec §6.3). A
 * single packet carries all records. Wire layout per transport-spec
 * §4.21:
 *
 * <pre>
 * record_count:        uint32
 * # repeated record_count times:
 * timestamp_unix:      int64
 * software_length:     uint16, software bytes[..]      (UTF-8)
 * parameters_length:   uint16, parameters_json[..]     (UTF-8 JSON)
 * input_refs_length:   uint16, input_refs_csv[..]      (UTF-8 CSV)
 * output_refs_length:  uint16, output_refs_csv[..]     (UTF-8 CSV)
 * </pre>
 *
 * <p>All multi-byte integers LITTLE-ENDIAN per spec §1.7. The
 * input_refs / output_refs lists ride as comma-joined UTF-8 — a
 * single empty string for an empty list (no separators). The
 * <code>parameters_json</code> field is the parameters dict
 * serialised via <code>NSJSONSerialization</code> with
 * <code>NSJSONWritingSortedKeys</code> so on-wire ordering matches
 * Python (<code>json.dumps(d, sort_keys=True)</code>); Java preserves
 * its <code>Map.copyOf</code> iteration order so per-record byte
 * parity across all three languages requires the source dict to be a
 * single-key dict (the test fixtures use single-key dicts to
 * guarantee parity, mirroring the Python and Java test pattern).</p>
 *
 * <p>Distinct from the per-run <code>Provenance</code> (0x06) packet,
 * which carries one JSON record per packet. An empty
 * <code>records</code> array is a no-op (no packet emitted) per
 * spec §5.4 step 2 ("zero or more").</p>
 *
 * <p>Java parity:
 * <code>TransportWriter.writeDatasetProvenance</code> (commit
 * <code>563e09c3</code>). Python parity:
 * <code>TransportWriter.write_dataset_provenance</code> (commit
 * <code>434d45a6</code>).</p>
 */
- (BOOL)writeDatasetProvenance:(NSArray<TTIOProvenanceRecord *> *)records
                          error:(NSError * _Nullable *)error;

/**
 * v0.11 Task 3.6: emit a <code>TTIOMSImage</code> as the packet sequence
 * <code>IMAGE_HEADER (0x13) -&gt; N x IMAGE_PIXEL (0x14)
 *  -&gt; END_OF_IMAGE (0x15)</code>, where <code>N = width * height</code>.
 *
 * <p>Wire layout matches transport-spec §4.16-§4.18. All multi-byte
 * integers are LITTLE-ENDIAN (spec §1.7). Each pixel rides as a
 * continuous-mode IMAGE_PIXEL — the shared m/z axis lives on the
 * IMAGE_HEADER, and every pixel carries only its intensities (FLOAT64,
 * uncompressed). The pixel index rides in the packet header's
 * <code>auSequence</code> field (<code>y * width + x</code>; 0-based).</p>
 *
 * <p>Processed-mode (sparse <code>{channel,intensity}</code> pairs,
 * signalled by <code>is_continuous == 0</code>) is emitted by the
 * opt-in sibling <code>-writeImageProcessed:</code> below.
 * Java parity: <code>TransportWriter.writeImage</code> (commit
 * <code>a6b1e5d9</code>). Python parity:
 * <code>TransportWriter.write_image</code> (commit
 * <code>1f619ced</code>).</p>
 */
- (BOOL)writeImage:(TTIOMSImage *)image
              error:(NSError * _Nullable *)error;

/**
 * v0.11 Task 5.1 (Deferral 1): emit a <code>TTIOMSImage</code> as
 * the packet sequence
 * <code>IMAGE_HEADER (0x13) -&gt; N x IMAGE_PIXEL (0x14) -&gt;
 *  END_OF_IMAGE (0x15)</code> in <strong>processed mode</strong>
 * (sparse), where each pixel carries only its nonzero
 * <code>(channel_index, intensity)</code> pairs indexed into the
 * shared <code>mzAxis</code>. The dense cube is reconstructed by
 * the reader.
 *
 * <p>Wire layout per transport-spec §4.17 (LITTLE-ENDIAN). The
 * IMAGE_HEADER is identical to <code>-writeImage:</code> except
 * for <code>is_continuous == 0</code>; each IMAGE_PIXEL payload
 * is:</p>
 *
 * <pre>
 *   x(u32) + y(u32) + precision(u8) + compression(u8)
 *     + payload_length(u32)
 *     + payload_bytes = nonzero_count(u32)
 *         + nonzero_count × { channel_index(u32) + intensity(f64) }
 * </pre>
 *
 * <p>Nonzero is defined strictly as <code>v != 0.0</code>; NaN is
 * preserved verbatim (NaN compares unequal to 0.0). The TTIOMSImage
 * data model stays dense; processed mode is purely a wire
 * optimisation for sparse cubes.</p>
 *
 * <p>This is an opt-in sibling of <code>-writeImage:</code>.
 * Callers pick continuous vs processed mode explicitly today; an
 * automatic heuristic (emit whichever is smaller) lands in a
 * follow-up task. Java parity:
 * <code>TransportWriter.writeImageProcessed</code> (commit
 * <code>1889343e</code>). Python parity:
 * <code>TransportWriter.write_image_processed</code> (commit
 * <code>8eac605a</code>).</p>
 */
- (BOOL)writeImageProcessed:(TTIOMSImage *)image
                      error:(NSError * _Nullable *)error;

/**
 * v0.11 Task 5.3 (Deferral 1): emit a <code>TTIORamanImage</code>
 * as the packet sequence
 * <code>IMAGE_HEADER (0x13) -&gt; N x IMAGE_PIXEL (0x14) -&gt;
 *  END_OF_IMAGE (0x15)</code> with <code>modality = 1</code>.
 *
 * <p>Wire layout per transport-spec §4.16 (LITTLE-ENDIAN). The
 * shared axis on the IMAGE_HEADER carries the Raman wavenumbers
 * vector (<code>axis_kind = 1 = wavenumber</code>). The
 * <code>modality_extras</code> slot at the tail of the
 * IMAGE_HEADER carries:</p>
 *
 * <pre>
 *   excitation_wavelength_nm: float64
 *   laser_power_mw:           float64
 * </pre>
 *
 * <p>(16 bytes total.) Each pixel rides as a continuous-mode
 * IMAGE_PIXEL whose <code>payload_bytes</code> is a dense vector
 * of <code>spectrum_bins</code> FLOAT64 intensities at the shared
 * wavenumber axis.</p>
 *
 * <p>Java parity: <code>TransportWriter.writeRamanImage</code>
 * (commit <code>f99ec47d</code>). Python parity:
 * <code>TransportWriter.write_raman_image</code> (commit
 * <code>6abead73</code>).</p>
 */
- (BOOL)writeRamanImage:(TTIORamanImage *)image
                  error:(NSError * _Nullable *)error;

/**
 * v0.11 Task 5.3 (Deferral 1): emit a <code>TTIOIRImage</code> as
 * the packet sequence
 * <code>IMAGE_HEADER (0x13) -&gt; N x IMAGE_PIXEL (0x14) -&gt;
 *  END_OF_IMAGE (0x15)</code> with <code>modality = 2</code>.
 *
 * <p>Wire layout per transport-spec §4.16 (LITTLE-ENDIAN). The
 * shared axis carries the IR wavenumbers vector
 * (<code>axis_kind = 1 = wavenumber</code>). The
 * <code>modality_extras</code> slot carries:</p>
 *
 * <pre>
 *   ir_mode:            uint8   # 0=TRANSMITTANCE, 1=ABSORBANCE
 *   resolution_cm_inv:  float64
 * </pre>
 *
 * <p>(9 bytes total.) Java parity:
 * <code>TransportWriter.writeIRImage</code> (commit
 * <code>f99ec47d</code>). Python parity:
 * <code>TransportWriter.write_ir_image</code> (commit
 * <code>6abead73</code>).</p>
 */
- (BOOL)writeIRImage:(TTIOIRImage *)image
               error:(NSError * _Nullable *)error;

/**
 * v0.11 Task 3.7: emit an <code>IDENTIFICATIONS_TABLE</code> (0x16)
 * packet carrying the full identifications table as a single
 * length-prefixed Apache Arrow IPC stream. Wire layout per
 * transport-spec §4.19:
 *
 * <pre>
 * arrow_ipc_length:    uint32
 * arrow_ipc:           bytes[arrow_ipc_length]   # self-describing IPC
 * </pre>
 *
 * <p>All multi-byte integers LITTLE-ENDIAN per spec §1.7. The Arrow
 * IPC stream carries its own schema, row count, and null bitmaps,
 * so no per-row TLV envelope is needed. An empty <code>rows</code>
 * array is a no-op (no packet emitted) per spec §5.4 step 6 ("zero
 * or more").</p>
 *
 * <p>The Arrow IPC payload bytes are NOT byte-identical to Java /
 * Python — each Arrow binding produces a slightly different
 * flatbuffer envelope encoding. All three SDKs decode each other's
 * bytes (logical equivalence is the contract). The uint32 length
 * prefix IS byte-identical.</p>
 *
 * <p>Java parity: <code>TransportWriter.writeIdentifications</code>
 * (commit <code>a6faab16</code>). Python parity:
 * <code>TransportWriter.write_identifications_table</code> (commit
 * <code>150552b6</code>).</p>
 */
- (BOOL)writeIdentificationsTable:(NSArray<TTIOIdentification *> *)rows
                              error:(NSError * _Nullable *)error;

/**
 * v0.11 Task 3.7: emit a <code>QUANTIFICATIONS_TABLE</code> (0x17)
 * packet carrying the full quantifications table as a single
 * length-prefixed Apache Arrow IPC stream. Wire layout per
 * transport-spec §4.20 — identical shape to §4.19 but with a
 * distinct packet type so receivers can dispatch without parsing
 * the IPC payload first.
 *
 * <p>An empty <code>rows</code> array is a no-op (spec §5.4 step 6).
 * Java parity: <code>TransportWriter.writeQuantifications</code>
 * (commit <code>a6faab16</code>). Python parity:
 * <code>TransportWriter.write_quantifications_table</code> (commit
 * <code>150552b6</code>).</p>
 */
- (BOOL)writeQuantificationsTable:(NSArray<TTIOQuantification *> *)rows
                              error:(NSError * _Nullable *)error;

/**
 * v0.11 Task 6.4 (Stage 6): emit a <code>SUBJECT_METADATA</code>
 * (0x19) packet carrying the dataset-level subject table as a single
 * length-prefixed Apache Arrow IPC stream. Wire layout per
 * transport-spec §4.22:
 *
 * <pre>
 * arrow_ipc_length:    uint32
 * arrow_ipc:           bytes[arrow_ipc_length]   # self-describing IPC
 * </pre>
 *
 * <p>All multi-byte integers LITTLE-ENDIAN per spec §1.7. Wire shape
 * mirrors <code>-writeIdentificationsTable:</code> exactly. An empty
 * <code>rows</code> array emits no packet per spec §5.4 step 5
 * ("zero or more").</p>
 *
 * <p>Java parity:
 * <code>TransportWriter.writeSubjectMetadata</code> (commit
 * <code>dd211600</code>). Python parity:
 * <code>TransportWriter.write_subject_metadata</code> (commit
 * <code>00c7e1b7</code>).</p>
 */
- (BOOL)writeSubjectMetadata:(NSArray<TTIOSubject *> *)rows
                       error:(NSError * _Nullable *)error;

/**
 * v0.11 Task 6.4 (Stage 6): emit a <code>SAMPLE_METADATA</code>
 * (0x1A) packet — identical shape to §4.22, distinct packet type so
 * receivers can dispatch without parsing the IPC payload.
 *
 * <p>Java parity:
 * <code>TransportWriter.writeSampleMetadata</code>. Python parity:
 * <code>TransportWriter.write_sample_metadata</code>.</p>
 */
- (BOOL)writeSampleMetadata:(NSArray<TTIOSample *> *)rows
                      error:(NSError * _Nullable *)error;

/**
 * Emit the trailing ``END_OF_STREAM`` sentinel packet.
 *
 * Marks the end of the transport stream. The reader stops
 * ingesting after this packet.
 *
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return ``YES`` on success, ``NO`` on failure.
 */
- (BOOL)writeEndOfStreamWithError:(NSError * _Nullable *)error;

/** Emits a single GenomicRun as a stream segment.
 *
 *  Writes the dataset header
 *  (<code>spectrum_class = "TTIOGenomicRead"</code>,
 *  <code>channel_names = ["sequences", "qualities"]</code>,
 *  reference / platform metadata in the
 *  <code>instrument_json</code> slot), then one ACCESS_UNIT per read
 *  with the genomic suffix populated, then end-of-dataset.
 *
 *  The caller is responsible for stream framing
 *  (<code>-writeStreamHeader...</code> /
 *  <code>-writeEndOfStream...</code>). For full-dataset emission
 *  use <code>-writeDataset:error:</code>, which calls this
 *  internally for each genomic run after the MS runs. */
- (BOOL)writeGenomicRun:(TTIOGenomicRun *)run
              datasetId:(uint16_t)datasetId
                   name:(NSString *)name
                  error:(NSError * _Nullable *)error;

/**
 * Close the underlying file sink, if any.
 *
 * No-op when the writer was constructed with ``-initWithSink:`` or
 * ``-initWithMutableData:`` (no file is owned). Safe to call more
 * than once.
 */
- (void)close;

@end

NS_ASSUME_NONNULL_END

#endif
