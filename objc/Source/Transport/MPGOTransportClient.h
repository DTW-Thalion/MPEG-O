/*
 * MPGOTransportClient — v0.10 M68.
 *
 * WebSocket client that connects to a TransportServer (see the Python
 * reference implementation at ``mpeg_o.transport.server``), sends a
 * JSON query, and collects the resulting transport packets.
 *
 * Built on libwebsockets (libwebsockets-dev package). The client runs
 * a private libwebsockets service loop inside -fetchPacketsWithFilters:
 * and blocks until the server emits EndOfStream or the connection
 * closes.
 *
 * Cross-language equivalents:
 *   Python: mpeg_o.transport.client.TransportClient
 *   Java:   com.dtwthalion.mpgo.transport.TransportClient
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef MPGO_TRANSPORT_CLIENT_H
#define MPGO_TRANSPORT_CLIENT_H

#import <Foundation/Foundation.h>
#import "MPGOTransportReader.h"  // reuses MPGOTransportPacketRecord

NS_ASSUME_NONNULL_BEGIN

@interface MPGOTransportClient : NSObject

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
- (nullable NSArray<MPGOTransportPacketRecord *> *)
    fetchPacketsWithFilters:(nullable NSDictionary<NSString *, id> *)filters
                    timeout:(NSTimeInterval)timeoutSeconds
                      error:(NSError * _Nullable *)error;

/**
 * Stream a filtered dataset into a new ``.mpgo`` file. Returns YES on
 * success. M68 scope: HDF5 provider; FLOAT64 / Compression.NONE wire
 * encoding (same as the offline codec).
 */
- (BOOL)streamToFilePath:(NSString *)outputPath
                  filters:(nullable NSDictionary<NSString *, id> *)filters
                    error:(NSError * _Nullable *)error;

@end

NS_ASSUME_NONNULL_END

#endif
