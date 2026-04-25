/*
 * TTIOTransportReader — v0.10 M67.
 *
 * Parses a transport byte stream into packet (header, payload) pairs
 * or materializes the stream into a new .tio file.
 *
 * Cross-language equivalents:
 *   Python: ttio.transport.codec.TransportReader
 *   Java:   global.thalion.ttio.transport.TransportReader
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_TRANSPORT_READER_H
#define TTIO_TRANSPORT_READER_H

#import <Foundation/Foundation.h>
#import "TTIOTransportPacket.h"
#import "TTIOAccessUnit.h"

NS_ASSUME_NONNULL_BEGIN

/** One parsed packet as a header + payload pair. */
@interface TTIOTransportPacketRecord : NSObject
@property (nonatomic, readonly, strong) TTIOTransportPacketHeader *header;
@property (nonatomic, readonly, strong) NSData *payload;
- (instancetype)initWithHeader:(TTIOTransportPacketHeader *)h payload:(NSData *)p;
@end


@interface TTIOTransportReader : NSObject

/** Initialize from a file path. */
- (instancetype)initWithInputPath:(NSString *)path;

/** Initialize from an in-memory byte buffer. */
- (instancetype)initWithData:(NSData *)data;

/**
 * Low-level: iterate packets. Returns all packets in the stream up
 * to and including TTIOTransportPacketEndOfStream. On CRC-32C
 * mismatch or structural violation returns nil with ``error``
 * populated (TTIOTransportErrorDomain).
 */
- (nullable NSArray<TTIOTransportPacketRecord *> *)
    readAllPacketsWithError:(NSError * _Nullable *)error;

/**
 * Materialize the transport stream into a ``.tio`` file at
 * ``outputPath``. Returns YES on success.
 *
 * v0.10 M67 scope: HDF5 provider; float64 + NONE compression; mass
 * spectra only. Full protection / chromatogram / annotation
 * round-trips arrive in M70/M71.
 */
- (BOOL)writeTtioToPath:(NSString *)outputPath error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
