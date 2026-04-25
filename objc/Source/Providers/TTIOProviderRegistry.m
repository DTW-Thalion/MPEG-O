#import "TTIOProviderRegistry.h"
#import "HDF5/TTIOHDF5Errors.h"

@implementation TTIOProviderRegistry {
    NSMutableDictionary<NSString *, Class> *_providers;
}

+ (instancetype)sharedRegistry
{
    static TTIOProviderRegistry *inst = nil;
    @synchronized (self) {
        if (!inst) inst = [[TTIOProviderRegistry alloc] init];
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

- (id<TTIOStorageProvider>)openURL:(NSString *)url
                               mode:(TTIOStorageOpenMode)mode
                           provider:(NSString *)providerName
                              error:(NSError **)error
{
    Class cls = nil;
    @synchronized (_providers) {
        if (providerName) {
            cls = _providers[providerName];
            if (!cls) {
                if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                        @"unknown provider '%@'. Known: %@",
                        providerName, _providers.allKeys);
                return nil;
            }
        } else {
            // Pick the first provider whose supportsURL: matches.
            for (NSString *n in _providers) {
                Class c = _providers[n];
                id<TTIOStorageProvider> probe = [[c alloc] init];
                if ([probe supportsURL:url]) { cls = c; break; }
            }
            if (!cls) {
                if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                        @"no registered provider supports URL '%@'", url);
                return nil;
            }
        }
    }
    id<TTIOStorageProvider> p = [[cls alloc] init];
    if (![p openURL:url mode:mode error:error]) return nil;
    return p;
}

@end
