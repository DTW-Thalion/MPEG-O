/*
 * TestMilestone49 — Post-quantum crypto (ObjC side, liboqs).
 *
 * Covers TTIOPostQuantumCrypto primitive round-trips (ML-KEM-1024,
 * ML-DSA-87), TTIOCipherSuite activation of the two PQC algorithms,
 * and the v0.8 opt_pqc_preview feature-flag constant.
 *
 * Primitive tests are short-circuited when libTTIO was compiled
 * without liboqs ([TTIOPostQuantumCrypto isAvailable] returns NO);
 * the catalog assertions run unconditionally.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Protection/TTIOCipherSuite.h"
#import "Protection/TTIOPostQuantumCrypto.h"
#import "Protection/TTIOKeyRotationManager.h"
#import "Protection/TTIOSignatureManager.h"
#import "HDF5/TTIOFeatureFlags.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "ValueClasses/TTIOEnums.h"

static NSString *m49TempPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_m49_%d_%@.tio",
            (int)getpid(), suffix];
}

void testMilestone49(void)
{
    // ── Catalog activation (runs unconditionally) ──

    PASS([TTIOCipherSuite isSupported:@"ml-kem-1024"],
         "M49: ml-kem-1024 is now active");
    PASS([TTIOCipherSuite isSupported:@"ml-dsa-87"],
         "M49: ml-dsa-87 is now active");
    PASS(![TTIOCipherSuite isSupported:@"shake256"],
         "M49: shake256 remains reserved");

    PASS([TTIOCipherSuite publicKeySize:@"ml-kem-1024"] == 1568,
         "M49: ML-KEM-1024 public key size is 1568");
    PASS([TTIOCipherSuite privateKeySize:@"ml-kem-1024"] == 3168,
         "M49: ML-KEM-1024 private key size is 3168");
    PASS([TTIOCipherSuite publicKeySize:@"ml-dsa-87"] == 2592,
         "M49: ML-DSA-87 public key size is 2592");
    PASS([TTIOCipherSuite privateKeySize:@"ml-dsa-87"] == 4896,
         "M49: ML-DSA-87 private key size is 4896");

    NSData *guess = [NSMutableData dataWithLength:1568];
    NSError *verr = nil;
    BOOL accepted = [TTIOCipherSuite validateKey:guess
                                        algorithm:@"ml-kem-1024"
                                            error:&verr];
    PASS(!accepted,
         "M49: +validateKey: rejects asymmetric algorithms");
    PASS(verr != nil &&
         [verr.localizedDescription rangeOfString:@"asymmetric"].location != NSNotFound,
         "M49: asymmetric-rejection error names the condition");

    verr = nil;
    BOOL pkOk = [TTIOCipherSuite validatePublicKey:guess
                                          algorithm:@"ml-kem-1024"
                                              error:&verr];
    PASS(pkOk, "M49: +validatePublicKey: accepts 1568-byte ML-KEM pk");

    NSData *sk = [NSMutableData dataWithLength:3168];
    verr = nil;
    BOOL swapFail = [TTIOCipherSuite validatePublicKey:sk
                                              algorithm:@"ml-kem-1024"
                                                  error:&verr];
    PASS(!swapFail,
         "M49: +validatePublicKey: rejects sk-sized input");

    PASS([[TTIOFeatureFlags featurePQCPreview]
           isEqualToString:@"opt_pqc_preview"],
         "M49: +featurePQCPreview string matches spec");

    // ── Primitive round-trips (requires liboqs linked) ──

    if (![TTIOPostQuantumCrypto isAvailable]) {
        NSLog(@"M49: skipping PQC primitive tests — liboqs not linked at build time");
        return;
    }

    NSError *err = nil;

    TTIOPQCKeyPair *kemKp = [TTIOPostQuantumCrypto kemKeygenWithError:&err];
    PASS(kemKp != nil, "M49: ML-KEM-1024 keygen succeeds");
    PASS(kemKp.publicKey.length == 1568,
         "M49: ML-KEM-1024 pk is 1568 bytes");
    PASS(kemKp.privateKey.length == 3168,
         "M49: ML-KEM-1024 sk is 3168 bytes");

    err = nil;
    TTIOPQCKemEncapResult *enc =
        [TTIOPostQuantumCrypto kemEncapsulateWithPublicKey:kemKp.publicKey
                                                       error:&err];
    PASS(enc != nil, "M49: encapsulate succeeds");
    PASS(enc.ciphertext.length == 1568,
         "M49: KEM ciphertext is 1568 bytes");
    PASS(enc.sharedSecret.length == 32,
         "M49: shared secret is 32 bytes");

    err = nil;
    NSData *ss2 =
        [TTIOPostQuantumCrypto kemDecapsulateWithPrivateKey:kemKp.privateKey
                                                   ciphertext:enc.ciphertext
                                                        error:&err];
    PASS(ss2 != nil, "M49: decapsulate succeeds");
    PASS([enc.sharedSecret isEqualToData:ss2],
         "M49: ML-KEM-1024 shared secret round-trips");

    err = nil;
    TTIOPQCKeyPair *kemKpBad = [TTIOPostQuantumCrypto kemKeygenWithError:&err];
    NSData *ssWrong =
        [TTIOPostQuantumCrypto kemDecapsulateWithPrivateKey:kemKpBad.privateKey
                                                   ciphertext:enc.ciphertext
                                                        error:&err];
    PASS(ssWrong != nil && ![ssWrong isEqualToData:enc.sharedSecret],
         "M49: wrong sk yields different (unauthenticated) shared secret");

    err = nil;
    TTIOPQCKeyPair *sigKp = [TTIOPostQuantumCrypto sigKeygenWithError:&err];
    PASS(sigKp != nil, "M49: ML-DSA-87 keygen succeeds");
    PASS(sigKp.publicKey.length == 2592,
         "M49: ML-DSA-87 pk is 2592 bytes");
    PASS(sigKp.privateKey.length == 4896,
         "M49: ML-DSA-87 sk is 4896 bytes");

    NSData *msg = [@"the quick brown fox"
                   dataUsingEncoding:NSUTF8StringEncoding];
    err = nil;
    NSData *sig = [TTIOPostQuantumCrypto sigSignWithPrivateKey:sigKp.privateKey
                                                         message:msg
                                                           error:&err];
    PASS(sig != nil, "M49: ML-DSA-87 sign succeeds");
    PASS(sig.length == 4627,
         "M49: ML-DSA-87 signature is 4627 bytes");

    err = nil;
    BOOL ok = [TTIOPostQuantumCrypto sigVerifyWithPublicKey:sigKp.publicKey
                                                     message:msg
                                                   signature:sig
                                                       error:&err];
    PASS(ok, "M49: ML-DSA-87 verify succeeds on original message");

    NSMutableData *tampered = [msg mutableCopy];
    ((uint8_t *)tampered.mutableBytes)[0] ^= 0x01;
    BOOL badOk = [TTIOPostQuantumCrypto sigVerifyWithPublicKey:sigKp.publicKey
                                                         message:tampered
                                                       signature:sig
                                                           error:&err];
    PASS(!badOk, "M49: verify fails on tampered message");

    // ── M49.1: ML-KEM envelope via TTIOKeyRotationManager ──

    NSString *envPath = m49TempPath(@"envelope");
    unlink([envPath fileSystemRepresentation]);

    err = nil;
    TTIOHDF5File *envFile = [TTIOHDF5File createAtPath:envPath error:&err];
    PASS(envFile != nil, "M49.1: create file for ML-KEM envelope");
    TTIOKeyRotationManager *mgr =
        [TTIOKeyRotationManager managerWithFile:envFile];
    TTIOPQCKeyPair *envKp = [TTIOPostQuantumCrypto kemKeygenWithError:&err];

    err = nil;
    NSData *dek = [mgr enableEnvelopeEncryptionWithKEK:envKp.publicKey
                                                  kekId:@"kem-1"
                                              algorithm:@"ml-kem-1024"
                                                  error:&err];
    PASS(dek != nil && dek.length == 32,
         "M49.1: enableEnvelopeEncryption with ml-kem-1024 returns DEK");
    PASS([mgr hasEnvelopeEncryption],
         "M49.1: envelope encryption is active on the file");
    [envFile close];

    // Reopen and round-trip the DEK with the private key.
    err = nil;
    TTIOHDF5File *envRe = [TTIOHDF5File openAtPath:envPath error:&err];
    TTIOKeyRotationManager *mgr2 =
        [TTIOKeyRotationManager managerWithFile:envRe];
    NSData *dek2 = [mgr2 unwrapDEKWithKEK:envKp.privateKey
                                 algorithm:@"ml-kem-1024"
                                     error:&err];
    PASS(dek2 != nil && [dek2 isEqualToData:dek],
         "M49.1: ML-KEM unwrap round-trips the DEK");

    // Wrong private key must fail (AES-GCM tag mismatch downstream).
    err = nil;
    TTIOPQCKeyPair *wrongKp =
        [TTIOPostQuantumCrypto kemKeygenWithError:&err];
    NSError *wrongErr = nil;
    NSData *dekWrong = [mgr2 unwrapDEKWithKEK:wrongKp.privateKey
                                     algorithm:@"ml-kem-1024"
                                         error:&wrongErr];
    PASS(dekWrong == nil, "M49.1: ML-KEM unwrap fails with wrong private key");

    // opt_pqc_preview is now on the root feature list.
    NSArray<NSString *> *features =
        [TTIOFeatureFlags featuresForRoot:[envRe rootGroup]];
    PASS([features containsObject:[TTIOFeatureFlags featurePQCPreview]],
         "M49.1: opt_pqc_preview flag set on ML-KEM-wrapped file");
    [envRe close];

    // ── M49.1: v3 dataset signatures via TTIOSignatureManager ──

    NSString *sigPath = m49TempPath(@"v3sig");
    unlink([sigPath fileSystemRepresentation]);

    err = nil;
    TTIOHDF5File *sigFile = [TTIOHDF5File createAtPath:sigPath error:&err];
    PASS(sigFile != nil, "M49.1: create file for v3 signatures");
    TTIOHDF5Dataset *ds =
        [[sigFile rootGroup] createDatasetNamed:@"payload"
                                       precision:TTIOPrecisionFloat64
                                          length:64
                                       chunkSize:0
                                compressionLevel:0
                                           error:&err];
    double vals[64];
    for (int i = 0; i < 64; i++) vals[i] = (double)i;
    NSData *payload = [NSData dataWithBytes:vals length:sizeof(vals)];
    PASS([ds writeData:payload error:&err], "M49.1: write payload dataset");
    [sigFile close];

    TTIOPQCKeyPair *sigKp2 =
        [TTIOPostQuantumCrypto sigKeygenWithError:&err];
    err = nil;
    BOOL signed_ = [TTIOSignatureManager signDataset:@"/payload"
                                              inFile:sigPath
                                             withKey:sigKp2.privateKey
                                           algorithm:@"ml-dsa-87"
                                               error:&err];
    PASS(signed_, "M49.1: signDataset with ml-dsa-87 succeeds");

    err = nil;
    BOOL verified = [TTIOSignatureManager verifyDataset:@"/payload"
                                                  inFile:sigPath
                                                 withKey:sigKp2.publicKey
                                               algorithm:@"ml-dsa-87"
                                                   error:&err];
    PASS(verified, "M49.1: verifyDataset with ml-dsa-87 succeeds");

    // Algorithm mismatch on verify must refuse, not silently pass.
    err = nil;
    NSData *hmacKey = [NSMutableData dataWithLength:32];
    BOOL crossed = [TTIOSignatureManager verifyDataset:@"/payload"
                                                 inFile:sigPath
                                                withKey:hmacKey
                                              algorithm:@"hmac-sha256"
                                                  error:&err];
    PASS(!crossed, "M49.1: verify with hmac-sha256 on v3 attribute is rejected");
    PASS(err != nil && [err.localizedDescription rangeOfString:@"v3"].location != NSNotFound,
         "M49.1: cross-algorithm mismatch error mentions v3");

    // opt_pqc_preview is set on the signed file.
    TTIOHDF5File *sigReopen =
        [TTIOHDF5File openReadOnlyAtPath:sigPath error:&err];
    NSArray<NSString *> *sigFeatures =
        [TTIOFeatureFlags featuresForRoot:[sigReopen rootGroup]];
    PASS([sigFeatures containsObject:[TTIOFeatureFlags featurePQCPreview]],
         "M49.1: opt_pqc_preview flag set on v3-signed file");
    [sigReopen close];

    // Cleanup tmp files.
    unlink([envPath fileSystemRepresentation]);
    unlink([sigPath fileSystemRepresentation]);
}
