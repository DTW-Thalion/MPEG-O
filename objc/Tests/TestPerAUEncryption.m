/*
 * TestPerAUEncryption — v1.0 per-AU encryption primitive tests.
 *
 * Mirrors python/tests/test_per_au_encryption.py. Covers AAD byte
 * layouts, primitive encrypt/decrypt, tamper detection, channel-
 * segment round-trip, and header-segment round-trip with position
 * binding.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <string.h>

#import "Protection/MPGOPerAUEncryption.h"
#import "Providers/MPGOCompoundField.h"
#import "Providers/MPGOStorageProtocols.h"
#import "Providers/MPGOHDF5Provider.h"

static NSData *makeKey(uint8_t byte)
{
    uint8_t buf[32];
    memset(buf, byte, 32);
    return [NSData dataWithBytes:buf length:32];
}

static NSData *dataOf(const void *bytes, NSUInteger len)
{
    return [NSData dataWithBytes:bytes length:len];
}


void testPerAUEncryption(void)
{
    NSData *key = makeKey(0x42);

    // ── 1. AAD byte layout ───────────────────────────────────────
    {
        NSData *aad = [MPGOPerAUEncryption aadForChannel:@"intensity"
                                                datasetId:1
                                               auSequence:42];
        const uint8_t expected[] = {
            0x01, 0x00,                          // dataset_id LE
            0x2a, 0x00, 0x00, 0x00,              // au_sequence LE
            'i','n','t','e','n','s','i','t','y'  // channel name
        };
        PASS(aad.length == sizeof(expected)
             && memcmp(aad.bytes, expected, sizeof(expected)) == 0,
             "AAD for channel matches spec");

        NSData *aadH = [MPGOPerAUEncryption aadForHeaderWithDatasetId:0x42
                                                            auSequence:0x1234];
        const uint8_t expH[] = {
            0x42, 0x00,
            0x34, 0x12, 0x00, 0x00,
            'h','e','a','d','e','r'
        };
        PASS(aadH.length == sizeof(expH)
             && memcmp(aadH.bytes, expH, sizeof(expH)) == 0,
             "AAD for header matches spec");

        NSData *aadP = [MPGOPerAUEncryption aadForPixelWithDatasetId:1
                                                           auSequence:0];
        const uint8_t expP[] = {
            0x01, 0x00,
            0x00, 0x00, 0x00, 0x00,
            'p','i','x','e','l'
        };
        PASS(aadP.length == sizeof(expP)
             && memcmp(aadP.bytes, expP, sizeof(expP)) == 0,
             "AAD for pixel matches spec");
    }

    // ── 2. Encrypt / decrypt with AAD ────────────────────────────
    {
        NSData *pt = [@"hello world" dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t fixedIV[12] = {0};
        NSData *iv = dataOf(fixedIV, 12);
        NSData *aad = [@"test-aad" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *tag = nil;
        NSError *err = nil;
        NSData *ct = [MPGOPerAUEncryption encryptWithPlaintext:pt
                                                             key:key iv:iv aad:aad
                                                          outTag:&tag error:&err];
        PASS(ct != nil && tag.length == 16, "encryptWithPlaintext produces ciphertext + 16-byte tag");

        NSData *plain = [MPGOPerAUEncryption decryptWithCiphertext:ct
                                                                key:key iv:iv tag:tag aad:aad
                                                              error:&err];
        PASS([plain isEqualToData:pt], "decryptWithCiphertext recovers plaintext");
    }

    // ── 3. Deterministic under fixed IV ─────────────────────────
    {
        NSData *pt = [@"identical" dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t fixedIV[12] = {0};
        NSData *iv = dataOf(fixedIV, 12);
        NSData *aad = [@"aad" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *tagA = nil, *tagB = nil;
        NSError *err = nil;
        NSData *ctA = [MPGOPerAUEncryption encryptWithPlaintext:pt
                                                              key:key iv:iv aad:aad
                                                           outTag:&tagA error:&err];
        NSData *ctB = [MPGOPerAUEncryption encryptWithPlaintext:pt
                                                              key:key iv:iv aad:aad
                                                           outTag:&tagB error:&err];
        PASS([ctA isEqualToData:ctB] && [tagA isEqualToData:tagB],
             "fixed IV + same plaintext + key + aad → deterministic");
    }

    // ── 4. Tamper / wrong AAD rejected ───────────────────────────
    {
        NSData *pt = [@"payload" dataUsingEncoding:NSUTF8StringEncoding];
        uint8_t fixedIV[12] = {0};
        NSData *iv = dataOf(fixedIV, 12);
        NSData *aadA = [@"aad-a" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *aadB = [@"aad-b" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *tag = nil;
        NSError *err = nil;
        NSData *ct = [MPGOPerAUEncryption encryptWithPlaintext:pt
                                                             key:key iv:iv aad:aadA
                                                          outTag:&tag error:&err];
        // Wrong AAD.
        err = nil;
        NSData *bad = [MPGOPerAUEncryption decryptWithCiphertext:ct
                                                               key:key iv:iv tag:tag aad:aadB
                                                             error:&err];
        PASS(bad == nil && err != nil, "wrong AAD rejected");

        // Flip tag byte.
        uint8_t *mutTag = malloc(16);
        memcpy(mutTag, tag.bytes, 16);
        mutTag[0] ^= 1;
        NSData *badTag = [NSData dataWithBytesNoCopy:mutTag length:16 freeWhenDone:YES];
        err = nil;
        bad = [MPGOPerAUEncryption decryptWithCiphertext:ct
                                                       key:key iv:iv tag:badTag aad:aadA
                                                     error:&err];
        PASS(bad == nil && err != nil, "tag-tamper rejected");
    }

    // ── 5. Channel segments round-trip ──────────────────────────
    {
        // 3 spectra × 4 float64 points = 96 bytes plaintext.
        double vals[12];
        for (int i = 0; i < 12; i++) vals[i] = 10.0 * i;
        NSData *plain = dataOf(vals, 96);
        uint64_t offsets[3] = {0, 4, 8};
        uint32_t lengths[3] = {4, 4, 4};
        NSError *err = nil;
        NSArray *segs = [MPGOPerAUEncryption encryptChannelToSegments:plain
                                                                 offsets:offsets
                                                                 lengths:lengths
                                                               nSpectra:3
                                                              datasetId:1
                                                            channelName:@"intensity"
                                                                    key:key
                                                                  error:&err];
        PASS(segs != nil && segs.count == 3, "encryptChannelToSegments produces 3 rows");
        MPGOChannelSegment *s0 = segs[0];
        PASS(s0.iv.length == 12 && s0.tag.length == 16 && s0.ciphertext.length == 32,
             "per-row sizes: iv=12, tag=16, ct=32 bytes for 4 float64");

        NSData *recovered = [MPGOPerAUEncryption decryptChannelFromSegments:segs
                                                                   datasetId:1
                                                                 channelName:@"intensity"
                                                                         key:key
                                                                       error:&err];
        PASS([recovered isEqualToData:plain], "decryptChannelFromSegments recovers plaintext");
    }

    // ── 6. Row swap rejected (AAD binds to au_sequence) ─────────
    {
        double vals[8] = {1, 2, 3, 4, 5, 6, 7, 8};
        NSData *plain = dataOf(vals, 64);
        uint64_t offsets[2] = {0, 4};
        uint32_t lengths[2] = {4, 4};
        NSError *err = nil;
        NSArray *segs = [MPGOPerAUEncryption encryptChannelToSegments:plain
                                                                 offsets:offsets
                                                                 lengths:lengths
                                                               nSpectra:2
                                                              datasetId:1
                                                            channelName:@"mz"
                                                                    key:key
                                                                  error:&err];
        NSArray *swapped = @[segs[1], segs[0]];
        err = nil;
        NSData *bad = [MPGOPerAUEncryption decryptChannelFromSegments:swapped
                                                             datasetId:1
                                                           channelName:@"mz"
                                                                   key:key
                                                                 error:&err];
        PASS(bad == nil && err != nil, "swapped segments rejected");
    }

    // ── 7. Header segments pack/unpack + round-trip ────────────
    {
        MPGOAUHeaderPlaintext *h = [[MPGOAUHeaderPlaintext alloc] init];
        h.acquisitionMode = 1;
        h.msLevel = 2;
        h.polarity = 1;
        h.retentionTime = 123.456;
        h.precursorMz = 500.25;
        h.precursorCharge = 2;
        h.ionMobility = 0.987;
        h.basePeakIntensity = 1.0e6;
        NSData *packed = [MPGOPerAUEncryption packAUHeaderPlaintext:h];
        PASS(packed.length == 36, "semantic header packs to 36 bytes");

        MPGOAUHeaderPlaintext *back = [MPGOPerAUEncryption unpackAUHeaderPlaintext:packed];
        PASS(back.acquisitionMode == 1 && back.msLevel == 2 && back.polarity == 1,
             "u8 fields round-trip");
        PASS(back.retentionTime == 123.456 && back.precursorMz == 500.25
             && back.basePeakIntensity == 1.0e6 && back.ionMobility == 0.987,
             "f64 fields round-trip");
        PASS(back.precursorCharge == 2, "precursor_charge round-trips");

        NSError *err = nil;
        NSArray *segs = [MPGOPerAUEncryption encryptHeaderSegments:@[h, h]
                                                            datasetId:1
                                                                  key:key
                                                                error:&err];
        PASS(segs != nil && segs.count == 2, "encryptHeaderSegments produces 2 rows");
        MPGOHeaderSegment *hs = segs[0];
        PASS(hs.ciphertext.length == 36 && hs.iv.length == 12 && hs.tag.length == 16,
             "header segment sizes: 36 ct / 12 iv / 16 tag");

        NSArray *backRows = [MPGOPerAUEncryption decryptHeaderSegments:segs
                                                              datasetId:1
                                                                    key:key
                                                                  error:&err];
        PASS(backRows != nil && backRows.count == 2, "decryptHeaderSegments round-trips");
        MPGOAUHeaderPlaintext *r0 = backRows[0];
        PASS(r0.msLevel == 2 && r0.precursorMz == 500.25,
             "header row decrypt preserves fields");
    }

    // ── 8. VL_BYTES compound through provider abstraction ───────
    {
        NSString *path = [NSString stringWithFormat:@"/tmp/mpgo_vlbytes_%d.h5",
                          (int)getpid()];
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];

        MPGOHDF5Provider *prov = [[MPGOHDF5Provider alloc] init];
        NSError *err = nil;
        BOOL opened = [prov openURL:path
                                 mode:MPGOStorageOpenModeCreate
                                error:&err];
        PASS(opened, "HDF5 provider opens for create");

        id<MPGOStorageGroup> root = [prov rootGroupWithError:&err];
        NSArray *fields = @[
            [MPGOCompoundField fieldWithName:@"offset" kind:MPGOCompoundFieldKindInt64],
            [MPGOCompoundField fieldWithName:@"length" kind:MPGOCompoundFieldKindUInt32],
            [MPGOCompoundField fieldWithName:@"iv" kind:MPGOCompoundFieldKindVLBytes],
            [MPGOCompoundField fieldWithName:@"tag" kind:MPGOCompoundFieldKindVLBytes],
            [MPGOCompoundField fieldWithName:@"ciphertext" kind:MPGOCompoundFieldKindVLBytes],
        ];
        id<MPGOStorageDataset> ds =
            [root createCompoundDatasetNamed:@"segments"
                                        fields:fields
                                         count:2
                                         error:&err];
        PASS(ds != nil, "createCompoundDataset with VL_BYTES returns handle");

        uint8_t ivA[12]; memset(ivA, 0x11, 12);
        uint8_t tagA[16]; memset(tagA, 0x22, 16);
        uint8_t ctA[32]; memset(ctA, 0x33, 32);
        uint8_t ivB[12]; memset(ivB, 0x44, 12);
        uint8_t tagB[16]; memset(tagB, 0x55, 16);
        uint8_t ctB[48]; memset(ctB, 0x66, 48);
        NSArray *rows = @[
            @{@"offset": @(0), @"length": @(4),
              @"iv": [NSData dataWithBytes:ivA length:12],
              @"tag": [NSData dataWithBytes:tagA length:16],
              @"ciphertext": [NSData dataWithBytes:ctA length:32]},
            @{@"offset": @(4), @"length": @(6),
              @"iv": [NSData dataWithBytes:ivB length:12],
              @"tag": [NSData dataWithBytes:tagB length:16],
              @"ciphertext": [NSData dataWithBytes:ctB length:48]},
        ];
        BOOL wrote = [ds writeAll:rows error:&err];
        PASS(wrote, "writeAll with VL_BYTES rows succeeds");

        NSArray<NSDictionary *> *back = [ds readRows:&err];
        PASS(back.count == 2, "readRows returns 2 rows");
        PASS([back[0][@"offset"] longLongValue] == 0
             && [back[0][@"length"] unsignedIntValue] == 4,
             "row 0 scalar fields preserved");
        NSData *ivBack = back[0][@"iv"];
        NSData *ctBack0 = back[0][@"ciphertext"];
        PASS(ivBack.length == 12
             && [ivBack isEqualToData:[NSData dataWithBytes:ivA length:12]],
             "row 0 iv VL_BYTES preserved bit-for-bit");
        PASS(ctBack0.length == 32
             && [ctBack0 isEqualToData:[NSData dataWithBytes:ctA length:32]],
             "row 0 ciphertext VL_BYTES preserved bit-for-bit");
        NSData *ctBack1 = back[1][@"ciphertext"];
        PASS(ctBack1.length == 48
             && [ctBack1 isEqualToData:[NSData dataWithBytes:ctB length:48]],
             "row 1 ciphertext (different length) preserved");

        // MPGOHDF5Provider doesn't expose closeWithError: — rely on
        // dealloc to close the file handle.
        prov = nil;
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
}
