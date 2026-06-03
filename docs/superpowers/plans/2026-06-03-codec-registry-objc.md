# Codec Registry — Objective-C Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the codec registry (Python PR #209, Java PR #210) to Objective-C: a `TTIOCodec` `@protocol` + `TTIOCodecRegistry` singleton + abstract-class-cluster unions, collapsing the decode switch + 5 side-paths and routing both encode bodies through the registry — with **zero wire/format change and zero embed-behavior change**.

**Architecture:** New ARC group `objc/Source/Codecs/Registry/`: union clusters (`TTIODecodedChannel`/`TTIOEncodedChannel`/`TTIOChannelPayload` + subclasses), `TTIOCodecContext` value object, `TTIOCodec` protocol, `TTIOCodecRegistry` (`NSDictionary<NSNumber*,id<TTIOCodec>>`, `pthread_once`). Thin adapters wrap the existing free C functions + smart-codec class methods verbatim.

**Tech Stack:** Objective-C + GNUstep + clang (`-fobjc-arc`), GNUstep `Testing.h`. Build/test in WSL: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/objc && ./build.sh check'`. Push from Windows git. Spec: `docs/superpowers/specs/2026-06-03-codec-registry-objc-design.md`.

**Branch:** `feat/codec-registry-objc` (created off `main`; spec committed on it).

**Invariant (every task):** existing ObjC codec/genomic tests + the cross-language `Fixtures/*.bin` byte-equality fences stay green. Wire id = the explicit `TTIOCompression` value; codec byte streams unchanged. ARC is ON — no manual retain/release.

---

## Reference facts (verified)

- New package `objc/Source/Codecs/Registry/`. ObjC codec classes are under `objc/Source/Codecs/`.
- `TTIOCompression` (`ValueClasses/TTIOEnums.h`) NS_ENUM, explicit = wire id: `TTIOCompressionRansOrder0`=4, `…RansOrder1`=5, `…BasePack`=6, `…QualityBinned`=7, `…DeltaRansOrder0`=11, `…FqzcompNx16Z`=12, `…MateInlineV2`=13, `…RefDiffV2`=14, `…NameTokenizedV2`=15. (Confirm exact constant spellings in TTIOEnums.h.)
- Free C codec fns: `NSData *TTIORansEncode(NSData *data, int order)`; `NSData *TTIORansDecode(NSData *encoded, NSError **)`; `NSData *TTIOBasePackEncode(NSData*)` / `TTIOBasePackDecode(NSData*, NSError**)`; `NSData *TTIOQualityEncode(NSData*)` / `TTIOQualityDecode(NSData*, NSError**)`; `NSData *TTIODeltaRansEncode(NSData*, uint8_t elementSize, NSError**)` / `TTIODeltaRansDecode(NSData*, NSError**)`.
- Smart codec class methods:
  - `+[TTIONameTokenizerV2 encodeNames:(NSArray<NSString*>*)] -> NSData*` ; `+[… decodeData:(NSData*)blob error:(NSError**)] -> NSArray<NSString*>*`.
  - `+[TTIOFqzcompNx16Z encodeWithQualities:(NSData*)q readLengths:(NSArray<NSNumber*>*)rl revcompFlags:(NSArray<NSNumber*>*)rc error:] -> NSData*` ; `+[… decodeData:(NSData*)d revcompFlags:(NSArray<NSNumber*>*)rc error:] -> NSDictionary*` with keys `@"qualities"` (NSData) + `@"readLengths"` (NSArray). (Confirm `readLengths`/`revcompFlags` param types — NSArray<NSNumber*> vs NSData — by reading the header.)
  - `+[TTIOMateInfoV2 encodeMateChromIds:(NSData*)mc matePositions:(NSData*)mp templateLengths:(NSData*)tl ownChromIds:(NSData*)oc ownPositions:(NSData*)op error:] -> NSData*` ; `+[… decodeData:(NSData*)d ownChromIds:(NSData*)oc ownPositions:(NSData*)op nRecords:(NSUInteger)n outMateChromIds:(NSData**)... outMatePositions:(NSData**)... outTemplateLengths:(NSData**)... error:] -> BOOL`. (Confirm exact param types/order.)
  - `+[TTIORefDiffV2 encodeSequences:offsets:positions:cigarStrings:reference:referenceMd5:referenceUri:readsPerSlice:error:] -> NSData*` ; `+[… decodeData:positions:cigarStrings:reference:nReads:totalBases:outSequences:(NSData**) outOffsets:(NSData**) error:] -> BOOL`. There is NO `parseBlobHeader` class method — the blob-header parse + reference resolve lives inline in `-_decodeRefDiffV2Sequences`.
  - Each smart codec: `+ (BOOL)nativeAvailable;` returns nil+error when native absent.
- `TTIOReferenceResolver` (`Codecs/TTIOReferenceResolver.h`): `-initWithRootGroup:(TTIOHDF5Group*)rootGroup …`; `-resolveURI:(NSString*)uri … -> NSData*` (confirm full selector incl. md5/chromosome args).
- `TTIOGenomicIndex` (`Genomics/TTIOGenomicIndex.h`): `@property (readonly) NSUInteger count;` `-offsetAt:`(uint64), `-lengthAt:`(uint32), `-positionAt:`(int64), `-flagsAt:`(uint32), `-chromosomeAt:`(NSString) — all `(NSUInteger)index`.
- `id<TTIOStorageGroup>` (`Providers/TTIOStorageProtocols.h:222`).
- `TTIOGenomicRun.m`: decode switch in `-byteChannelSliceNamed:offset:count:error:` at `:346`; bespoke `-_decodeRefDiffV2Sequences:error:` (`:956`), `-_ttio_m94z_decodeFqzcompNx16Z:error:` (`:406`), `-readNameAtIndex:error:` (`:443`), `-cigarAtIndex:error:` (`:618`), `-_decodeMateInfoInlineV2:error:` (`:1112`).
- `TTIOSpectralDataset.m`: byte-stream `_TTIO_M86_EncodeWithCodec` (`:403`); HDF5 encode body (`:2071-2238`), storage encode body (`:2483-2714`); embed predicate `_TTIO_V18_UseRefDiffV2` (`:1749`).
- Build: GNUstep is NOT auto-discovery — new `.m` go in `objc/Source/GNUmakefile` (`libTTIO_OBJC_FILES`, headers in `libTTIO_HEADER_FILES` ~`:126-134`); the test goes in `objc/Tests/GNUmakefile` + `objc/Tests/TTIOTestRunner.m` (`extern void testX(void);` decl + a `START_SET("…") testX(); END_SET("…")` call in `main()`).
- `./build.sh check` post-parses GNUstep Testing output and fails on any reported failure.

---

## File structure

| File | Change |
|---|---|
| `Codecs/Registry/TTIODecodedChannel.{h,m}` | Create — decode union cluster |
| `Codecs/Registry/TTIOEncodedChannel.{h,m}` | Create — encode union cluster |
| `Codecs/Registry/TTIOChannelPayload.{h,m}` | Create — payload union cluster |
| `Codecs/Registry/TTIOCodecContext.{h,m}` | Create — context value object |
| `Codecs/Registry/TTIOCodec.h` | Create — protocol |
| `Codecs/Registry/TTIOCodecRegistry.{h,m}` | Create — registry + adapters |
| `Genomics/TTIOGenomicRun.m` | Modify — `-_codecContext` + route decode |
| `Dataset/TTIOSpectralDataset.m` | Modify — route both encode bodies |
| `Tests/TestCodecRegistry.m` | Create — registry tests |
| `Tests/TTIOTestRunner.m` | Modify — register test |
| `objc/Source/GNUmakefile`, `objc/Tests/GNUmakefile` | Modify — add sources/test |
| `CHANGELOG.md` | Modify — `[Unreleased]` |

---

## Task 1: Union class clusters + build wiring + test skeleton

**Files:** Create the 3 union `{h,m}` pairs; modify `objc/Source/GNUmakefile`; create `Tests/TestCodecRegistry.m`; modify `objc/Tests/GNUmakefile` + `Tests/TTIOTestRunner.m`.

- [ ] **Step 1: Create `Codecs/Registry/TTIODecodedChannel.h`**

```objc
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/** Closed union of a decoded channel value: bytes | str-list | mate-info.
 *  Consumed via isKindOfClass:. Mirrors the Python/Java DecodedChannel. */
@interface TTIODecodedChannel : NSObject
@end

@interface TTIODecodedBytes : TTIODecodedChannel
@property (readonly, copy) NSData *data;
- (instancetype)initWithData:(NSData *)data;
@end

@interface TTIODecodedStringList : TTIODecodedChannel
@property (readonly, copy) NSArray<NSString *> *names;
- (instancetype)initWithNames:(NSArray<NSString *> *)names;
@end

@interface TTIODecodedMateInfo : TTIODecodedChannel
@property (readonly, copy) NSData *mateChromIds;
@property (readonly, copy) NSData *matePositions;
@property (readonly, copy) NSData *templateLengths;
- (instancetype)initWithMateChromIds:(NSData *)mateChromIds
                       matePositions:(NSData *)matePositions
                     templateLengths:(NSData *)templateLengths;
@end

NS_ASSUME_NONNULL_END
```

> Note: `TTIODecodedMateInfo` uses `NSData` for all three (the `+[TTIOMateInfoV2 decode…]` out-params are `NSData`). Confirm against the codec header in Task 4; if mate out-params are `NSArray<NSNumber*>`, change these property types to match before Task 4.

`Codecs/Registry/TTIODecodedChannel.m`:
```objc
#import "TTIODecodedChannel.h"

@implementation TTIODecodedChannel
@end

@implementation TTIODecodedBytes
- (instancetype)initWithData:(NSData *)data {
    if ((self = [super init])) { _data = [data copy]; }
    return self;
}
@end

@implementation TTIODecodedStringList
- (instancetype)initWithNames:(NSArray<NSString *> *)names {
    if ((self = [super init])) { _names = [names copy]; }
    return self;
}
@end

@implementation TTIODecodedMateInfo
- (instancetype)initWithMateChromIds:(NSData *)mateChromIds
                       matePositions:(NSData *)matePositions
                     templateLengths:(NSData *)templateLengths {
    if ((self = [super init])) {
        _mateChromIds = [mateChromIds copy];
        _matePositions = [matePositions copy];
        _templateLengths = [templateLengths copy];
    }
    return self;
}
@end
```

- [ ] **Step 2: Create `Codecs/Registry/TTIOEncodedChannel.{h,m}`**

`.h`:
```objc
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/** Closed union of encode output: a flat dataset blob or a group layout (ref_diff). */
@interface TTIOEncodedChannel : NSObject
@end

@interface TTIOEncodedDatasetBytes : TTIOEncodedChannel
@property (readonly, copy) NSData *bytes;
- (instancetype)initWithBytes:(NSData *)bytes;
@end

@interface TTIOEncodedGroupLayout : TTIOEncodedChannel
@property (readonly, copy) NSDictionary<NSString *, NSData *> *children;
@property (readonly, copy) NSDictionary<NSString *, id> *attrs;
- (instancetype)initWithChildren:(NSDictionary<NSString *, NSData *> *)children
                           attrs:(NSDictionary<NSString *, id> *)attrs;
@end

NS_ASSUME_NONNULL_END
```

`.m`:
```objc
#import "TTIOEncodedChannel.h"

@implementation TTIOEncodedChannel
@end

@implementation TTIOEncodedDatasetBytes
- (instancetype)initWithBytes:(NSData *)bytes {
    if ((self = [super init])) { _bytes = [bytes copy]; }
    return self;
}
@end

@implementation TTIOEncodedGroupLayout
- (instancetype)initWithChildren:(NSDictionary<NSString *, NSData *> *)children
                           attrs:(NSDictionary<NSString *, id> *)attrs {
    if ((self = [super init])) { _children = [children copy]; _attrs = [attrs copy]; }
    return self;
}
@end
```

- [ ] **Step 3: Create `Codecs/Registry/TTIOChannelPayload.{h,m}`**

`.h`:
```objc
#import <Foundation/Foundation.h>
#import "Providers/TTIOStorageProtocols.h"
NS_ASSUME_NONNULL_BEGIN

/** Encoded payload: either flat dataset bytes or a storage group (ref_diff). */
@interface TTIOChannelPayload : NSObject
@end

@interface TTIOBytesPayload : TTIOChannelPayload
@property (readonly, copy) NSData *bytes;
- (instancetype)initWithBytes:(NSData *)bytes;
@end

@interface TTIOGroupPayload : TTIOChannelPayload
@property (readonly, strong) id<TTIOStorageGroup> group;
- (instancetype)initWithGroup:(id<TTIOStorageGroup>)group;
@end

NS_ASSUME_NONNULL_END
```
> Confirm the `#import` path for `TTIOStorageProtocols.h` (it may need to be `#import "../../Providers/TTIOStorageProtocols.h"` or an angle-bracket framework import — match how other Codecs/*.m import providers).

`.m`:
```objc
#import "TTIOChannelPayload.h"

@implementation TTIOChannelPayload
@end

@implementation TTIOBytesPayload
- (instancetype)initWithBytes:(NSData *)bytes {
    if ((self = [super init])) { _bytes = [bytes copy]; }
    return self;
}
@end

@implementation TTIOGroupPayload
- (instancetype)initWithGroup:(id<TTIOStorageGroup>)group {
    if ((self = [super init])) { _group = group; }
    return self;
}
@end
```

- [ ] **Step 4: Wire the new sources into `objc/Source/GNUmakefile`.** Add the 3 headers to `libTTIO_HEADER_FILES` (near the `Codecs/…` block ~`:126`) and the 3 `.m` to `libTTIO_OBJC_FILES` (`:136`):
```
	Codecs/Registry/TTIODecodedChannel.h \
	Codecs/Registry/TTIOEncodedChannel.h \
	Codecs/Registry/TTIOChannelPayload.h \
```
```
	Codecs/Registry/TTIODecodedChannel.m \
	Codecs/Registry/TTIOEncodedChannel.m \
	Codecs/Registry/TTIOChannelPayload.m \
```
(Match the existing `\`-continuation + tab indentation exactly.)

- [ ] **Step 5: Create `Tests/TestCodecRegistry.m`** (skeleton with union tests) and register it.

`Tests/TestCodecRegistry.m`:
```objc
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Codecs/Registry/TTIODecodedChannel.h"
#import "Codecs/Registry/TTIOEncodedChannel.h"
#import "Codecs/Registry/TTIOChannelPayload.h"

void testCodecRegistry(void)
{
    @autoreleasepool {
        // Union variant identity.
        TTIODecodedChannel *d =
            [[TTIODecodedBytes alloc] initWithData:[NSData dataWithBytes:"abc" length:3]];
        PASS([d isKindOfClass:[TTIODecodedBytes class]],
             "TTIODecodedBytes is a TTIODecodedChannel");
        PASS([((TTIODecodedBytes *)d).data length] == 3, "decoded bytes length");

        TTIODecodedChannel *s =
            [[TTIODecodedStringList alloc] initWithNames:@[@"r1", @"r2"]];
        PASS([((TTIODecodedStringList *)s).names count] == 2, "decoded str-list");

        TTIOEncodedChannel *e =
            [[TTIOEncodedDatasetBytes alloc] initWithBytes:[NSData dataWithBytes:"x" length:1]];
        PASS([e isKindOfClass:[TTIOEncodedDatasetBytes class]], "encoded dataset-bytes");

        TTIOEncodedChannel *g =
            [[TTIOEncodedGroupLayout alloc]
                initWithChildren:@{@"refdiff_v2": [NSData data]} attrs:@{}];
        PASS([((TTIOEncodedGroupLayout *)g).children objectForKey:@"refdiff_v2"] != nil,
             "encoded group-layout child");

        TTIOChannelPayload *p =
            [[TTIOBytesPayload alloc] initWithBytes:[NSData dataWithBytes:"q" length:1]];
        PASS([((TTIOBytesPayload *)p).bytes length] == 1, "bytes payload");
    }
}
```

Register: in `objc/Tests/TTIOTestRunner.m`, add `extern void testCodecRegistry(void);` with the other externs, and in `main()` add (matching the existing `START_SET/END_SET` style):
```objc
    START_SET("codec registry")
        testCodecRegistry();
    END_SET("codec registry")
```
Add `TestCodecRegistry.m` to the test sources in `objc/Tests/GNUmakefile` (find where `TestM86GenomicCodecWiring.m` etc. are listed and append).

- [ ] **Step 6: Build + run**

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/objc && ./build.sh check 2>&1 | tail -25'`
Expected: builds; the `codec registry` set passes (6 PASS lines); no failures.

- [ ] **Step 7: Commit**

```bash
git -C ~/TTI-O add objc/Source/Codecs/Registry objc/Source/GNUmakefile objc/Tests/TestCodecRegistry.m objc/Tests/TTIOTestRunner.m objc/Tests/GNUmakefile && git -C ~/TTI-O commit -m "feat(objc-codecs): codec-registry union class clusters + build wiring"
```

---

## Task 2: `TTIOCodecContext` + `TTIOCodec` protocol

**Files:** Create `Codecs/Registry/TTIOCodecContext.{h,m}` + `TTIOCodec.h`; add to GNUmakefile.

- [ ] **Step 1: Create `TTIOCodecContext.h`** (immutable value object; all-optional fields)

```objc
#import <Foundation/Foundation.h>
#import "Codecs/TTIOReferenceResolver.h"
NS_ASSUME_NONNULL_BEGIN

/** Run-derived context for codecs. All fields optional/nullable; plain codecs ignore it. */
@interface TTIOCodecContext : NSObject
@property (nullable, strong) NSArray<NSNumber *> *readLengths;     // fqzcomp
@property (nullable, strong) NSArray<NSNumber *> *revcompFlags;    // fqzcomp
@property (nullable, strong) NSNumber *elementSize;               // delta encode
@property (nullable, strong) NSNumber *readCount;
@property (nullable, strong) NSData *positions;                  // int64-LE
@property (nullable, copy)   NSArray<NSString *> *(^cigarsProvider)(void);  // lazy thunk
@property (nullable, strong) NSNumber *totalBases;
@property (nullable, strong) NSArray<NSString *> *chromosomes;
@property (nullable, strong) NSData *ownChromIds;                // mate_info
@property (nullable, strong) NSData *ownPositions;               // mate_info
@property (nullable, strong) NSNumber *nRecords;
@property (nullable, strong) TTIOReferenceResolver *referenceResolver;
// encode-only (ref_diff):
@property (nullable, strong) NSData *offsets;
@property (nullable, strong) NSData *reference;
@property (nullable, strong) NSData *referenceMd5;
@property (nullable, strong) NSString *referenceUri;
@property (nullable, strong) NSNumber *readsPerSlice;

+ (instancetype)emptyContext;
@end

NS_ASSUME_NONNULL_END
```
> The codec methods may want `readLengths`/`revcompFlags` as `NSArray<NSNumber*>` or `NSData`/`int[]` — match what `+[TTIOFqzcompNx16Z]` actually takes (verified in Task 4). Adjust these property types accordingly before Task 4 (keep the names).

`.m`:
```objc
#import "TTIOCodecContext.h"
@implementation TTIOCodecContext
+ (instancetype)emptyContext { return [[self alloc] init]; }
@end
```

- [ ] **Step 2: Create `TTIOCodec.h`** (protocol)

```objc
#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"
#import "Codecs/Registry/TTIOChannelPayload.h"
#import "Codecs/Registry/TTIODecodedChannel.h"
#import "Codecs/Registry/TTIOEncodedChannel.h"
#import "Codecs/Registry/TTIOCodecContext.h"
NS_ASSUME_NONNULL_BEGIN

@protocol TTIOCodec <NSObject>
- (TTIOCompression)codecId;
- (BOOL)isContextAware;
- (BOOL)needsEmbeddedReference;
- (nullable TTIODecodedChannel *)decode:(TTIOChannelPayload *)payload
                                context:(TTIOCodecContext *)ctx
                                  error:(NSError **)error;
- (nullable TTIOEncodedChannel *)encode:(TTIODecodedChannel *)value
                                context:(TTIOCodecContext *)ctx
                                  error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
```
> Confirm the `#import` paths for `TTIOEnums.h` / `TTIOReferenceResolver.h` match how other files in the lib import them (the lib uses header-search paths — likely `#import "ValueClasses/TTIOEnums.h"`).

- [ ] **Step 3: Wire into `objc/Source/GNUmakefile`** — add `TTIOCodecContext.h`, `TTIOCodec.h` to headers; `TTIOCodecContext.m` to `_OBJC_FILES`.

- [ ] **Step 4: Build (no new test needed yet)**

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/objc && ./build.sh check 2>&1 | tail -15'` — expect green (compiles; existing tests pass).

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add objc/Source/Codecs/Registry/TTIOCodecContext.h objc/Source/Codecs/Registry/TTIOCodecContext.m objc/Source/Codecs/Registry/TTIOCodec.h objc/Source/GNUmakefile && git -C ~/TTI-O commit -m "feat(objc-codecs): TTIOCodecContext + TTIOCodec protocol"
```

---

## Task 3: `TTIOCodecRegistry` + plain adapters

**Files:** Create `Codecs/Registry/TTIOCodecRegistry.{h,m}`; add to GNUmakefile; extend `TestCodecRegistry.m`.

- [ ] **Step 1: Add tests** — append to `testCodecRegistry()` in `Tests/TestCodecRegistry.m` (add `#import "Codecs/Registry/TTIOCodecRegistry.h"` + `#import "Codecs/Registry/TTIOCodec.h"`):

```objc
        // Plain round-trip via registry (RANS0/1, BASE_PACK — lossless).
        TTIOCompression plain[3] = {TTIOCompressionRansOrder0,
                                    TTIOCompressionRansOrder1,
                                    TTIOCompressionBasePack};
        for (int k = 0; k < 3; k++) {
            id<TTIOCodec> codec = [TTIOCodecRegistry codecForId:plain[k]];
            PASS(codec != nil, "plain codec registered: %d", (int)plain[k]);
            PASS([codec codecId] == plain[k], "codecId matches");
            PASS(![codec isContextAware], "plain codec not context-aware");
            uint8_t buf[256]; for (int i = 0; i < 256; i++) buf[i] = (uint8_t)i;
            NSData *data = [NSData dataWithBytes:buf length:256];
            NSError *err = nil;
            TTIOEncodedChannel *enc =
                [codec encode:[[TTIODecodedBytes alloc] initWithData:data]
                      context:[TTIOCodecContext emptyContext] error:&err];
            NSData *encBytes = ((TTIOEncodedDatasetBytes *)enc).bytes;
            TTIODecodedChannel *dec =
                [codec decode:[[TTIOBytesPayload alloc] initWithBytes:encBytes]
                      context:[TTIOCodecContext emptyContext] error:&err];
            PASS([((TTIODecodedBytes *)dec).data isEqualToData:data],
                 "plain codec round-trip byte-identical: %d", (int)plain[k]);
        }
        // delta needs elementSize.
        id<TTIOCodec> delta = [TTIOCodecRegistry codecForId:TTIOCompressionDeltaRansOrder0];
        PASS(delta != nil, "delta registered");
        NSError *derr = nil;
        TTIOEncodedChannel *de =
            [delta encode:[[TTIODecodedBytes alloc] initWithData:[NSData dataWithBytes:"\0\0\0\0" length:4]]
                  context:[TTIOCodecContext emptyContext] error:&derr];
        PASS(de == nil && derr != nil, "delta encode without elementSize errors");
```

- [ ] **Step 2: Build to verify FAIL** (`TTIOCodecRegistry` undefined). `./build.sh check 2>&1 | tail -20`.

- [ ] **Step 3: Create `TTIOCodecRegistry.h`**

```objc
#import <Foundation/Foundation.h>
#import "ValueClasses/TTIOEnums.h"
#import "Codecs/Registry/TTIOCodec.h"
NS_ASSUME_NONNULL_BEGIN

@interface TTIOCodecRegistry : NSObject
/** The codec for a wire id, or nil for unregistered/reserved ids (membership-safe). */
+ (nullable id<TTIOCodec>)codecForId:(TTIOCompression)codecId;
@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 4: Create `TTIOCodecRegistry.m`** with plain adapters + the `pthread_once` registry

```objc
#import "TTIOCodecRegistry.h"
#import "Codecs/TTIORans.h"
#import "Codecs/TTIOBasePack.h"
#import "Codecs/TTIOQuality.h"
#import "Codecs/TTIODeltaRans.h"
#import <pthread.h>

static NSDictionary<NSNumber *, id<TTIOCodec>> *gRegistry = nil;
static pthread_once_t gOnce = PTHREAD_ONCE_INIT;

// --- plain adapters ---

@interface _TTIORansCodec : NSObject <TTIOCodec>
- (instancetype)initWithId:(TTIOCompression)cid order:(int)order;
@end
@implementation _TTIORansCodec {
    TTIOCompression _cid; int _order;
}
- (instancetype)initWithId:(TTIOCompression)cid order:(int)order {
    if ((self = [super init])) { _cid = cid; _order = order; }
    return self;
}
- (TTIOCompression)codecId { return _cid; }
- (BOOL)isContextAware { return NO; }
- (BOOL)needsEmbeddedReference { return NO; }
- (TTIODecodedChannel *)decode:(TTIOChannelPayload *)p context:(TTIOCodecContext *)ctx error:(NSError **)e {
    NSData *out = TTIORansDecode(((TTIOBytesPayload *)p).bytes, e);
    return out ? [[TTIODecodedBytes alloc] initWithData:out] : nil;
}
- (TTIOEncodedChannel *)encode:(TTIODecodedChannel *)v context:(TTIOCodecContext *)ctx error:(NSError **)e {
    NSData *out = TTIORansEncode(((TTIODecodedBytes *)v).data, _order);
    return [[TTIOEncodedDatasetBytes alloc] initWithBytes:out];
}
@end

@interface _TTIOBasePackCodec : NSObject <TTIOCodec> @end
@implementation _TTIOBasePackCodec
- (TTIOCompression)codecId { return TTIOCompressionBasePack; }
- (BOOL)isContextAware { return NO; }
- (BOOL)needsEmbeddedReference { return NO; }
- (TTIODecodedChannel *)decode:(TTIOChannelPayload *)p context:(TTIOCodecContext *)ctx error:(NSError **)e {
    NSData *out = TTIOBasePackDecode(((TTIOBytesPayload *)p).bytes, e);
    return out ? [[TTIODecodedBytes alloc] initWithData:out] : nil;
}
- (TTIOEncodedChannel *)encode:(TTIODecodedChannel *)v context:(TTIOCodecContext *)ctx error:(NSError **)e {
    return [[TTIOEncodedDatasetBytes alloc] initWithBytes:TTIOBasePackEncode(((TTIODecodedBytes *)v).data)];
}
@end

@interface _TTIOQualityCodec : NSObject <TTIOCodec> @end
@implementation _TTIOQualityCodec
- (TTIOCompression)codecId { return TTIOCompressionQualityBinned; }
- (BOOL)isContextAware { return NO; }
- (BOOL)needsEmbeddedReference { return NO; }
- (TTIODecodedChannel *)decode:(TTIOChannelPayload *)p context:(TTIOCodecContext *)ctx error:(NSError **)e {
    NSData *out = TTIOQualityDecode(((TTIOBytesPayload *)p).bytes, e);
    return out ? [[TTIODecodedBytes alloc] initWithData:out] : nil;
}
- (TTIOEncodedChannel *)encode:(TTIODecodedChannel *)v context:(TTIOCodecContext *)ctx error:(NSError **)e {
    return [[TTIOEncodedDatasetBytes alloc] initWithBytes:TTIOQualityEncode(((TTIODecodedBytes *)v).data)];
}
@end

@interface _TTIODeltaRansCodec : NSObject <TTIOCodec> @end
@implementation _TTIODeltaRansCodec
- (TTIOCompression)codecId { return TTIOCompressionDeltaRansOrder0; }
- (BOOL)isContextAware { return NO; }
- (BOOL)needsEmbeddedReference { return NO; }
- (TTIODecodedChannel *)decode:(TTIOChannelPayload *)p context:(TTIOCodecContext *)ctx error:(NSError **)e {
    NSData *out = TTIODeltaRansDecode(((TTIOBytesPayload *)p).bytes, e);
    return out ? [[TTIODecodedBytes alloc] initWithData:out] : nil;
}
- (TTIOEncodedChannel *)encode:(TTIODecodedChannel *)v context:(TTIOCodecContext *)ctx error:(NSError **)e {
    if (ctx.elementSize == nil) {
        if (e) *e = [NSError errorWithDomain:@"global.thalion.ttio.CodecRegistry" code:-1
            userInfo:@{NSLocalizedDescriptionKey: @"DELTA_RANS encode requires context.elementSize"}];
        return nil;
    }
    NSData *out = TTIODeltaRansEncode(((TTIODecodedBytes *)v).data,
        (uint8_t)ctx.elementSize.unsignedCharValue, e);
    return out ? [[TTIOEncodedDatasetBytes alloc] initWithBytes:out] : nil;
}
@end

static void _buildRegistry(void) {
    gRegistry = @{
        @(TTIOCompressionRansOrder0): [[_TTIORansCodec alloc] initWithId:TTIOCompressionRansOrder0 order:0],
        @(TTIOCompressionRansOrder1): [[_TTIORansCodec alloc] initWithId:TTIOCompressionRansOrder1 order:1],
        @(TTIOCompressionBasePack):   [[_TTIOBasePackCodec alloc] init],
        @(TTIOCompressionQualityBinned): [[_TTIOQualityCodec alloc] init],
        @(TTIOCompressionDeltaRansOrder0): [[_TTIODeltaRansCodec alloc] init],
    };
}

@implementation TTIOCodecRegistry
+ (nullable id<TTIOCodec>)codecForId:(TTIOCompression)codecId {
    pthread_once(&gOnce, _buildRegistry);
    return gRegistry[@(codecId)];
}
@end
```
> The context-aware adapters (Task 4) get added to this file + the `gRegistry` literal. Confirm the exact `TTIOCompression…` constant spellings against `TTIOEnums.h`.

- [ ] **Step 5: Wire `TTIOCodecRegistry.{h,m}` into `objc/Source/GNUmakefile`. Build + run.**

Run: `./build.sh check 2>&1 | tail -20` — expect the plain round-trip + delta PASS lines; no failures.

- [ ] **Step 6: Commit**

```bash
git -C ~/TTI-O add objc/Source/Codecs/Registry/TTIOCodecRegistry.h objc/Source/Codecs/Registry/TTIOCodecRegistry.m objc/Source/GNUmakefile objc/Tests/TestCodecRegistry.m && git -C ~/TTI-O commit -m "feat(objc-codecs): TTIOCodecRegistry + plain adapters"
```

---

## Task 4: Context-aware adapters

**Files:** Modify `TTIOCodecRegistry.m`; extend `TestCodecRegistry.m`.

- [ ] **Step 0: READ the smart-codec headers** (`Codecs/TTIORefDiffV2.h`, `TTIOMateInfoV2.h`, `TTIOFqzcompNx16Z.h`, `TTIONameTokenizerV2.h`) and `-_decodeRefDiffV2Sequences:` (`TTIOGenomicRun.m:956-1110`) to confirm: exact selectors + param types (esp. fqzcomp `readLengths`/`revcompFlags` types, mate out-param types, ref_diff out-params), the fqzcomp decode dict keys (`@"qualities"`/`@"readLengths"`), and the inline blob-header parse + `TTIOReferenceResolver -resolveURI:…` call in ref_diff decode. Adjust the adapter code + the `TTIODecodedMateInfo`/`TTIOCodecContext` field types to the REAL signatures; report any deviation.

- [ ] **Step 1: Add tests** — append to `testCodecRegistry()`:

```objc
        // name_tok round-trip.
        id<TTIOCodec> nt = [TTIOCodecRegistry codecForId:TTIOCompressionNameTokenizedV2];
        PASS(nt != nil && ![nt isContextAware], "name_tok registered, not context-aware");
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (int i = 0; i < 200; i++) [names addObject:[NSString stringWithFormat:@"read%d", i]];
        NSError *nerr = nil;
        TTIOEncodedChannel *ne =
            [nt encode:[[TTIODecodedStringList alloc] initWithNames:names]
                context:[TTIOCodecContext emptyContext] error:&nerr];
        TTIODecodedChannel *nd =
            [nt decode:[[TTIOBytesPayload alloc] initWithBytes:((TTIOEncodedDatasetBytes *)ne).bytes]
                context:[TTIOCodecContext emptyContext] error:&nerr];
        PASS([((TTIODecodedStringList *)nd).names isEqualToArray:names], "name_tok round-trip");

        // context-aware flags.
        PASS([[TTIOCodecRegistry codecForId:TTIOCompressionRefDiffV2] isContextAware], "refdiff context-aware");
        PASS([[TTIOCodecRegistry codecForId:TTIOCompressionFqzcompNx16Z] isContextAware], "fqzcomp context-aware");
        PASS([[TTIOCodecRegistry codecForId:TTIOCompressionMateInlineV2] isContextAware], "mate context-aware");
        PASS([[TTIOCodecRegistry codecForId:TTIOCompressionRefDiffV2] needsEmbeddedReference], "refdiff needs embed");
        PASS(![[TTIOCodecRegistry codecForId:TTIOCompressionFqzcompNx16Z] needsEmbeddedReference], "fqzcomp no embed");
```

- [ ] **Step 2: Build to verify FAIL** (refdiff/fqz/mate/name_tok not registered → nil → assertion fail). `./build.sh check 2>&1 | tail -20`.

- [ ] **Step 3: Add the 4 context-aware adapters** to `TTIOCodecRegistry.m` (imports `#import "Codecs/TTIOFqzcompNx16Z.h"`, `TTIOMateInfoV2.h`, `TTIONameTokenizerV2.h`, `TTIORefDiffV2.h`). Write them mirroring the plain adapters but pulling from `ctx` and returning the right union subclass:
- `_TTIONameTokenizedCodec` (id NameTokenizedV2, NOT context-aware): decode `+[TTIONameTokenizerV2 decodeData:error:]` → `TTIODecodedStringList`; encode `+[… encodeNames:]` → `TTIOEncodedDatasetBytes`.
- `_TTIOFqzcompCodec` (context-aware): decode `+[TTIOFqzcompNx16Z decodeData:revcompFlags:error:]` → dict; `TTIODecodedBytes(dict[@"qualities"])`. encode needs `ctx.readLengths`/`ctx.revcompFlags` (error if nil) → `+[… encodeWithQualities:readLengths:revcompFlags:error:]`.
- `_TTIOMateInfoCodec` (context-aware): decode `+[TTIOMateInfoV2 decodeData:ownChromIds:ownPositions:nRecords:outMateChromIds:outMatePositions:outTemplateLengths:error:]` (needs ctx.ownChromIds/ownPositions/nRecords) → `TTIODecodedMateInfo`. encode from `TTIODecodedMateInfo` + ctx.ownChromIds/ownPositions → `TTIOEncodedDatasetBytes`.
- `_TTIORefDiffCodec` (context-aware, needsEmbeddedReference=YES): decode = relocate `-_decodeRefDiffV2Sequences` body — open `refdiff_v2` from `((TTIOGroupPayload*)p).group`, parse blob header inline (as the original does), resolve via `ctx.referenceResolver` + single-chrom from `ctx.chromosomes`, call `+[TTIORefDiffV2 decodeData:…outSequences:outOffsets:error:]`, return `TTIODecodedBytes(outSequences)`. encode (filled in Task 6) → for now return nil+error "ref_diff encode wired in Task 6".

Add the 4 to the `gRegistry` literal in `_buildRegistry`.

- [ ] **Step 4: Build + run** — expect the name_tok + flag PASS lines; no failures.

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add objc/Source/Codecs/Registry/TTIOCodecRegistry.m objc/Tests/TestCodecRegistry.m && git -C ~/TTI-O commit -m "feat(objc-codecs): context-aware codec adapters"
```

---

## Task 5: `-_codecContext` + route DECODE in `TTIOGenomicRun.m`

**Files:** Modify `Genomics/TTIOGenomicRun.m`.

- [ ] **Step 0: READ** `-byteChannelSliceNamed:offset:count:error:` (incl. the switch at `:346` and the surrounding read/cache), `-_decodeRefDiffV2Sequences:` (`:956`, esp. the `TTIOReferenceResolver` construction from the HDF5 root group + the encounter-order chrom-id logic), `-_decodeMateInfoInlineV2:` (`:1112`, the `ownChromIds` derivation), `-readNameAtIndex:`, `-cigarAtIndex:`.

- [ ] **Step 1: Add a cached `-_codecContext`** (new ivar `TTIOCodecContext *_codecCtxCache;`). Build `readLengths`/`revcompFlags` (as NSArray<NSNumber*> or NSData matching the codec), `readCount=@(self.index.count)`, `positions` (int64-LE NSData), `totalBases`, `chromosomes`, `ownChromIds`/`ownPositions`/`nRecords` (mirror `-_decodeMateInfoInlineV2` EXACTLY), `cigarsProvider` (a block calling the cigars accessor), and `referenceResolver` (construct exactly as `-_decodeRefDiffV2Sequences` does). Cache it. (Write it mirroring the Python/Java `codecContext()` builders; the field derivations are already in the bespoke methods you read.)

- [ ] **Step 2: Route the byte-channel switch** (`:346`). Replace the `switch (codec_id) { case …: decoded = TTIORansDecode(all,…); … }` with:
```objc
    id<TTIOCodec> codec = [TTIOCodecRegistry codecForId:(TTIOCompression)codec_id];
    if (codec == nil) {
        if (error) *error = /* same NSError the old default arm built */;
        return nil;
    }
    TTIODecodedChannel *dc = [codec decode:[[TTIOBytesPayload alloc] initWithBytes:all]
                                   context:[self _codecContext] error:error];
    if (dc == nil) return nil;
    decoded = ((TTIODecodedBytes *)dc).data;
```
Keep the `codec_id == 0` raw path, the whole-channel read, and the cache + slice tail unchanged. (Import `TTIOCodecRegistry.h` + the registry headers at the top of the `.m`.)

- [ ] **Step 3: Route ref_diff / read_names / mate_info** through the registry (replace the bespoke decode-call lines with `[TTIOCodecRegistry codecForId:…]` + the right payload/union, preserving caches + sidecar parsing). cigars: route only the inner rANS. Delete `-_decodeRefDiffV2Sequences` only if the build stays green (its body now lives in the ref_diff adapter).

- [ ] **Step 4: Build + run the codec/genomic suites — MUST stay green**

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/objc && ./build.sh check 2>&1 | tail -30'`
Expected: all tests pass (esp. `TestM86GenomicCodecWiring`, `TestRefDiffV2Dispatch`, `TestMateInfoV2Dispatch`, `TestNameTokenizedV2Dispatch`, and the `Fixtures/*.bin` byte-equality tests). If any fail, the registry decode is not byte-identical — debug; do not change codec bodies. If a genuine plan gap, STOP and report BLOCKED.

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add objc/Source/Genomics/TTIOGenomicRun.m && git -C ~/TTI-O commit -m "refactor(objc-codecs): route genomic decode through codec registry"
```

---

## Task 6: Route ENCODE (both bodies) in `TTIOSpectralDataset.m` + ref_diff encode

**Files:** Modify `Dataset/TTIOSpectralDataset.m` + `Codecs/Registry/TTIOCodecRegistry.m`.

- [ ] **Step 0: READ** `_TTIO_M86_EncodeWithCodec` (`:403`), `_TTIO_M86_WriteByteChannel`/`…Storage`, `_TTIO_V18_WriteRefDiffV2SequencesHDF5`/`…Storage` (`:1784`/`:1847`), `_TTIO_M94Z_WriteQualitiesFqzcompNx16Z`, the name_tok/mate_info writer sites, AND both encode bodies (`:2071-2238` HDF5, `:2483-2714` storage).

- [ ] **Step 1: Route the byte-stream encode.** Replace the `switch(codec)` in `_TTIO_M86_EncodeWithCodec(raw, codec)` with a registry call returning `((TTIOEncodedDatasetBytes *)[codec encode:[[TTIODecodedBytes alloc] initWithData:raw] context:[TTIOCodecContext emptyContext] error:&err]).bytes`. Both `_TTIO_M86_WriteByteChannel` and `…Storage` consume this helper, so routing it once covers both encode bodies for plain channels. Keep the dataset write + `@compression` tail.

- [ ] **Step 2: Route fqzcomp / name_tok / mate_info writers.** In `_TTIO_M94Z_WriteQualitiesFqzcompNx16Z`, the name_tok inline writers (`:2180`/`:2666`), and the mate_info writers (`:2226`/`:2698`), replace the direct `+[TTIOFqzcompNx16Z …]` / `+[TTIONameTokenizerV2 …]` / `+[TTIOMateInfoV2 …]` call with the registry, building an encode-time `TTIOCodecContext` carrying what each needs (readLengths/revcompFlags for fqzcomp; ownChromIds/ownPositions for mate). Take `((TTIOEncodedDatasetBytes*)enc).bytes`. Both HDF5 + storage call sites route identically.

- [ ] **Step 3: Fill in `_TTIORefDiffCodec.encode`** in `TTIOCodecRegistry.m`: call `+[TTIORefDiffV2 encodeSequences:offsets:positions:cigarStrings:reference:referenceMd5:referenceUri:readsPerSlice:error:]` with args from `ctx` + the `TTIODecodedBytes` value, return `TTIOEncodedGroupLayout(@{@"refdiff_v2": blob}, @{})`. Then in `_TTIO_V18_WriteRefDiffV2SequencesHDF5` + `…Storage`, replace the direct `+[TTIORefDiffV2 encode…]` call with the registry, build the encode `TTIOCodecContext`, and materialize the `sequences` group + `refdiff_v2` child + `@compression` from the returned `TTIOEncodedGroupLayout` — byte-identical to before. The BASE_PACK fallback path stays intact.

- [ ] **Step 4: Build + run full suites — MUST stay green**

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/objc && ./build.sh check 2>&1 | tail -30'`
Expected: all pass; on-disk bytes unchanged (the `Fixtures/*.bin` + M86 round-trip fences). If unsure about byte-identity, STOP and report.

- [ ] **Step 5: Commit**

```bash
git -C ~/TTI-O add objc/Source/Dataset/TTIOSpectralDataset.m objc/Source/Codecs/Registry/TTIOCodecRegistry.m && git -C ~/TTI-O commit -m "refactor(objc-codecs): route genomic encode through codec registry"
```

---

## Task 7: Completeness guard, full check, CHANGELOG

**Files:** extend `TestCodecRegistry.m`; modify `CHANGELOG.md`.

- [ ] **Step 1: Add completeness + membership-safety tests** — append to `testCodecRegistry()`:

```objc
        // Completeness: all 9 real ids registered.
        TTIOCompression all9[9] = {
            TTIOCompressionRansOrder0, TTIOCompressionRansOrder1, TTIOCompressionBasePack,
            TTIOCompressionQualityBinned, TTIOCompressionDeltaRansOrder0,
            TTIOCompressionFqzcompNx16Z, TTIOCompressionMateInlineV2,
            TTIOCompressionRefDiffV2, TTIOCompressionNameTokenizedV2};
        for (int k = 0; k < 9; k++)
            PASS([TTIOCodecRegistry codecForId:all9[k]] != nil,
                 "registry covers id %d", (int)all9[k]);
        // Membership-safe: unregistered valid ids -> nil (no crash).
        PASS([TTIOCodecRegistry codecForId:TTIOCompressionNone] == nil, "NONE unregistered -> nil");
        PASS([TTIOCodecRegistry codecForId:TTIOCompressionZlib] == nil, "ZLIB unregistered -> nil");
```
(Use the exact `TTIOCompressionNone`/`Zlib` constant names from `TTIOEnums.h`.)

- [ ] **Step 2: Run the FULL ObjC suite**

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O/objc && ./build.sh check 2>&1 | tail -40'`
Expected: build OK; `./build.sh check` reports 0 failed tests/sets. If any fail, list them and determine this-work vs environmental; if this-work, STOP and report BLOCKED.

- [ ] **Step 3: Add the CHANGELOG entry** — under `## [Unreleased]`:

```markdown
### Changed — Codec dispatch unified behind a registry (Objective-C)

ObjC's genomic codec dispatch (the decode switch + five bespoke
ref_diff/fqzcomp/name_tok/mate_info/cigars side-paths and the two near-identical
encode bodies) now routes through a single `TTIOCodec` registry keyed by
`TTIOCompression` (`Codecs/Registry/`), fronted by a uniform `TTIOCodec`
protocol, a `TTIOCodecContext` value object, and abstract-class-cluster unions
`TTIODecodedChannel`/`TTIOEncodedChannel`/`TTIOChannelPayload`. Codecs expose
`isContextAware` and `needsEmbeddedReference` (REF_DIFF_V2 only). No
wire/on-disk format change; all byte-equality and cross-language fixtures
unchanged. Completes the 3-SDK codec-registry parity (Python #209, Java #210).
```

- [ ] **Step 4: Commit**

```bash
git -C ~/TTI-O add objc/Tests/TestCodecRegistry.m CHANGELOG.md && git -C ~/TTI-O commit -m "test(objc-codecs): registry completeness guard; changelog"
```

---

## Notes / gotchas

- **ARC is ON** (`-fobjc-arc`): no manual retain/release; use `strong`/`copy` properties as shown.
- **GNUstep is not auto-discovery:** every new `.m` MUST be added to `objc/Source/GNUmakefile` (`libTTIO_OBJC_FILES`) and headers to `libTTIO_HEADER_FILES`; the test `.m` to `objc/Tests/GNUmakefile` + a `START_SET/END_SET` call + `extern` decl in `TTIOTestRunner.m`. A missing entry = link/undefined-symbol error, not a compile error in the new file.
- **No wire change is load-bearing:** adapters wrap the codec functions verbatim; `Fixtures/*.bin` + `TestM86GenomicCodecWiring` are the fences. If any on-disk byte differs, stop and diff.
- **ref_diff is the hard case:** its decode adapter relocates `-_decodeRefDiffV2Sequences` (inline blob-header parse + `TTIOReferenceResolver`), its encode relocates the writer's `+[TTIORefDiffV2 encode…]`. Verify the smart-codec selectors + resolver `-resolveURI:…` before relying on them (Task 4 Step 0).
- **mate_info `ownChromIds` encounter-order** in `-_codecContext` must byte-match `-_decodeMateInfoInlineV2`.
- **Both encode bodies** (HDF5 + storage) must route identically — do NOT let them diverge; do NOT attempt to merge them (out of scope).
- **`codecForId:` nil** for reserved/unregistered ids — callers null-check.
- **Confirm `TTIOCompression…` constant spellings + import paths** against `TTIOEnums.h` and how sibling Codecs files import (header-search-path imports like `"ValueClasses/TTIOEnums.h"`).
- **Final SDK:** no follow-on; after merge a release can bundle all three ports.
