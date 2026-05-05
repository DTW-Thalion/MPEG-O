/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_TRANSPORT_READER_H
#define TTIO_TRANSPORT_READER_H

#import <Foundation/Foundation.h>
#import "TTIOTransportPacket.h"
#import "TTIOAccessUnit.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * <heading>TTIOTransportPacketRecord</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOTransportReader.h</p>
 *
 * <p>One parsed packet as a header + payload pair.</p>
 */
@interface TTIOTransportPacketRecord : NSObject
@property (nonatomic, readonly, strong) TTIOTransportPacketHeader *header;
@property (nonatomic, readonly, strong) NSData *payload;
- (instancetype)initWithHeader:(TTIOTransportPacketHeader *)h payload:(NSData *)p;
@end


/**
 * <heading>TTIOTransportReader</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOTransportReader.h</p>
 *
 * <p>Parses a transport byte stream into packet (header, payload)
 * pairs or materialises the stream into a new <code>.tio</code>
 * file.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.transport.codec.TransportReader</code><br/>
 * Java:
 * <code>global.thalion.ttio.transport.TransportReader</code></p>
 */
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
 * Scope: HDF5 provider; float64 + NONE compression; mass spectra.
 */
- (BOOL)writeTtioToPath:(NSString *)outputPath error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
