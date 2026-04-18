/*
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "MPGOPostQuantumCrypto.h"
#import "HDF5/MPGOHDF5Errors.h"   // MPGOMakeError, MPGOErrorInvalidArgument

#if MPGO_HAVE_LIBOQS
#  include <oqs/oqs.h>
#  define MPGO_PQC_ENABLED 1
#else
#  define MPGO_PQC_ENABLED 0
#endif

@implementation MPGOPQCKeyPair
- (instancetype)initWithPublicKey:(NSData *)publicKey
                        privateKey:(NSData *)privateKey
{
    self = [super init];
    if (self) {
        _publicKey = [publicKey copy];
        _privateKey = [privateKey copy];
    }
    return self;
}
@end

@implementation MPGOPQCKemEncapResult
- (instancetype)initWithCiphertext:(NSData *)ciphertext
                       sharedSecret:(NSData *)sharedSecret
{
    self = [super init];
    if (self) {
        _ciphertext = [ciphertext copy];
        _sharedSecret = [sharedSecret copy];
    }
    return self;
}
@end

#pragma mark - Availability guard

static BOOL MPGO_SetUnavailableError(NSError **error)
{
    if (error) {
        *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"libMPGO was built without liboqs — PQC entry points "
            @"are not callable. Install liboqs (pip install "
            @"'mpeg-o[pqc]' auto-installs to $HOME/_oqs) and rebuild.");
    }
    return NO;
}

@implementation MPGOPostQuantumCrypto

+ (BOOL)isAvailable
{
    return MPGO_PQC_ENABLED;
}

#if MPGO_PQC_ENABLED

#pragma mark - ML-KEM-1024

+ (nullable MPGOPQCKeyPair *)kemKeygenWithError:(NSError **)error
{
    OQS_KEM *kem = OQS_KEM_new(OQS_KEM_alg_ml_kem_1024);
    if (!kem) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"liboqs: ML-KEM-1024 is not enabled in this libMPGO build");
        return nil;
    }
    NSMutableData *pk = [NSMutableData dataWithLength:kem->length_public_key];
    NSMutableData *sk = [NSMutableData dataWithLength:kem->length_secret_key];
    OQS_STATUS rc = OQS_KEM_keypair(kem, pk.mutableBytes, sk.mutableBytes);
    OQS_KEM_free(kem);
    if (rc != OQS_SUCCESS) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"OQS_KEM_keypair failed (rc=%d)", (int)rc);
        return nil;
    }
    return [[MPGOPQCKeyPair alloc] initWithPublicKey:pk privateKey:sk];
}

+ (nullable MPGOPQCKemEncapResult *)kemEncapsulateWithPublicKey:(NSData *)publicKey
                                                            error:(NSError **)error
{
    OQS_KEM *kem = OQS_KEM_new(OQS_KEM_alg_ml_kem_1024);
    if (!kem) return (MPGOPQCKemEncapResult *)(MPGO_SetUnavailableError(error), nil);
    if (publicKey.length != kem->length_public_key) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"ML-KEM-1024: public key must be %zu bytes (got %lu)",
            kem->length_public_key, (unsigned long)publicKey.length);
        OQS_KEM_free(kem);
        return nil;
    }
    NSMutableData *ct = [NSMutableData dataWithLength:kem->length_ciphertext];
    NSMutableData *ss = [NSMutableData dataWithLength:kem->length_shared_secret];
    OQS_STATUS rc = OQS_KEM_encaps(kem, ct.mutableBytes, ss.mutableBytes,
                                    publicKey.bytes);
    OQS_KEM_free(kem);
    if (rc != OQS_SUCCESS) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"OQS_KEM_encaps failed (rc=%d)", (int)rc);
        return nil;
    }
    return [[MPGOPQCKemEncapResult alloc] initWithCiphertext:ct sharedSecret:ss];
}

+ (nullable NSData *)kemDecapsulateWithPrivateKey:(NSData *)privateKey
                                         ciphertext:(NSData *)ciphertext
                                              error:(NSError **)error
{
    OQS_KEM *kem = OQS_KEM_new(OQS_KEM_alg_ml_kem_1024);
    if (!kem) { MPGO_SetUnavailableError(error); return nil; }
    if (privateKey.length != kem->length_secret_key) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"ML-KEM-1024: private key must be %zu bytes (got %lu)",
            kem->length_secret_key, (unsigned long)privateKey.length);
        OQS_KEM_free(kem);
        return nil;
    }
    if (ciphertext.length != kem->length_ciphertext) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"ML-KEM-1024: ciphertext must be %zu bytes (got %lu)",
            kem->length_ciphertext, (unsigned long)ciphertext.length);
        OQS_KEM_free(kem);
        return nil;
    }
    NSMutableData *ss = [NSMutableData dataWithLength:kem->length_shared_secret];
    OQS_STATUS rc = OQS_KEM_decaps(kem, ss.mutableBytes,
                                    ciphertext.bytes, privateKey.bytes);
    OQS_KEM_free(kem);
    if (rc != OQS_SUCCESS) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"OQS_KEM_decaps failed (rc=%d)", (int)rc);
        return nil;
    }
    return ss;
}

#pragma mark - ML-DSA-87

+ (nullable MPGOPQCKeyPair *)sigKeygenWithError:(NSError **)error
{
    OQS_SIG *sig = OQS_SIG_new(OQS_SIG_alg_ml_dsa_87);
    if (!sig) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"liboqs: ML-DSA-87 is not enabled in this libMPGO build");
        return nil;
    }
    NSMutableData *pk = [NSMutableData dataWithLength:sig->length_public_key];
    NSMutableData *sk = [NSMutableData dataWithLength:sig->length_secret_key];
    OQS_STATUS rc = OQS_SIG_keypair(sig, pk.mutableBytes, sk.mutableBytes);
    OQS_SIG_free(sig);
    if (rc != OQS_SUCCESS) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"OQS_SIG_keypair failed (rc=%d)", (int)rc);
        return nil;
    }
    return [[MPGOPQCKeyPair alloc] initWithPublicKey:pk privateKey:sk];
}

+ (nullable NSData *)sigSignWithPrivateKey:(NSData *)privateKey
                                    message:(NSData *)message
                                      error:(NSError **)error
{
    OQS_SIG *sig = OQS_SIG_new(OQS_SIG_alg_ml_dsa_87);
    if (!sig) { MPGO_SetUnavailableError(error); return nil; }
    if (privateKey.length != sig->length_secret_key) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"ML-DSA-87: private key must be %zu bytes (got %lu)",
            sig->length_secret_key, (unsigned long)privateKey.length);
        OQS_SIG_free(sig);
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithLength:sig->length_signature];
    size_t sigLen = 0;
    OQS_STATUS rc = OQS_SIG_sign(sig, out.mutableBytes, &sigLen,
                                   message.bytes, message.length,
                                   privateKey.bytes);
    OQS_SIG_free(sig);
    if (rc != OQS_SUCCESS) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"OQS_SIG_sign failed (rc=%d)", (int)rc);
        return nil;
    }
    [out setLength:sigLen];
    return out;
}

+ (BOOL)sigVerifyWithPublicKey:(NSData *)publicKey
                         message:(NSData *)message
                       signature:(NSData *)signature
                           error:(NSError **)error
{
    OQS_SIG *sig = OQS_SIG_new(OQS_SIG_alg_ml_dsa_87);
    if (!sig) return MPGO_SetUnavailableError(error);
    if (publicKey.length != sig->length_public_key) {
        if (error) *error = MPGOMakeError(MPGOErrorInvalidArgument,
            @"ML-DSA-87: public key must be %zu bytes (got %lu)",
            sig->length_public_key, (unsigned long)publicKey.length);
        OQS_SIG_free(sig);
        return NO;
    }
    OQS_STATUS rc = OQS_SIG_verify(sig, message.bytes, message.length,
                                     signature.bytes, signature.length,
                                     publicKey.bytes);
    OQS_SIG_free(sig);
    return rc == OQS_SUCCESS;
}

#else  // MPGO_PQC_ENABLED == 0 — liboqs absent at build time

+ (nullable MPGOPQCKeyPair *)kemKeygenWithError:(NSError **)error
    { MPGO_SetUnavailableError(error); return nil; }
+ (nullable MPGOPQCKemEncapResult *)kemEncapsulateWithPublicKey:(NSData *)publicKey
                                                            error:(NSError **)error
    { MPGO_SetUnavailableError(error); return nil; }
+ (nullable NSData *)kemDecapsulateWithPrivateKey:(NSData *)privateKey
                                         ciphertext:(NSData *)ciphertext
                                              error:(NSError **)error
    { MPGO_SetUnavailableError(error); return nil; }
+ (nullable MPGOPQCKeyPair *)sigKeygenWithError:(NSError **)error
    { MPGO_SetUnavailableError(error); return nil; }
+ (nullable NSData *)sigSignWithPrivateKey:(NSData *)privateKey
                                    message:(NSData *)message
                                      error:(NSError **)error
    { MPGO_SetUnavailableError(error); return nil; }
+ (BOOL)sigVerifyWithPublicKey:(NSData *)publicKey
                         message:(NSData *)message
                       signature:(NSData *)signature
                           error:(NSError **)error
    { return MPGO_SetUnavailableError(error); }

#endif /* MPGO_PQC_ENABLED */

@end
