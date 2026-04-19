/*
 * MPGOTransportReader — v0.10 M67.
 *
 * Parses a transport byte stream into packet (header, payload) pairs
 * or materializes the stream into a new .mpgo file.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.transport.codec.TransportReader
 *   Java:   com.dtwthalion.mpgo.transport.TransportReader
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_TRANSPORT_READER_H
#define MPGO_TRANSPORT_READER_H

#import <Foundation/Foundation.h>
#import "MPGOTransportPacket.h"
#import "MPGOAccessUnit.h"

NS_ASSUME_NONNULL_BEGIN

/** One parsed packet as a header + payload pair. */
@interface MPGOTransportPacketRecord : NSObject
@property (nonatomic, readonly, strong) MPGOTransportPacketHeader *header;
@property (nonatomic, readonly, strong) NSData *payload;
- (instancetype)initWithHeader:(MPGOTransportPacketHeader *)h payload:(NSData *)p;
@end


@interface MPGOTransportReader : NSObject

/** Initialize from a file path. */
- (instancetype)initWithInputPath:(NSString *)path;

/** Initialize from an in-memory byte buffer. */
- (instancetype)initWithData:(NSData *)data;

/**
 * Low-level: iterate packets. Returns all packets in the stream up
 * to and including MPGOTransportPacketEndOfStream. On CRC-32C
 * mismatch or structural violation returns nil with ``error``
 * populated (MPGOTransportErrorDomain).
 */
- (nullable NSArray<MPGOTransportPacketRecord *> *)
    readAllPacketsWithError:(NSError * _Nullable *)error;

/**
 * Materialize the transport stream into a ``.mpgo`` file at
 * ``outputPath``. Returns YES on success.
 *
 * v0.10 M67 scope: HDF5 provider; float64 + NONE compression; mass
 * spectra only. Full protection / chromatogram / annotation
 * round-trips arrive in M70/M71.
 */
- (BOOL)writeMpgoToPath:(NSString *)outputPath error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
