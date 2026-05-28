/*
 * TTIOTransportIngest.h
 * TTI-O Objective-C Implementation
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Callback-driven incremental transport-stream parser. Sits next to
 * TTIOTransportReader: where the reader assumes you have the whole
 * stream up front and want every packet back at once, the ingest is
 * for callers (e.g. the TTI-O Workbench Server's WebSocket upload
 * session) that feed bytes in chunks as they arrive and want each
 * packet delivered as soon as it's complete.
 *
 * Lifecycle:
 *     TTIOTransportIngest *ingest = [TTIOTransportIngest new];
 *     ingest.delegate = self;
 *     ... when bytes arrive ...
 *     [ingest feedData:chunk error:&err];   // delegate fires per packet
 *     ... on producer EOF ...
 *     [ingest finishWithError:&err];        // raises if trailing partial
 *
 * Cross-language equivalents (planned):
 *   Python: ttio.transport.codec.TransportIngest
 *   Java:   global.thalion.ttio.transport.TransportIngest
 */
#ifndef TTIO_TRANSPORT_INGEST_H
#define TTIO_TRANSPORT_INGEST_H

#import <Foundation/Foundation.h>
#import "TTIOTransportPacket.h"
#import "TTIOTransportReader.h"

NS_ASSUME_NONNULL_BEGIN

@class TTIOTransportIngest;

/**
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOTransportIngest.h</p>
 *
 * <p>Receives packets and lifecycle events from a
 * TTIOTransportIngest as bytes arrive. All callbacks fire on the
 * thread that invoked <code>-feedBytes:length:error:</code>; callers
 * managing their own queues (e.g. the workbench server's libwebsockets
 * worker thread) should keep the work in the callback short.</p>
 */
@protocol TTIOTransportIngestDelegate <NSObject>

/**
 * Fired once per complete packet as it lands in the rolling buffer.
 *
 * The callback runs synchronously on the thread that invoked
 * ``-feedBytes:length:error:``.
 *
 * @param ingest  The ingest delivering the packet.
 * @param record  Parsed packet (header + payload).
 */
- (void)ingest:(TTIOTransportIngest *)ingest
    didReceivePacket:(TTIOTransportPacketRecord *)record;

@optional

/// Fired exactly once after an EndOfStream packet is parsed.
- (void)ingestDidReceiveEndOfStream:(TTIOTransportIngest *)ingest;

/// Fired on any parse error (bad magic, version, truncated header,
/// CRC mismatch, etc.). The ingest moves to a permanently-failed
/// state after this; subsequent -feed calls return NO immediately.
- (void)ingest:(TTIOTransportIngest *)ingest didFailWithError:(NSError *)error;

@end


/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Transport/TTIOTransportIngest.h</p>
 *
 * <p>Incremental transport-stream parser. Maintains a rolling
 * byte buffer and emits TTIOTransportPacketRecord values to its
 * delegate as packets become complete.</p>
 *
 * <p>Validates everything TTIOTransportReader validates — magic,
 * version, header CRC, payload CRC when the HasChecksum flag is set,
 * AU-sequence monotonicity — but does so packet-by-packet instead
 * of in one pass. A failed validation halts the ingest; the rolling
 * buffer is discarded and any subsequent -feed returns NO.</p>
 *
 * <p>Not thread-safe: a single ingest instance must be driven from
 * one thread. The server pattern is one ingest per WS connection,
 * owned by the worker thread that accepted the connection.</p>
 */
@interface TTIOTransportIngest : NSObject

/** Delegate receiving per-packet, end-of-stream, and failure callbacks. Weak; set before feeding bytes. */
@property (nonatomic, weak, nullable) id<TTIOTransportIngestDelegate> delegate;

/// Total packets emitted so far. Useful for resumable-upload
/// progress reporting.
@property (nonatomic, readonly) NSUInteger packetCount;

/// Bytes currently buffered awaiting a complete packet.
@property (nonatomic, readonly) NSUInteger bufferedBytes;

/// `YES` once the ingest has received and emitted an EndOfStream
/// packet, or has been put into the failed state by a parse error.
/// Further -feed calls on a finished ingest return NO.
@property (nonatomic, readonly) BOOL isFinished;

/**
 * Designated initialiser. Returns a ready-to-feed ingest with an
 * empty rolling buffer, no delegate, and ``isFinished == NO``.
 */
- (instancetype)init NS_DESIGNATED_INITIALIZER;

/**
 * Feed a chunk of transport bytes into the rolling buffer.
 *
 * As packets become complete they are delivered to the delegate
 * synchronously on the calling thread. A parse error halts the
 * ingest permanently: subsequent ``-feed*`` calls return ``NO``
 * immediately.
 *
 * @param bytes   Pointer to the chunk to ingest. Borrowed; may be
 *                released as soon as the call returns.
 * @param length  Number of bytes pointed to by ``bytes``.
 * @param error   On the first parse error, populated with an
 *                ``NSError`` in ``TTIOTransportErrorDomain``. May
 *                be ``NULL``. (The delegate's
 *                ``-ingest:didFailWithError:`` is also invoked.)
 *
 * @return ``YES`` when the chunk was fully buffered/dispatched
 *         without error; ``NO`` on parse failure.
 */
- (BOOL)feedBytes:(const void *)bytes
           length:(NSUInteger)length
            error:(NSError * _Nullable *)error;

/**
 * Convenience wrapper around ``-feedBytes:length:error:`` for ``NSData``.
 *
 * @param data   Chunk of transport bytes.
 * @param error  See ``-feedBytes:length:error:``.
 * @return ``YES`` on success, ``NO`` on parse failure.
 */
- (BOOL)feedData:(NSData *)data error:(NSError * _Nullable *)error;

/**
 * Signal end-of-input from the producer side.
 *
 * If the rolling buffer contains a partial packet (header without
 * payload, payload without CRC, etc.) returns ``NO`` with
 * ``TTIOTransportErrorTruncated`` and fires the delegate's
 * ``-ingest:didFailWithError:``. If the last successfully parsed
 * packet was ``END_OF_STREAM`` returns ``YES``.
 *
 * @param error On failure, populated with an ``NSError``. May be ``NULL``.
 * @return ``YES`` when the stream ended cleanly, ``NO`` otherwise.
 */
- (BOOL)finishWithError:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
