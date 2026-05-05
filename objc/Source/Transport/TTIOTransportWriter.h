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

NS_ASSUME_NONNULL_BEGIN

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
