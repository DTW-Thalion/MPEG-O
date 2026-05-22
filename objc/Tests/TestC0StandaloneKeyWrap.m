/*
 * TestC0StandaloneKeyWrap — FD-1 Phase C-0 (ObjC).
 *
 * Standalone (fileless) key-wrap primitive on TTIOKeyRotationManager,
 * filling the gap that Java (EncryptionManager.wrapKey) and Python
 * (key_rotation._wrap_dek) already cover. The server key-custody
 * software-KMS stub (Phase C-1) calls these to (un)wrap a DEK under a
 * tenant KEK, so a client-wrapped server recipient entry is recoverable
 * server-side.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Protection/TTIOKeyRotationManager.h"

static NSData *filled(NSUInteger n, uint8_t v) {
    uint8_t *b = malloc(n);
    memset(b, v, n);
    NSData *d = [NSData dataWithBytes:b length:n];
    free(b);
    return d;
}

void testC0StandaloneKeyWrap(void)
{
    NSData *dek = filled(32, 0x5A);
    NSData *kek = filled(32, 0x11);

    // aes-256-gcm round-trip: unwrap recovers the exact DEK.
    NSError *err = nil;
    NSData *wrapped = [TTIOKeyRotationManager wrapKey:dek withKEK:kek
                                            algorithm:@"aes-256-gcm" error:&err];
    PASS(wrapped != nil, "wrapKey(aes-256-gcm) succeeds");
    PASS(wrapped.length != dek.length,
         "wrapped blob is a versioned envelope, not the bare DEK");

    NSData *recovered = [TTIOKeyRotationManager unwrapKey:wrapped withKEK:kek
                                                algorithm:@"aes-256-gcm" error:&err];
    PASS([recovered isEqualToData:dek],
         "unwrapKey(aes-256-gcm) recovers the DEK byte-for-byte");

    // A wrong KEK must fail authentication (nil, not garbage).
    NSData *wrongKek = filled(32, 0x22);
    err = nil;
    NSData *bad = [TTIOKeyRotationManager unwrapKey:wrapped withKEK:wrongKek
                                          algorithm:@"aes-256-gcm" error:&err];
    PASS(bad == nil, "unwrapKey with the wrong KEK fails (AES-GCM auth)");

    // An unsupported algorithm is a hard error, not a silent pass.
    err = nil;
    NSData *unsupported = [TTIOKeyRotationManager wrapKey:dek withKEK:kek
                                                algorithm:@"rot13" error:&err];
    PASS(unsupported == nil && err != nil,
         "wrapKey rejects an unsupported algorithm");
}
