/*
 * TTIOTransportServer — v0.10 M68.5 parity backfill.
 *
 * WebSocket transport server built on libwebsockets. Serves an
 * TTIOSpectralDataset to connecting clients with full server-side
 * filtering (ms_level, rt range, precursor m/z range, polarity,
 * dataset_id, max_au cap). Wire protocol identical to Python
 * ttio.transport.server.TransportServer and Java
 * com.dtwthalion.tio.transport.TransportServer.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_TRANSPORT_SERVER_H
#define TTIO_TRANSPORT_SERVER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TTIOTransportServer : NSObject

/** Create a server bound to ``host:port``. ``port == 0`` picks a
 *  free ephemeral port; query ``actualPort`` after -start. */
- (instancetype)initWithDatasetPath:(NSString *)datasetPath
                                 host:(NSString *)host
                                 port:(uint16_t)port;

/** Start the server's event loop on a background thread. Returns
 *  only after the listen socket is bound. */
- (BOOL)startAndReturnError:(NSError * _Nullable *)error;

/** Signal the event loop to exit. Blocks until the thread joins
 *  or ``timeoutSeconds`` elapses. */
- (void)stopWithTimeout:(NSTimeInterval)timeoutSeconds;

/** Actual port the server is listening on (useful when port=0). */
@property (nonatomic, readonly) uint16_t actualPort;

@end

NS_ASSUME_NONNULL_END

#endif
