/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_TRANSPORT_CLIENT_H
#define TTIO_TRANSPORT_CLIENT_H

#import <Foundation/Foundation.h>
#import "TTIOTransportReader.h"  // reuses TTIOTransportPacketRecord

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOTransportClient.h</p>
 *
 * <p>WebSocket client that connects to a
 * <code>TTIOTransportServer</code>, sends a JSON query, and collects
 * the resulting transport packets. Built on libwebsockets
 * (<code>libwebsockets-dev</code> package). The client runs a
 * private libwebsockets service loop inside
 * <code>-fetchPacketsWithFilters:timeout:error:</code> and blocks
 * until the server emits EndOfStream or the connection closes.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.transport.client.TransportClient</code><br/>
 * Java:
 * <code>global.thalion.ttio.transport.TransportClient</code></p>
 */
@interface TTIOTransportClient : NSObject

/**
 * Construct a client bound to a transport-server endpoint.
 *
 * The URL is stored verbatim; the WebSocket is opened on each call
 * to -fetchPacketsWithFilters:timeout:error: or -streamToFilePath:...
 *
 * @param url Endpoint URL. Must be a ``ws://`` scheme (``wss://``
 *            is not yet supported by this client).
 * @return Initialised client instance.
 */
- (instancetype)initWithURL:(NSString *)url;

/**
 * Connect, send a filtered query, and collect every packet through EndOfStream.
 *
 * Opens a fresh WebSocket to the configured URL, sends a JSON query
 * frame built from ``filters``, and drains the binary packet stream
 * into an array of TTIOTransportPacketRecord values. The call
 * blocks until the server emits ``EndOfStream`` or the connection
 * closes.
 *
 * @param filters         Optional filter dictionary with string
 *                        keys and ``NSNumber`` / ``NSString`` values
 *                        per ``docs/transport-spec.md`` §7. Pass
 *                        ``nil`` or an empty dictionary for the
 *                        full stream.
 * @param timeoutSeconds  Connect / receive timeout. ``<= 0`` means
 *                        no timeout (block indefinitely).
 * @param error           On failure, populated with an ``NSError``
 *                        describing the cause. May be ``NULL``.
 *
 * @return Ordered packet array on success, or ``nil`` on connect
 *         failure or protocol violation (and ``*error`` is set if
 *         non-NULL).
 */
- (nullable NSArray<TTIOTransportPacketRecord *> *)
    fetchPacketsWithFilters:(nullable NSDictionary<NSString *, id> *)filters
                    timeout:(NSTimeInterval)timeoutSeconds
                      error:(NSError * _Nullable *)error;

/**
 * Streams a filtered dataset into a new <code>.tio</code> file.
 * Scope: HDF5 provider; FLOAT64 / Compression.NONE wire encoding
 * (same as the offline codec).
 *
 * @param outputPath Destination <code>.tio</code> path.
 * @param filters    Filter dictionary; pass <code>nil</code> for a
 *                   full stream.
 * @param error      Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)streamToFilePath:(NSString *)outputPath
                  filters:(nullable NSDictionary<NSString *, id> *)filters
                    error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
