/*
 * TtioPQCTool — cross-language PQC conformance CLI (v0.8 M54).
 *
 * Invoked by the cross-language conformance harness
 * (python/tests/test_m54_pqc_conformance.py) as the ObjC counterpart
 * of the Java com.dtwthalion.ttio.tools.PQCTool. Subcommands match the
 * Java tool 1:1 so the pytest harness can drive both with identical
 * argument strings.
 *
 * Subcommands (all file arguments are raw bytes, no hex wrapping):
 *   sig-keygen  PK_OUT  SK_OUT
 *   sig-sign    SK_IN   MSG_IN  SIG_OUT
 *   sig-verify  PK_IN   MSG_IN  SIG_IN                (exit 0/1/2)
 *   kem-keygen  PK_OUT  SK_OUT
 *   kem-encaps  PK_IN   CT_OUT  SS_OUT
 *   kem-decaps  SK_IN   CT_IN   SS_OUT
 *   hdf5-sign   FILE    DATASET_PATH  SK_IN
 *   hdf5-verify FILE    DATASET_PATH  PK_IN            (exit 0/1/2)
 *
 * Build via gnustep-make (see GNUmakefile).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Protection/TTIOCipherSuite.h"
#import "Protection/TTIOPostQuantumCrypto.h"
#import "Protection/TTIOSignatureManager.h"
#import "Providers/TTIOHDF5Provider.h"
#import "Providers/TTIOProviderRegistry.h"
#import "Providers/TTIOStorageProtocols.h"

static NSData *readBytes(NSString *path)
{
    return [NSData dataWithContentsOfFile:path] ?: [NSData data];
}

static void writeBytes(NSString *path, NSData *bytes)
{
    [bytes writeToFile:path atomically:YES];
}

static int subKeygen(BOOL isSig, int argc, char **argv)
{
    if (argc < 4) { fprintf(stderr, "usage: %s PK_OUT SK_OUT\n", argv[1]); return 2; }
    NSError *err = nil;
    TTIOPQCKeyPair *kp = isSig
        ? [TTIOPostQuantumCrypto sigKeygenWithError:&err]
        : [TTIOPostQuantumCrypto kemKeygenWithError:&err];
    if (!kp) {
        fprintf(stderr, "keygen failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
        return 2;
    }
    writeBytes(@(argv[2]), kp.publicKey);
    writeBytes(@(argv[3]), kp.privateKey);
    return 0;
}

static int subSigSign(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: sig-sign SK_IN MSG_IN SIG_OUT\n"); return 2; }
    NSError *err = nil;
    NSData *sk = readBytes(@(argv[2]));
    NSData *msg = readBytes(@(argv[3]));
    NSData *sig = [TTIOPostQuantumCrypto sigSignWithPrivateKey:sk
                                                         message:msg
                                                           error:&err];
    if (!sig) {
        fprintf(stderr, "sign failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
        return 2;
    }
    writeBytes(@(argv[4]), sig);
    return 0;
}

static int subSigVerify(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: sig-verify PK_IN MSG_IN SIG_IN\n"); return 2; }
    NSError *err = nil;
    NSData *pk = readBytes(@(argv[2]));
    NSData *msg = readBytes(@(argv[3]));
    NSData *sig = readBytes(@(argv[4]));
    BOOL ok = [TTIOPostQuantumCrypto sigVerifyWithPublicKey:pk
                                                     message:msg
                                                   signature:sig
                                                       error:&err];
    return ok ? 0 : 1;
}

static int subKemEncaps(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: kem-encaps PK_IN CT_OUT SS_OUT\n"); return 2; }
    NSError *err = nil;
    NSData *pk = readBytes(@(argv[2]));
    TTIOPQCKemEncapResult *r =
        [TTIOPostQuantumCrypto kemEncapsulateWithPublicKey:pk error:&err];
    if (!r) {
        fprintf(stderr, "encaps failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
        return 2;
    }
    writeBytes(@(argv[3]), r.ciphertext);
    writeBytes(@(argv[4]), r.sharedSecret);
    return 0;
}

static int subKemDecaps(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: kem-decaps SK_IN CT_IN SS_OUT\n"); return 2; }
    NSError *err = nil;
    NSData *sk = readBytes(@(argv[2]));
    NSData *ct = readBytes(@(argv[3]));
    NSData *ss = [TTIOPostQuantumCrypto kemDecapsulateWithPrivateKey:sk
                                                           ciphertext:ct
                                                                error:&err];
    if (!ss) {
        fprintf(stderr, "decaps failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
        return 2;
    }
    writeBytes(@(argv[4]), ss);
    return 0;
}

static int subHdf5Sign(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: hdf5-sign FILE DS_PATH SK_IN\n"); return 2; }
    NSError *err = nil;
    NSData *sk = readBytes(@(argv[4]));
    BOOL ok = [TTIOSignatureManager signDataset:@(argv[3])
                                          inFile:@(argv[2])
                                         withKey:sk
                                       algorithm:@"ml-dsa-87"
                                           error:&err];
    if (!ok) {
        fprintf(stderr, "hdf5-sign failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
        return 2;
    }
    return 0;
}

static int subHdf5Verify(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: hdf5-verify FILE DS_PATH PK_IN\n"); return 2; }
    NSError *err = nil;
    NSData *pk = readBytes(@(argv[4]));
    BOOL ok = [TTIOSignatureManager verifyDataset:@(argv[3])
                                            inFile:@(argv[2])
                                           withKey:pk
                                         algorithm:@"ml-dsa-87"
                                             error:&err];
    return ok ? 0 : 1;
}

// ── Provider-agnostic sign/verify (v0.8 M54.1) ───────────────────────

static id<TTIOStorageDataset> openDatasetAtPath(id<TTIOStorageGroup> root,
                                                  NSString *path,
                                                  NSError **error)
{
    NSString *trimmed = [path hasPrefix:@"/"] ? [path substringFromIndex:1] : path;
    NSArray<NSString *> *parts = [trimmed componentsSeparatedByString:@"/"];
    id<TTIOStorageGroup> cur = root;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        cur = [cur openGroupNamed:parts[i] error:error];
        if (!cur) return nil;
    }
    return [cur openDatasetNamed:parts.lastObject error:error];
}

static int subProviderSign(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: provider-sign URL DS_PATH SK_IN\n"); return 2; }
    NSError *err = nil;
    NSData *sk = readBytes(@(argv[4]));
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry] openURL:@(argv[2])
                                                   mode:TTIOStorageOpenModeReadWrite
                                               provider:nil
                                                  error:&err];
    if (!p) {
        fprintf(stderr, "open failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
        return 2;
    }
    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];
    id<TTIOStorageDataset> ds = openDatasetAtPath(root, @(argv[3]), &err);
    if (!ds) {
        fprintf(stderr, "dataset open failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
        [p close];
        return 2;
    }
    NSData *canonical = [ds readCanonicalBytes:&err];
    if (!canonical) {
        fprintf(stderr, "canonical read failed\n");
        [p close];
        return 2;
    }
    // ML-DSA-87 v3: signature.
    NSData *sig = [TTIOPostQuantumCrypto sigSignWithPrivateKey:sk
                                                         message:canonical
                                                           error:&err];
    if (!sig) {
        fprintf(stderr, "sign failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
        [p close];
        return 2;
    }
    NSString *stored = [@"v3:" stringByAppendingString:
        [sig base64EncodedStringWithOptions:0]];
    BOOL ok = [ds setAttributeValue:stored forName:@"ttio_signature" error:&err];
    [p close];
    if (!ok) {
        fprintf(stderr, "setAttribute failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
        return 2;
    }
    return 0;
}

static int subProviderVerify(int argc, char **argv)
{
    if (argc < 5) { fprintf(stderr, "usage: provider-verify URL DS_PATH PK_IN\n"); return 2; }
    NSError *err = nil;
    NSData *pk = readBytes(@(argv[4]));
    id<TTIOStorageProvider> p =
        [[TTIOProviderRegistry sharedRegistry] openURL:@(argv[2])
                                                   mode:TTIOStorageOpenModeRead
                                               provider:nil
                                                  error:&err];
    if (!p) {
        fprintf(stderr, "open failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
        return 2;
    }
    id<TTIOStorageGroup> root = [p rootGroupWithError:&err];
    id<TTIOStorageDataset> ds = openDatasetAtPath(root, @(argv[3]), &err);
    if (!ds) {
        fprintf(stderr, "dataset open failed: %s\n",
                err.localizedDescription.UTF8String ?: "(unknown)");
        [p close];
        return 2;
    }
    NSData *canonical = [ds readCanonicalBytes:&err];
    id stored = [ds attributeValueForName:@"ttio_signature" error:&err];
    [p close];
    if (!stored) {
        fprintf(stderr, "no @ttio_signature\n");
        return 2;
    }
    NSString *s = [stored isKindOfClass:[NSString class]] ? stored : [stored description];
    if (![s hasPrefix:@"v3:"]) {
        fprintf(stderr, "stored signature is not v3\n");
        return 2;
    }
    NSString *b64 = [s substringFromIndex:3];
    NSData *sig = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    BOOL ok = [TTIOPostQuantumCrypto sigVerifyWithPublicKey:pk
                                                     message:canonical
                                                   signature:sig
                                                       error:&err];
    return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr,
                "usage: TtioPQCTool <subcommand> [args...]\n"
                "  sig-keygen  PK_OUT  SK_OUT\n"
                "  sig-sign    SK_IN   MSG_IN  SIG_OUT\n"
                "  sig-verify  PK_IN   MSG_IN  SIG_IN\n"
                "  kem-keygen  PK_OUT  SK_OUT\n"
                "  kem-encaps  PK_IN   CT_OUT  SS_OUT\n"
                "  kem-decaps  SK_IN   CT_IN   SS_OUT\n"
                "  hdf5-sign      FILE    DATASET_PATH  SK_IN\n"
                "  hdf5-verify    FILE    DATASET_PATH  PK_IN\n"
                "  provider-sign   URL     DATASET_PATH  SK_IN\n"
                "  provider-verify URL     DATASET_PATH  PK_IN\n");
            return 2;
        }
        NSString *sub = @(argv[1]);
        if ([sub isEqualToString:@"sig-keygen"]) return subKeygen(YES, argc, argv);
        if ([sub isEqualToString:@"kem-keygen"]) return subKeygen(NO,  argc, argv);
        if ([sub isEqualToString:@"sig-sign"])   return subSigSign(argc, argv);
        if ([sub isEqualToString:@"sig-verify"]) return subSigVerify(argc, argv);
        if ([sub isEqualToString:@"kem-encaps"]) return subKemEncaps(argc, argv);
        if ([sub isEqualToString:@"kem-decaps"]) return subKemDecaps(argc, argv);
        if ([sub isEqualToString:@"hdf5-sign"])   return subHdf5Sign(argc, argv);
        if ([sub isEqualToString:@"hdf5-verify"]) return subHdf5Verify(argc, argv);
        if ([sub isEqualToString:@"provider-sign"])   return subProviderSign(argc, argv);
        if ([sub isEqualToString:@"provider-verify"]) return subProviderVerify(argc, argv);
        fprintf(stderr, "unknown subcommand: %s\n", argv[1]);
        return 2;
    }
}
