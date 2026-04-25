/*
 * TTIOTransportClient — v0.10 M68.
 *
 * WebSocket client that connects to a TransportServer (see the Python
 * reference implementation at ``ttio.transport.server``), sends a
 * JSON query, and collects the resulting transport packets.
 *
 * Built on libwebsockets (libwebsockets-dev package). The client runs
 * a private libwebsockets service loop inside -fetchPacketsWithFilters:
 * and blocks until the server emits EndOfStream or the connection
 * closes.
 *
 * Cross-language equivalents:
 *   Python: ttio.transport.client.TransportClient
 *   Java:   com.dtwthalion.tio.transport.TransportClient
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_TRANSPORT_CLIENT_H
#define TTIO_TRANSPORT_CLIENT_H

#import <Foundation/Foundation.h>
#import "TTIOTransportReader.h"  // reuses TTIOTransportPacketRecord

NS_ASSUME_NONNULL_BEGIN

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
 * Stream a filtered dataset into a new ``.tio`` file. Returns YES on
 * success. M68 scope: HDF5 provider; FLOAT64 / Compression.NONE wire
 * encoding (same as the offline codec).
 */
- (BOOL)streamToFilePath:(NSString *)outputPath
                  filters:(nullable NSDictionary<NSString *, id> *)filters
                    error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
