/* SPDX-License-Identifier: Apache-2.0 */
#import "Core/TTIOThreads.h"
#include <pthread.h>
#include <stdlib.h>
#if __has_include("ttio_rans.h")
#  include "ttio_rans.h"
#  define TTIO_THREADS_HAVE_RANS 1
#endif

@implementation TTIOThreads

+ (unsigned long long)resolveMemoryBudget:(NSNumber *)explicitBytes
                                  threads:(NSUInteger)threads
                               blockBytes:(unsigned long long)blockBytes
{
    if (explicitBytes != nil && [explicitBytes unsignedLongLongValue] > 0) {
        return [explicitBytes unsignedLongLongValue];
    }
    const char *env = getenv("TTIO_MEMORY_BUDGET");
    if (env && env[0]) {
        unsigned long long v = strtoull(env, NULL, 10);
        if (v > 0) return v;
    }
    /* Target full-thread admittance: a block in flight costs about
     * eight times blockBytes (raw sequence + qualities, times four for
     * codec workspace), the writer takes half the budget, so sixteen
     * blockBytes per thread admits ~threads blocks. Clamped to half
     * the physical memory so the target never outruns the box. */
    unsigned long long computed = (unsigned long long)threads * blockBytes * 16ull;
    unsigned long long ramHalf =
        (unsigned long long)[[NSProcessInfo processInfo] physicalMemory] / 2ull;
    if (ramHalf > 0 && computed > ramHalf) computed = ramHalf;
    unsigned long long floor1g = 1ull << 30;
    return computed > floor1g ? computed : floor1g;
}

+ (NSUInteger)resolveV6SegmentThreads:(NSUInteger)poolWorkers
{
    NSUInteger cores = (NSUInteger)[[NSProcessInfo processInfo] activeProcessorCount];
    NSUInteger workers = poolWorkers < 1 ? 1 : poolWorkers;
    NSUInteger n = cores / workers;
    if (n < 2) n = 2;
    if (n > 8) n = 8;
    return n;
}

+ (NSUInteger)resolve:(NSNumber *)explicitCount
{
    if (explicitCount && explicitCount.integerValue > 0) {
        return (NSUInteger)explicitCount.integerValue;
    }
    const char *raw = getenv("TTIO_THREADS");
    long n = 0;
    if (raw && *raw) {
        char *end = NULL;
        n = strtol(raw, &end, 10);
        if (end == raw || (end && *end && *end != ' ')) return 1;
    }
    if (n <= 0) {
        /* Two cores held back rather than eight: measured throughput
         * kept climbing to roughly one writer per core, and the wider
         * margin left a quarter of it unused. The floor keeps a
         * two-core machine from resolving to zero. */
        long cores = (long)[[NSProcessInfo processInfo] activeProcessorCount];
        n = cores - 2 > 1 ? cores - 2 : 1;
    }
    return (NSUInteger)n;
}

@end

static pthread_mutex_t g_poolLock = PTHREAD_MUTEX_INITIALIZER;
static int g_poolDepth = 0;
static int g_savedAutotune = 3;
static int g_savedV6 = 0;

@implementation TTIOThreadPool {
    NSOperationQueue *_queue;
    NSUInteger _threads;
    BOOL _closed;
}

+ (instancetype)poolWithThreads:(NSUInteger)threads
{
    TTIOThreadPool *p = [self new];
    p->_threads = threads < 1 ? 1 : threads;
    if (p->_threads > 1) {
        p->_queue = [NSOperationQueue new];
        p->_queue.maxConcurrentOperationCount = (NSInteger)p->_threads;
        p->_queue.name = @"ttio-block";
        pthread_mutex_lock(&g_poolLock);
        if (g_poolDepth++ == 0) {
#ifdef TTIO_THREADS_HAVE_RANS
            g_savedAutotune = ttio_m94z_get_autotune_threads();
            ttio_m94z_set_autotune_threads(1);
            g_savedV6 = ttio_m94z_get_v6_threads();
            ttio_m94z_set_v6_threads(
                (int)[TTIOThreads resolveV6SegmentThreads:p->_threads]);
#endif
        }
        pthread_mutex_unlock(&g_poolLock);
    }
    return p;
}

- (NSOperationQueue *)queue { return _queue; }
- (NSUInteger)threads { return _threads; }

- (void)close
{
    if (_closed || !_queue) { _closed = YES; return; }
    _closed = YES;
    [_queue waitUntilAllOperationsAreFinished];
    pthread_mutex_lock(&g_poolLock);
    if (--g_poolDepth == 0) {
#ifdef TTIO_THREADS_HAVE_RANS
        ttio_m94z_set_autotune_threads(g_savedAutotune);
        ttio_m94z_set_v6_threads(g_savedV6);
#endif
    }
    pthread_mutex_unlock(&g_poolLock);
}

- (void)dealloc { [self close]; }

@end
