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
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOTransportReader.h</p>
 *
 * <p>One parsed packet as a header + payload pair.</p>
 */
@interface TTIOTransportPacketRecord : NSObject
/** Decoded packet header. */
@property (nonatomic, readonly, strong) TTIOTransportPacketHeader *header;

/** Packet payload bytes (size matches ``header.payloadLength``). */
@property (nonatomic, readonly, strong) NSData *payload;

/**
 * Construct a packet record from a header + payload pair.
 *
 * @param h Decoded packet header.
 * @param p Payload bytes; size must equal ``h.payloadLength``.
 * @return Initialised record instance.
 */
- (instancetype)initWithHeader:(TTIOTransportPacketHeader *)h payload:(NSData *)p;
@end


/**
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

/**
 * Initialise a reader sourcing from a ``.tis`` file on disk.
 *
 * The file is opened lazily on the first read and closed when the
 * reader deallocates.
 *
 * @param path Filesystem path of the ``.tis`` file.
 * @return Initialised reader instance.
 */
- (instancetype)initWithInputPath:(NSString *)path;

/**
 * Initialise a reader sourcing from an in-memory byte buffer.
 *
 * The buffer is borrowed; the reader never mutates it. Useful for
 * round-tripping bytes produced by ``-[TTIOTransportWriter
 * initWithMutableData:]``.
 *
 * @param data The full transport-stream byte buffer.
 * @return Initialised reader instance.
 */
- (instancetype)initWithData:(NSData *)data;

/**
 * Read every packet in the stream into an array of records.
 *
 * Returns all packets through (and including) ``END_OF_STREAM``.
 * Unknown packet types are kept in the returned list for
 * forward-compat per transport-spec §6. CRC-32C trailers are
 * verified when ``HAS_CHECKSUM`` is set on the header.
 *
 * @param error On failure, populated with an ``NSError`` in
 *              ``TTIOTransportErrorDomain``. May be ``NULL``.
 *
 * @return Ordered packet array on success, or ``nil`` on CRC-32C
 *         mismatch / structural violation / truncated stream (and
 *         ``*error`` is set if non-NULL).
 */
- (nullable NSArray<TTIOTransportPacketRecord *> *)
    readAllPacketsWithError:(NSError * _Nullable *)error;

/**
 * Materialise the transport stream into a ``.tio`` file.
 *
 * Drains every packet, accumulates per-dataset state, and writes
 * the result via the HDF5 provider. Scope: HDF5 provider; float64
 * + ``NONE``/``ZLIB`` compression; the spectral, genomic, image,
 * reference, identifications, quantifications, subjects, samples
 * and provenance payloads documented in
 * ``docs/transport-spec.md`` are all supported.
 *
 * @param outputPath Destination ``.tio`` path. Created if absent;
 *                   truncated if present.
 * @param error      On failure, populated with an ``NSError``.
 *                   May be ``NULL``.
 *
 * @return ``YES`` on success, ``NO`` on failure (and ``*error`` is
 *         set if non-NULL).
 */
- (BOOL)writeTtioToPath:(NSString *)outputPath error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
