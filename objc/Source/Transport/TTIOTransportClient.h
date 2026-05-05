/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_TRANSPORT_CLIENT_H
#define TTIO_TRANSPORT_CLIENT_H

#import <Foundation/Foundation.h>
#import "TTIOTransportReader.h"  // reuses TTIOTransportPacketRecord

NS_ASSUME_NONNULL_BEGIN

/**
 * <heading>TTIOTransportClient</heading>
 *
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

/** ``url`` must be a ``ws://`` URL (``wss://`` is not yet supported). */
- (instancetype)initWithURL:(NSString *)url;

/**
 * Connect, send the JSON query built from ``filters``, and collect
 * every packet through EndOfStream. Returns the packet list, or nil
 * on connect failure / protocol violation.
 *
 * ``filters`` is an NSDictionary with string keys and NSNumber /
 * NSString values matching ``docs/transport-spec.md`` §7. Pass nil
 * or an empty dictionary for a full stream.
 *
 * ``timeoutSeconds <= 0`` means no timeout.
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
