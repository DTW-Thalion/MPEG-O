/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "TTIOCipherSuite.h"
#import "HDF5/TTIOHDF5Errors.h"   // TTIOMakeError

typedef struct {
    const char            *algorithm;
    TTIOCipherCategory     category;
    NSInteger              keySize;    // -1 = variable, 0 = N/A; for KEM/Sig: public-key size
    NSInteger              nonceSize;
    NSInteger              tagSize;
    TTIOCipherStatus       status;
    NSInteger              privateKeySize;  // v0.8 M49: KEM/Sig only, 0 for symmetric
} CatalogEntry;

static const CatalogEntry kCatalog[] = {
    { "aes-256-gcm", TTIOCipherCategoryAEAD,      32,  12,  16, TTIOCipherStatusActive,   0    },
    { "ml-kem-1024", TTIOCipherCategoryKEM,    1568,   0,   0, TTIOCipherStatusActive,   3168 },
    { "hmac-sha256", TTIOCipherCategoryMAC,       -1,   0,  32, TTIOCipherStatusActive,   0    },
    { "ml-dsa-87",   TTIOCipherCategorySignature, 2592, 0, 4627, TTIOCipherStatusActive,  4896 },
    { "sha-256",     TTIOCipherCategoryHash,       0,   0,  32, TTIOCipherStatusActive,   0    },
    { "shake256",    TTIOCipherCategoryXOF,        0,   0,   0, TTIOCipherStatusReserved, 0    },
};
static const size_t kCatalogCount = sizeof(kCatalog) / sizeof(kCatalog[0]);

static const CatalogEntry *findEntry(NSString *algorithm)
{
    const char *needle = [algorithm UTF8String];
    if (!needle) return NULL;
    for (size_t i = 0; i < kCatalogCount; i++) {
        if (strcmp(kCatalog[i].algorithm, needle) == 0) {
            return &kCatalog[i];
        }
    }
    return NULL;
}

@implementation TTIOCipherSuite

+ (BOOL)isSupported:(NSString *)algorithm
{
    const CatalogEntry *e = findEntry(algorithm);
    return e != NULL && e->status == TTIOCipherStatusActive;
}

+ (BOOL)isRegistered:(NSString *)algorithm
{
    return findEntry(algorithm) != NULL;
}

+ (TTIOCipherCategory)category:(NSString *)algorithm
{
    const CatalogEntry *e = findEntry(algorithm);
    return e ? e->category : TTIOCipherCategoryAEAD;
}

+ (NSInteger)keyLength:(NSString *)algorithm
{
    const CatalogEntry *e = findEntry(algorithm);
    return e ? e->keySize : 0;
}

+ (NSInteger)nonceLength:(NSString *)algorithm
{
    const CatalogEntry *e = findEntry(algorithm);
    return e ? e->nonceSize : 0;
}

+ (NSInteger)tagLength:(NSString *)algorithm
{
    const CatalogEntry *e = findEntry(algorithm);
    return e ? e->tagSize : 0;
}

+ (BOOL)validateKey:(NSData *)key
          algorithm:(NSString *)algorithm
              error:(NSError **)error
{
    const CatalogEntry *e = findEntry(algorithm);
    if (!e) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"unknown algorithm: '%@'", algorithm);
        return NO;
    }
    if (e->status != TTIOCipherStatusActive) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"'%@' is in the catalog but reserved — this build does "
            @"not ship the primitive", algorithm);
        return NO;
    }
    if (e->category == TTIOCipherCategoryKEM ||
        e->category == TTIOCipherCategorySignature) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"'%@' is asymmetric — use +validatePublicKey: or "
            @"+validatePrivateKey: instead of +validateKey:", algorithm);
        return NO;
    }
    if (e->keySize < 0) {
        // Variable-length (HMAC): require non-empty.
        if (key.length == 0) {
            if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
                @"%@: key must be non-empty (got 0 bytes)", algorithm);
            return NO;
        }
        return YES;
    }
    if ((NSInteger)key.length != e->keySize) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"%@: key must be %ld bytes (got %lu)",
            algorithm, (long)e->keySize, (unsigned long)key.length);
        return NO;
    }
    return YES;
}

+ (BOOL)validatePublicKey:(NSData *)key
                algorithm:(NSString *)algorithm
                    error:(NSError **)error
{
    const CatalogEntry *e = findEntry(algorithm);
    if (!e || e->status != TTIOCipherStatusActive) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"'%@' is not an active catalog entry", algorithm);
        return NO;
    }
    if (e->category != TTIOCipherCategoryKEM &&
        e->category != TTIOCipherCategorySignature) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"'%@' is symmetric; use +validateKey: instead", algorithm);
        return NO;
    }
    if ((NSInteger)key.length != e->keySize) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"%@: public key must be %ld bytes (got %lu)",
            algorithm, (long)e->keySize, (unsigned long)key.length);
        return NO;
    }
    return YES;
}

+ (BOOL)validatePrivateKey:(NSData *)key
                 algorithm:(NSString *)algorithm
                     error:(NSError **)error
{
    const CatalogEntry *e = findEntry(algorithm);
    if (!e || e->status != TTIOCipherStatusActive) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"'%@' is not an active catalog entry", algorithm);
        return NO;
    }
    if (e->category != TTIOCipherCategoryKEM &&
        e->category != TTIOCipherCategorySignature) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"'%@' is symmetric; use +validateKey: instead", algorithm);
        return NO;
    }
    if (e->privateKeySize <= 0) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"%@: catalog entry is missing privateKeySize", algorithm);
        return NO;
    }
    if ((NSInteger)key.length != e->privateKeySize) {
        if (error) *error = TTIOMakeError(TTIOErrorInvalidArgument,
            @"%@: private key must be %ld bytes (got %lu)",
            algorithm, (long)e->privateKeySize, (unsigned long)key.length);
        return NO;
    }
    return YES;
}

+ (NSInteger)publicKeySize:(NSString *)algorithm
{
    const CatalogEntry *e = findEntry(algorithm);
    if (!e || (e->category != TTIOCipherCategoryKEM &&
               e->category != TTIOCipherCategorySignature)) {
        [NSException raise:NSInvalidArgumentException
                    format:@"'%@' has no public key (not KEM/Signature)",
                           algorithm];
    }
    return e->keySize;
}

+ (NSInteger)privateKeySize:(NSString *)algorithm
{
    const CatalogEntry *e = findEntry(algorithm);
    if (!e || (e->category != TTIOCipherCategoryKEM &&
               e->category != TTIOCipherCategorySignature) ||
        e->privateKeySize <= 0) {
        [NSException raise:NSInvalidArgumentException
                    format:@"'%@' has no private key (not KEM/Signature)",
                           algorithm];
    }
    return e->privateKeySize;
}

+ (NSArray<NSString *> *)allAlgorithms
{
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:kCatalogCount];
    for (size_t i = 0; i < kCatalogCount; i++) {
        [out addObject:@(kCatalog[i].algorithm)];
    }
    return out;
}

@end
