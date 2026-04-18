/*
 * TestMilestone49 — Post-quantum crypto (ObjC side, liboqs).
 *
 * Covers MPGOPostQuantumCrypto primitive round-trips (ML-KEM-1024,
 * ML-DSA-87), MPGOCipherSuite activation of the two PQC algorithms,
 * and the v0.8 opt_pqc_preview feature-flag constant.
 *
 * Primitive tests are short-circuited when libMPGO was compiled
 * without liboqs ([MPGOPostQuantumCrypto isAvailable] returns NO);
 * the catalog assertions run unconditionally.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>

#import "Protection/MPGOCipherSuite.h"
#import "Protection/MPGOPostQuantumCrypto.h"
#import "Protection/MPGOKeyRotationManager.h"
#import "Protection/MPGOSignatureManager.h"
#import "HDF5/MPGOFeatureFlags.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Dataset.h"
#import "ValueClasses/MPGOEnums.h"

static NSString *m49TempPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m49_%d_%@.mpgo",
            (int)getpid(), suffix];
}

void testMilestone49(void)
{
    // ── Catalog activation (runs unconditionally) ──

    PASS([MPGOCipherSuite isSupported:@"ml-kem-1024"],
         "M49: ml-kem-1024 is now active");
    PASS([MPGOCipherSuite isSupported:@"ml-dsa-87"],
         "M49: ml-dsa-87 is now active");
    PASS(![MPGOCipherSuite isSupported:@"shake256"],
         "M49: shake256 remains reserved");

    PASS([MPGOCipherSuite publicKeySize:@"ml-kem-1024"] == 1568,
         "M49: ML-KEM-1024 public key size is 1568");
    PASS([MPGOCipherSuite privateKeySize:@"ml-kem-1024"] == 3168,
         "M49: ML-KEM-1024 private key size is 3168");
    PASS([MPGOCipherSuite publicKeySize:@"ml-dsa-87"] == 2592,
         "M49: ML-DSA-87 public key size is 2592");
    PASS([MPGOCipherSuite privateKeySize:@"ml-dsa-87"] == 4896,
         "M49: ML-DSA-87 private key size is 4896");

    NSData *guess = [NSMutableData dataWithLength:1568];
    NSError *verr = nil;
    BOOL accepted = [MPGOCipherSuite validateKey:guess
                                        algorithm:@"ml-kem-1024"
                                            error:&verr];
    PASS(!accepted,
         "M49: +validateKey: rejects asymmetric algorithms");
    PASS(verr != nil &&
         [verr.localizedDescription rangeOfString:@"asymmetric"].location != NSNotFound,
         "M49: asymmetric-rejection error names the condition");

    verr = nil;
    BOOL pkOk = [MPGOCipherSuite validatePublicKey:guess
                                          algorithm:@"ml-kem-1024"
                                              error:&verr];
    PASS(pkOk, "M49: +validatePublicKey: accepts 1568-byte ML-KEM pk");

    NSData *sk = [NSMutableData dataWithLength:3168];
    verr = nil;
    BOOL swapFail = [MPGOCipherSuite validatePublicKey:sk
                                              algorithm:@"ml-kem-1024"
                                                  error:&verr];
    PASS(!swapFail,
         "M49: +validatePublicKey: rejects sk-sized input");

    PASS([[MPGOFeatureFlags featurePQCPreview]
           isEqualToString:@"opt_pqc_preview"],
         "M49: +featurePQCPreview string matches spec");

    // ── Primitive round-trips (requires liboqs linked) ──

    if (![MPGOPostQuantumCrypto isAvailable]) {
        NSLog(@"M49: skipping PQC primitive tests — liboqs not linked at build time");
        return;
    }

    NSError *err = nil;

    MPGOPQCKeyPair *kemKp = [MPGOPostQuantumCrypto kemKeygenWithError:&err];
    PASS(kemKp != nil, "M49: ML-KEM-1024 keygen succeeds");
    PASS(kemKp.publicKey.length == 1568,
         "M49: ML-KEM-1024 pk is 1568 bytes");
    PASS(kemKp.privateKey.length == 3168,
         "M49: ML-KEM-1024 sk is 3168 bytes");

    err = nil;
    MPGOPQCKemEncapResult *enc =
        [MPGOPostQuantumCrypto kemEncapsulateWithPublicKey:kemKp.publicKey
                                                       error:&err];
    PASS(enc != nil, "M49: encapsulate succeeds");
    PASS(enc.ciphertext.length == 1568,
         "M49: KEM ciphertext is 1568 bytes");
    PASS(enc.sharedSecret.length == 32,
         "M49: shared secret is 32 bytes");

    err = nil;
    NSData *ss2 =
        [MPGOPostQuantumCrypto kemDecapsulateWithPrivateKey:kemKp.privateKey
                                                   ciphertext:enc.ciphertext
                                                        error:&err];
    PASS(ss2 != nil, "M49: decapsulate succeeds");
    PASS([enc.sharedSecret isEqualToData:ss2],
         "M49: ML-KEM-1024 shared secret round-trips");

    err = nil;
    MPGOPQCKeyPair *kemKpBad = [MPGOPostQuantumCrypto kemKeygenWithError:&err];
    NSData *ssWrong =
        [MPGOPostQuantumCrypto kemDecapsulateWithPrivateKey:kemKpBad.privateKey
                                                   ciphertext:enc.ciphertext
                                                        error:&err];
    PASS(ssWrong != nil && ![ssWrong isEqualToData:enc.sharedSecret],
         "M49: wrong sk yields different (unauthenticated) shared secret");

    err = nil;
    MPGOPQCKeyPair *sigKp = [MPGOPostQuantumCrypto sigKeygenWithError:&err];
    PASS(sigKp != nil, "M49: ML-DSA-87 keygen succeeds");
    PASS(sigKp.publicKey.length == 2592,
         "M49: ML-DSA-87 pk is 2592 bytes");
    PASS(sigKp.privateKey.length == 4896,
         "M49: ML-DSA-87 sk is 4896 bytes");

    NSData *msg = [@"the quick brown fox"
                   dataUsingEncoding:NSUTF8StringEncoding];
    err = nil;
    NSData *sig = [MPGOPostQuantumCrypto sigSignWithPrivateKey:sigKp.privateKey
                                                         message:msg
                                                           error:&err];
    PASS(sig != nil, "M49: ML-DSA-87 sign succeeds");
    PASS(sig.length == 4627,
         "M49: ML-DSA-87 signature is 4627 bytes");

    err = nil;
    BOOL ok = [MPGOPostQuantumCrypto sigVerifyWithPublicKey:sigKp.publicKey
                                                     message:msg
                                                   signature:sig
                                                       error:&err];
    PASS(ok, "M49: ML-DSA-87 verify succeeds on original message");

    NSMutableData *tampered = [msg mutableCopy];
    ((uint8_t *)tampered.mutableBytes)[0] ^= 0x01;
    BOOL badOk = [MPGOPostQuantumCrypto sigVerifyWithPublicKey:sigKp.publicKey
                                                         message:tampered
                                                       signature:sig
                                                           error:&err];
    PASS(!badOk, "M49: verify fails on tampered message");

    // ── M49.1: ML-KEM envelope via MPGOKeyRotationManager ──

    NSString *envPath = m49TempPath(@"envelope");
    unlink([envPath fileSystemRepresentation]);

    err = nil;
    MPGOHDF5File *envFile = [MPGOHDF5File createAtPath:envPath error:&err];
    PASS(envFile != nil, "M49.1: create file for ML-KEM envelope");
    MPGOKeyRotationManager *mgr =
        [MPGOKeyRotationManager managerWithFile:envFile];
    MPGOPQCKeyPair *envKp = [MPGOPostQuantumCrypto kemKeygenWithError:&err];

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
    MPGOHDF5File *envRe = [MPGOHDF5File openAtPath:envPath error:&err];
    MPGOKeyRotationManager *mgr2 =
        [MPGOKeyRotationManager managerWithFile:envRe];
    NSData *dek2 = [mgr2 unwrapDEKWithKEK:envKp.privateKey
                                 algorithm:@"ml-kem-1024"
                                     error:&err];
    PASS(dek2 != nil && [dek2 isEqualToData:dek],
         "M49.1: ML-KEM unwrap round-trips the DEK");

    // Wrong private key must fail (AES-GCM tag mismatch downstream).
    err = nil;
    MPGOPQCKeyPair *wrongKp =
        [MPGOPostQuantumCrypto kemKeygenWithError:&err];
    NSError *wrongErr = nil;
    NSData *dekWrong = [mgr2 unwrapDEKWithKEK:wrongKp.privateKey
                                     algorithm:@"ml-kem-1024"
                                         error:&wrongErr];
    PASS(dekWrong == nil, "M49.1: ML-KEM unwrap fails with wrong private key");

    // opt_pqc_preview is now on the root feature list.
    NSArray<NSString *> *features =
        [MPGOFeatureFlags featuresForRoot:[envRe rootGroup]];
    PASS([features containsObject:[MPGOFeatureFlags featurePQCPreview]],
         "M49.1: opt_pqc_preview flag set on ML-KEM-wrapped file");
    [envRe close];

    // ── M49.1: v3 dataset signatures via MPGOSignatureManager ──

    NSString *sigPath = m49TempPath(@"v3sig");
    unlink([sigPath fileSystemRepresentation]);

    err = nil;
    MPGOHDF5File *sigFile = [MPGOHDF5File createAtPath:sigPath error:&err];
    PASS(sigFile != nil, "M49.1: create file for v3 signatures");
    MPGOHDF5Dataset *ds =
        [[sigFile rootGroup] createDatasetNamed:@"payload"
                                       precision:MPGOPrecisionFloat64
                                          length:64
                                       chunkSize:0
                                compressionLevel:0
                                           error:&err];
    double vals[64];
    for (int i = 0; i < 64; i++) vals[i] = (double)i;
    NSData *payload = [NSData dataWithBytes:vals length:sizeof(vals)];
    PASS([ds writeData:payload error:&err], "M49.1: write payload dataset");
    [sigFile close];

    MPGOPQCKeyPair *sigKp2 =
        [MPGOPostQuantumCrypto sigKeygenWithError:&err];
    err = nil;
    BOOL signed_ = [MPGOSignatureManager signDataset:@"/payload"
                                              inFile:sigPath
                                             withKey:sigKp2.privateKey
                                           algorithm:@"ml-dsa-87"
                                               error:&err];
    PASS(signed_, "M49.1: signDataset with ml-dsa-87 succeeds");

    err = nil;
    BOOL verified = [MPGOSignatureManager verifyDataset:@"/payload"
                                                  inFile:sigPath
                                                 withKey:sigKp2.publicKey
                                               algorithm:@"ml-dsa-87"
                                                   error:&err];
    PASS(verified, "M49.1: verifyDataset with ml-dsa-87 succeeds");

    // Algorithm mismatch on verify must refuse, not silently pass.
    err = nil;
    NSData *hmacKey = [NSMutableData dataWithLength:32];
    BOOL crossed = [MPGOSignatureManager verifyDataset:@"/payload"
                                                 inFile:sigPath
                                                withKey:hmacKey
                                              algorithm:@"hmac-sha256"
                                                  error:&err];
    PASS(!crossed, "M49.1: verify with hmac-sha256 on v3 attribute is rejected");
    PASS(err != nil && [err.localizedDescription rangeOfString:@"v3"].location != NSNotFound,
         "M49.1: cross-algorithm mismatch error mentions v3");

    // opt_pqc_preview is set on the signed file.
    MPGOHDF5File *sigReopen =
        [MPGOHDF5File openReadOnlyAtPath:sigPath error:&err];
    NSArray<NSString *> *sigFeatures =
        [MPGOFeatureFlags featuresForRoot:[sigReopen rootGroup]];
    PASS([sigFeatures containsObject:[MPGOFeatureFlags featurePQCPreview]],
         "M49.1: opt_pqc_preview flag set on v3-signed file");
    [sigReopen close];

    // Cleanup tmp files.
    unlink([envPath fileSystemRepresentation]);
    unlink([sigPath fileSystemRepresentation]);
}
