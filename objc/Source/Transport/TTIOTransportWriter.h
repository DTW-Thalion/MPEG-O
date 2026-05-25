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
@property (nonatomic, readonly) NSMutableData *data;
+ (instancetype)sink;
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

- (instancetype)initWithOutputPath:(NSString *)path;
- (instancetype)initWithMutableData:(NSMutableData *)data;

/** Designated streaming initialiser. The writer calls
 *  <code>-[sink writeData:]</code> once per encoded packet — use
 *  this for WebSocket / pipe / custom sinks where intermediate
 *  buffering is undesirable. */
- (instancetype)initWithSink:(id<TTIOTransportWriterSink>)sink;

/** Full-dataset convenience. Emits the entire packet sequence. */
- (BOOL)writeDataset:(TTIOSpectralDataset *)dataset
               error:(NSError * _Nullable *)error;

// --- Fine-grained API ---

- (BOOL)writeStreamHeaderWithFormatVersion:(NSString *)formatVersion
                                      title:(NSString *)title
                           isaInvestigation:(NSString *)isaInvestigation
                                   features:(NSArray<NSString *> *)features
                                 nDatasets:(uint16_t)nDatasets
                                      error:(NSError * _Nullable *)error;

- (BOOL)writeDatasetHeaderWithDatasetId:(uint16_t)datasetId
                                    name:(NSString *)name
                         acquisitionMode:(uint8_t)acquisitionMode
                           spectrumClass:(NSString *)spectrumClass
                            channelNames:(NSArray<NSString *> *)channelNames
                          instrumentJSON:(NSString *)instrumentJSON
                        expectedAUCount:(uint32_t)expectedAUCount
                                   error:(NSError * _Nullable *)error;

- (BOOL)writeAccessUnit:(TTIOAccessUnit *)au
              datasetId:(uint16_t)datasetId
             auSequence:(uint32_t)auSequence
                  error:(NSError * _Nullable *)error;

- (BOOL)writeEndOfDatasetWithDatasetId:(uint16_t)datasetId
                       finalAUSequence:(uint32_t)finalAUSequence
                                  error:(NSError * _Nullable *)error;

/** Phase 2c-T (transport-spec §4.10). */
- (BOOL)writeBlobV2MateInfoWithDatasetId:(uint16_t)datasetId
                              chromNames:(NSArray<NSString *> *)chromNames
                                    blob:(NSData *)blob
                                    error:(NSError * _Nullable *)error;

/** Phase 2c-T (transport-spec §4.11). */
- (BOOL)writeBlobV2RefDiffWithDatasetId:(uint16_t)datasetId
                            referenceUri:(NSString *)referenceUri
                                    blob:(NSData *)blob
                                    error:(NSError * _Nullable *)error;

/** Phase 2c-T (transport-spec §4.12). */
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

- (void)close;

@end

NS_ASSUME_NONNULL_END

#endif
