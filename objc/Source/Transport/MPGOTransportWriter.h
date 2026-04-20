/*
 * MPGOTransportWriter — v0.10 M67.
 *
 * Serializes an MPGOSpectralDataset as a transport byte stream.
 * Walks ``msRuns``, emits StreamHeader → DatasetHeaders →
 * AccessUnits → EndOfDataset → EndOfStream.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.transport.codec.TransportWriter
 *   Java:   com.dtwthalion.mpgo.transport.TransportWriter
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_TRANSPORT_WRITER_H
#define MPGO_TRANSPORT_WRITER_H

#import <Foundation/Foundation.h>
#import "MPGOTransportPacket.h"
#import "MPGOAccessUnit.h"

@class MPGOSpectralDataset;
@class MPGOAcquisitionRun;

NS_ASSUME_NONNULL_BEGIN

@interface MPGOTransportWriter : NSObject

/** Whether each packet's payload is followed by a CRC-32C checksum
 *  (sets MPGOTransportPacketFlagHasChecksum). Default NO. */
@property (nonatomic) BOOL useChecksum;

/** Compress each channel's float64 bytes with zlib on the wire,
 *  setting ``MPGOCompressionZlib`` on the ChannelData. The reader
 *  decompresses automatically regardless of this flag. Default NO. */
@property (nonatomic) BOOL useCompression;

- (instancetype)initWithOutputPath:(NSString *)path;
- (instancetype)initWithMutableData:(NSMutableData *)data;

/** Full-dataset convenience. Emits the entire packet sequence. */
- (BOOL)writeDataset:(MPGOSpectralDataset *)dataset
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

- (BOOL)writeAccessUnit:(MPGOAccessUnit *)au
              datasetId:(uint16_t)datasetId
             auSequence:(uint32_t)auSequence
                  error:(NSError * _Nullable *)error;

- (BOOL)writeEndOfDatasetWithDatasetId:(uint16_t)datasetId
                       finalAUSequence:(uint32_t)finalAUSequence
                                  error:(NSError * _Nullable *)error;

- (BOOL)writeEndOfStreamWithError:(NSError * _Nullable *)error;

- (void)close;

@end

NS_ASSUME_NONNULL_END

#endif
