/*
 * MpgoTransportServer — v0.10 M68.5 ObjC transport server CLI.
 *
 * Parallel to Python ``python -m mpeg_o.tools.transport_server_cli``
 * and Java ``com.dtwthalion.mpgo.tools.TransportServerCli``.
 *
 * Usage: MpgoTransportServer <path.mpgo> [--host 127.0.0.1] [--port 0]
 *
 * Prints ``PORT=<n>`` to stdout once bound so supervising
 * processes can discover the listen port. Runs until SIGTERM.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Transport/MPGOTransportServer.h"
#include <stdio.h>
#include <signal.h>

static volatile sig_atomic_t g_shouldStop = 0;
static void handleSig(int sig) { (void)sig; g_shouldStop = 1; }

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: MpgoTransportServer <path.mpgo> "
                            "[--host 127.0.0.1] [--port 0]\n");
            return 2;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSString *host = @"127.0.0.1";
        uint16_t port = 0;
        for (int i = 2; i + 1 < argc; i += 2) {
            if (strcmp(argv[i], "--host") == 0) host = [NSString stringWithUTF8String:argv[i + 1]];
            else if (strcmp(argv[i], "--port") == 0) port = (uint16_t)atoi(argv[i + 1]);
        }

        MPGOTransportServer *srv =
            [[MPGOTransportServer alloc] initWithDatasetPath:path host:host port:port];
        NSError *err = nil;
        if (![srv startAndReturnError:&err]) {
            fprintf(stderr, "server start failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
        printf("PORT=%u\n", (unsigned)srv.actualPort);
        fflush(stdout);

        signal(SIGTERM, handleSig);
        signal(SIGINT, handleSig);
        while (!g_shouldStop) {
            [NSThread sleepForTimeInterval:0.1];
        }
        [srv stopWithTimeout:2.0];
    }
    return 0;
}
