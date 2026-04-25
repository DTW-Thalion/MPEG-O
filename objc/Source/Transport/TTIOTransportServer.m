/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#define _GNU_SOURCE 1

#import "TTIOTransportServer.h"
#import "TTIOTransportPacket.h"
#import "TTIOAccessUnit.h"
#import "TTIOTransportWriter.h"
#import "TTIOAUFilter.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOInstrumentConfig.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Spectra/TTIOSpectrum.h"
#import "Spectra/TTIOMassSpectrum.h"
#import "Core/TTIOSignalArray.h"
#import "ValueClasses/TTIOEnums.h"

#include <libwebsockets.h>
#include <string.h>
#include <pthread.h>

// Per-connection state: a queue of NSData frames to deliver, one
// per WRITEABLE callback. Held via opaque_user_data as
// __bridge_retained until CLOSED fires.
@interface TTIOServerSession : NSObject
@property (nonatomic, strong) NSMutableArray<NSData *> *queue;
@property (nonatomic, weak) TTIOTransportServer *server;  // back-pointer for dataset access
@end
@implementation TTIOServerSession
- (instancetype)init {
    if ((self = [super init])) { _queue = [NSMutableArray array]; }
    return self;
}
@end


@interface TTIOTransportServer ()
- (TTIOSpectralDataset *)_openDataset:(NSError **)error;
- (uint16_t)_wireFromPolarity:(TTIOPolarity)p;
- (uint8_t)_wireFromSpectrumClass:(NSString *)name;
@end


// ---------------------------------------------------------------- LE helpers

static inline void appendU16LE(NSMutableData *buf, uint16_t v) {
    uint8_t b[2] = {(uint8_t)(v & 0xFFu), (uint8_t)((v >> 8) & 0xFFu)};
    [buf appendBytes:b length:2];
}
static inline void appendU32LE(NSMutableData *buf, uint32_t v) {
    uint8_t b[4];
    b[0] = (uint8_t)(v & 0xFFu);
    b[1] = (uint8_t)((v >> 8) & 0xFFu);
    b[2] = (uint8_t)((v >> 16) & 0xFFu);
    b[3] = (uint8_t)((v >> 24) & 0xFFu);
    [buf appendBytes:b length:4];
}
static void appendLEString(NSMutableData *buf, NSString *s, int width) {
    NSData *d = [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (width == 2) appendU16LE(buf, (uint16_t)d.length);
    else            appendU32LE(buf, (uint32_t)d.length);
    [buf appendData:d];
}

static uint64_t nowNs(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static NSData *frameForPacket(TTIOTransportPacketType type,
                                uint16_t datasetId,
                                uint32_t auSequence,
                                NSData *payload)
{
    TTIOTransportPacketHeader *hdr =
        [[TTIOTransportPacketHeader alloc] initWithPacketType:type
                                                          flags:0
                                                      datasetId:datasetId
                                                     auSequence:auSequence
                                                  payloadLength:(uint32_t)payload.length
                                                    timestampNs:nowNs()];
    NSMutableData *out = [NSMutableData dataWithCapacity:24 + payload.length];
    [out appendData:[hdr encode]];
    [out appendData:payload];
    return out;
}

static NSString *instrumentJSON(TTIOInstrumentConfig *cfg)
{
    if (!cfg) return @"{}";
    NSDictionary *d = @{
        @"analyzer_type": cfg.analyzerType ?: @"",
        @"detector_type": cfg.detectorType ?: @"",
        @"manufacturer": cfg.manufacturer ?: @"",
        @"model": cfg.model ?: @"",
        @"serial_number": cfg.serialNumber ?: @"",
        @"source_type": cfg.sourceType ?: @"",
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:d
                                                     options:NSJSONWritingSortedKeys
                                                       error:nil];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

// ---------------------------------------------------------------- build stream

static void buildStreamFrames(TTIOTransportServer *server,
                                TTIOAUFilter *filter,
                                NSMutableArray<NSData *> *outFrames)
{
    NSError *err = nil;
    TTIOSpectralDataset *dataset = [server _openDataset:&err];
    if (!dataset) return;

    NSArray<NSString *> *runNames = [dataset.msRuns.allKeys
                                      sortedArrayUsingSelector:@selector(compare:)];

    // StreamHeader
    {
        NSMutableData *p = [NSMutableData data];
        appendLEString(p, @"1.2", 2);
        appendLEString(p, dataset.title ?: @"", 2);
        appendLEString(p, dataset.isaInvestigationId ?: @"", 2);
        appendU16LE(p, 0);  // no features
        appendU16LE(p, (uint16_t)runNames.count);
        [outFrames addObject:frameForPacket(TTIOTransportPacketStreamHeader, 0, 0, p)];
    }

    // DatasetHeaders
    uint16_t did = 1;
    for (NSString *name in runNames) {
        if (filter.datasetId && did != filter.datasetId.unsignedIntValue) {
            did++; continue;
        }
        TTIOAcquisitionRun *run = dataset.msRuns[name];
        NSArray<NSString *> *channelNames =
            [run valueForKey:@"channelNames"] ?: @[@"mz", @"intensity"];
        NSMutableData *p = [NSMutableData data];
        appendU16LE(p, did);
        appendLEString(p, name, 2);
        uint8_t acqMode = (uint8_t)run.acquisitionMode;
        [p appendBytes:&acqMode length:1];
        appendLEString(p, run.spectrumClassName ?: @"TTIOMassSpectrum", 2);
        uint8_t nch = (uint8_t)channelNames.count;
        [p appendBytes:&nch length:1];
        for (NSString *c in channelNames) appendLEString(p, c, 2);
        appendLEString(p, instrumentJSON(run.instrumentConfig), 4);
        appendU32LE(p, (uint32_t)[run count]);
        [outFrames addObject:frameForPacket(TTIOTransportPacketDatasetHeader, did, 0, p)];
        did++;
    }

    // AccessUnits
    uint32_t emitted = 0;
    uint32_t maxAu = filter.maxAU ? filter.maxAU.unsignedIntValue : UINT32_MAX;
    did = 1;
    for (NSString *name in runNames) {
        if (filter.datasetId && did != filter.datasetId.unsignedIntValue) {
            did++; continue;
        }
        TTIOAcquisitionRun *run = dataset.msRuns[name];
        NSArray<NSString *> *channelNames =
            [run valueForKey:@"channelNames"] ?: @[@"mz", @"intensity"];
        NSUInteger count = [run count];
        for (NSUInteger i = 0; i < count; i++) {
            if (emitted >= maxAu) goto done;
            TTIOSpectrum *sp = [run objectAtIndex:i];
            uint8_t wireClass = [server _wireFromSpectrumClass:run.spectrumClassName];
            uint8_t msLevel = 0;
            uint8_t polarityWire = 2;
            if ([sp isKindOfClass:[TTIOMassSpectrum class]]) {
                TTIOMassSpectrum *ms = (TTIOMassSpectrum *)sp;
                msLevel = (uint8_t)MIN((NSUInteger)255, ms.msLevel);
                polarityWire = (uint8_t)[server _wireFromPolarity:ms.polarity];
            }
            double bpi = 0.0;
            if (run.spectrumIndex && sp.indexPosition < run.spectrumIndex.count) {
                bpi = [run.spectrumIndex basePeakIntensityAt:sp.indexPosition];
            }
            NSMutableArray *chs = [NSMutableArray array];
            for (NSString *cname in channelNames) {
                TTIOSignalArray *sa = sp.signalArrays[cname];
                if (!sa) continue;
                TTIOTransportChannelData *ch =
                    [[TTIOTransportChannelData alloc]
                        initWithName:cname
                           precision:TTIOPrecisionFloat64
                         compression:TTIOCompressionNone
                           nElements:(uint32_t)(sa.buffer.length / 8)
                                data:sa.buffer];
                [chs addObject:ch];
            }
            TTIOAccessUnit *au =
                [[TTIOAccessUnit alloc]
                    initWithSpectrumClass:wireClass
                           acquisitionMode:(uint8_t)run.acquisitionMode
                                   msLevel:msLevel
                                  polarity:polarityWire
                             retentionTime:sp.scanTimeSeconds
                               precursorMz:sp.precursorMz
                           precursorCharge:(uint8_t)MIN((NSUInteger)255, sp.precursorCharge)
                               ionMobility:0.0
                         basePeakIntensity:bpi
                                  channels:chs
                                    pixelX:0 pixelY:0 pixelZ:0];
            if (![filter matches:au datasetId:did]) continue;
            [outFrames addObject:frameForPacket(
                TTIOTransportPacketAccessUnit, did, (uint32_t)i, [au encode])];
            emitted++;
        }
        did++;
    }
done:

    // EndOfDataset per dataset
    did = 1;
    for (NSString *name in runNames) {
        if (filter.datasetId && did != filter.datasetId.unsignedIntValue) {
            did++; continue;
        }
        TTIOAcquisitionRun *run = dataset.msRuns[name];
        NSMutableData *p = [NSMutableData data];
        appendU16LE(p, did);
        appendU32LE(p, (uint32_t)[run count]);
        [outFrames addObject:frameForPacket(TTIOTransportPacketEndOfDataset, did, 0, p)];
        did++;
    }

    // EndOfStream
    [outFrames addObject:frameForPacket(TTIOTransportPacketEndOfStream, 0, 0, [NSData data])];
}


// ---------------------------------------------------------------- callback

static int serverCallback(struct lws *wsi,
                            enum lws_callback_reasons reason,
                            void *user, void *in, size_t len)
{
    (void)user;

    switch (reason) {
        case LWS_CALLBACK_ESTABLISHED: {
            struct lws_context *ctx = lws_get_context(wsi);
            TTIOTransportServer *server =
                (__bridge TTIOTransportServer *)lws_context_user(ctx);
            TTIOServerSession *session = [[TTIOServerSession alloc] init];
            session.server = server;
            lws_set_opaque_user_data(wsi, (__bridge_retained void *)session);
            break;
        }
        case LWS_CALLBACK_RECEIVE: {
            void *opaque = lws_get_opaque_user_data(wsi);
            if (!opaque) return 0;
            TTIOServerSession *session = (__bridge TTIOServerSession *)opaque;
            NSString *text = [[NSString alloc]
                initWithBytes:in length:len encoding:NSUTF8StringEncoding];
            TTIOAUFilter *filter = [TTIOAUFilter filterFromQueryJSON:(text ?: @"")];
            buildStreamFrames(session.server, filter, session.queue);
            lws_callback_on_writable(wsi);
            break;
        }
        case LWS_CALLBACK_SERVER_WRITEABLE: {
            void *opaque = lws_get_opaque_user_data(wsi);
            if (!opaque) return 0;
            TTIOServerSession *session = (__bridge TTIOServerSession *)opaque;
            if (session.queue.count == 0) return 0;
            NSData *frame = session.queue.firstObject;
            [session.queue removeObjectAtIndex:0];
            unsigned char *buf = calloc(LWS_PRE + frame.length, 1);
            memcpy(buf + LWS_PRE, frame.bytes, frame.length);
            int wrote = lws_write(wsi, buf + LWS_PRE, frame.length, LWS_WRITE_BINARY);
            free(buf);
            if (wrote < 0) return -1;
            if (session.queue.count > 0) {
                lws_callback_on_writable(wsi);
            } else {
                // Close the connection once the stream is fully drained.
                lws_close_reason(wsi, LWS_CLOSE_STATUS_NORMAL,
                                   (unsigned char *)"done", 4);
                return -1;
            }
            break;
        }
        case LWS_CALLBACK_CLOSED: {
            void *opaque = lws_get_opaque_user_data(wsi);
            if (opaque) {
                TTIOServerSession *session =
                    (__bridge_transfer TTIOServerSession *)opaque;
                lws_set_opaque_user_data(wsi, NULL);
                (void)session;  // releases via ARC
            }
            break;
        }
        default:
            break;
    }
    return 0;
}


static const struct lws_protocols serverProtocols[] = {
    {
        "ttio-transport",
        serverCallback,
        0,
        1024 * 1024,
        0, NULL, 0
    },
    LWS_PROTOCOL_LIST_TERM
};


// ---------------------------------------------------------------- server impl

@implementation TTIOTransportServer
{
    NSString *_datasetPath;
    NSString *_host;
    uint16_t _port;
    uint16_t _actualPort;
    struct lws_context *_context;
    pthread_t _thread;
    volatile BOOL _running;
    volatile BOOL _started;
}

- (instancetype)initWithDatasetPath:(NSString *)datasetPath
                                 host:(NSString *)host
                                 port:(uint16_t)port
{
    if ((self = [super init])) {
        _datasetPath = [datasetPath copy];
        _host = [host copy];
        _port = port;
    }
    return self;
}

- (uint16_t)actualPort { return _actualPort; }

- (TTIOSpectralDataset *)_openDataset:(NSError **)error
{
    return [TTIOSpectralDataset readFromFilePath:_datasetPath error:error];
}

- (uint8_t)_wireFromSpectrumClass:(NSString *)name
{
    if ([name isEqualToString:@"TTIOMassSpectrum"]) return 0;
    if ([name isEqualToString:@"TTIONMRSpectrum"]) return 1;
    if ([name isEqualToString:@"TTIONMR2DSpectrum"]) return 2;
    if ([name isEqualToString:@"TTIOFreeInductionDecay"]) return 3;
    if ([name isEqualToString:@"TTIOMSImagePixel"]) return 4;
    return 0;
}

- (uint16_t)_wireFromPolarity:(TTIOPolarity)p
{
    switch (p) {
        case TTIOPolarityPositive: return 0;
        case TTIOPolarityNegative: return 1;
        case TTIOPolarityUnknown:  default: return 2;
    }
}

static void *serverThreadMain(void *arg)
{
    TTIOTransportServer *self = (__bridge TTIOTransportServer *)arg;
    while (self->_running) {
        lws_service(self->_context, 50);
    }
    return NULL;
}

- (BOOL)startAndReturnError:(NSError **)error
{
    lws_set_log_level(LLL_ERR, NULL);
    struct lws_context_creation_info info;
    memset(&info, 0, sizeof(info));
    info.port = _port;
    info.iface = [_host UTF8String];
    info.protocols = serverProtocols;
    info.gid = -1;
    info.uid = -1;
    info.user = (__bridge void *)self;
    info.options = LWS_SERVER_OPTION_DO_SSL_GLOBAL_INIT;

    _context = lws_create_context(&info);
    if (!_context) {
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"lws_create_context failed"}];
        return NO;
    }

    // Discover the port via the default vhost.
    struct lws_vhost *vhost = lws_get_vhost_by_name(_context, "default");
    if (vhost) {
        _actualPort = (uint16_t)lws_get_vhost_listen_port(vhost);
    }

    _running = YES;
    if (pthread_create(&_thread, NULL, serverThreadMain, (__bridge void *)self) != 0) {
        lws_context_destroy(_context);
        _context = NULL;
        if (error) *error = [NSError errorWithDomain:TTIOTransportErrorDomain
                                                 code:TTIOTransportErrorUnexpectedPayload
                                             userInfo:@{NSLocalizedDescriptionKey:
                             @"pthread_create failed"}];
        return NO;
    }
    return YES;
}

- (void)stopWithTimeout:(NSTimeInterval)timeoutSeconds
{
    _running = NO;
    if (_thread) {
        // Cancel any blocked lws_service by sending a self-interrupt.
        if (_context) lws_cancel_service(_context);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
        while ([deadline timeIntervalSinceNow] > 0) {
            if (pthread_tryjoin_np(_thread, NULL) == 0) { _thread = 0; break; }
            [NSThread sleepForTimeInterval:0.01];
        }
    }
    if (_context) {
        lws_context_destroy(_context);
        _context = NULL;
    }
}

- (void)dealloc
{
    if (_running) [self stopWithTimeout:1.0];
}

@end
