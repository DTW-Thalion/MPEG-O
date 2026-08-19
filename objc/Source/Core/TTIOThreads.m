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
    unsigned long long computed = (unsigned long long)threads * blockBytes * 4ull;
    unsigned long long floor1g = 1ull << 30;
    return computed > floor1g ? computed : floor1g;
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
        long cores = (long)[[NSProcessInfo processInfo] activeProcessorCount];
        n = cores - 8 > 1 ? cores - 8 : 1;
    }
    return (NSUInteger)n;
}

@end

static pthread_mutex_t g_poolLock = PTHREAD_MUTEX_INITIALIZER;
static int g_poolDepth = 0;
static int g_savedAutotune = 3;

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
#endif
    }
    pthread_mutex_unlock(&g_poolLock);
}

- (void)dealloc { [self close]; }

@end
