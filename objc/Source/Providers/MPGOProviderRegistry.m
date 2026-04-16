#import "MPGOProviderRegistry.h"
#import "HDF5/MPGOHDF5Errors.h"

@implementation MPGOProviderRegistry {
    NSMutableDictionary<NSString *, Class> *_providers;
}

+ (instancetype)sharedRegistry
{
    static MPGOProviderRegistry *inst = nil;
    @synchronized (self) {
        if (!inst) inst = [[MPGOProviderRegistry alloc] init];
    }
    return inst;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _providers = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)registerProviderClass:(Class)providerClass forName:(NSString *)name
{
    @synchronized (_providers) { _providers[name] = providerClass; }
}

- (NSArray<NSString *> *)knownProviderNames
{
    @synchronized (_providers) { return _providers.allKeys; }
}

- (id<MPGOStorageProvider>)openURL:(NSString *)url
                               mode:(MPGOStorageOpenMode)mode
                           provider:(NSString *)providerName
                              error:(NSError **)error
{
    Class cls = nil;
    @synchronized (_providers) {
        if (providerName) {
            cls = _providers[providerName];
            if (!cls) {
                if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
                        @"unknown provider '%@'. Known: %@",
                        providerName, _providers.allKeys);
                return nil;
            }
        } else {
            // Pick the first provider whose supportsURL: matches.
            for (NSString *n in _providers) {
                Class c = _providers[n];
                id<MPGOStorageProvider> probe = [[c alloc] init];
                if ([probe supportsURL:url]) { cls = c; break; }
            }
            if (!cls) {
                if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
                        @"no registered provider supports URL '%@'", url);
                return nil;
            }
        }
    }
    id<MPGOStorageProvider> p = [[cls alloc] init];
    if (![p openURL:url mode:mode error:error]) return nil;
    return p;
}

@end
