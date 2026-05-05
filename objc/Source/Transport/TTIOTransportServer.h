/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#ifndef TTIO_TRANSPORT_SERVER_H
#define TTIO_TRANSPORT_SERVER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSObject (NSObject)</p>
 * <p><em>Declared In:</em> Transport/TTIOTransportServer.h</p>
 *
 * <p>WebSocket transport server built on libwebsockets. Serves a
 * <code>TTIOSpectralDataset</code> to connecting clients with full
 * server-side filtering (ms_level, RT range, precursor m/z range,
 * polarity, dataset_id, max_au cap). Wire protocol identical to
 * Python <code>ttio.transport.server.TransportServer</code> and Java
 * <code>global.thalion.ttio.transport.TransportServer</code>.</p>
 *
 * <p><strong>API status:</strong> Provisional.</p>
 */
@interface TTIOTransportServer : NSObject

/**
 * Creates a server bound to <code>host:port</code>.
 *
 * @param datasetPath Path to the .tio file to serve.
 * @param host        Bind address.
 * @param port        TCP port; <code>0</code> picks a free
 *                    ephemeral port (query
 *                    <code>actualPort</code> after
 *                    <code>-startAndReturnError:</code>).
 * @return An initialised but not yet started server.
 */
- (instancetype)initWithDatasetPath:(NSString *)datasetPath
                                 host:(NSString *)host
                                 port:(uint16_t)port;

/**
 * Starts the server's event loop on a background thread. Returns
 * only after the listen socket is bound.
 *
 * @param error Out-parameter populated on failure.
 * @return <code>YES</code> on success, <code>NO</code> on failure.
 */
- (BOOL)startAndReturnError:(NSError * _Nullable *)error;

/**
 * Signals the event loop to exit.
 *
 * @param timeoutSeconds Maximum time to wait for the thread to
 *                       join.
 */
- (void)stopWithTimeout:(NSTimeInterval)timeoutSeconds;

/** Actual port the server is listening on (useful when
 *  <code>port == 0</code> was passed to the initialiser). */
@property (nonatomic, readonly) uint16_t actualPort;

@end

NS_ASSUME_NONNULL_END

#endif
