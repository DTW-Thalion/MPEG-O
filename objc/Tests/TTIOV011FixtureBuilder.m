/*
 * TTIOV011FixtureBuilder.m — Task 3.10 of transport-spec v0.11.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import "TTIOV011FixtureBuilder.h"

#import <objc/runtime.h>
#import <hdf5.h>
#include <string.h>
#include <unistd.h>

#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOSubject.h"
#import "Dataset/TTIOSample.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "Genomics/TTIOReferenceImport.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Image/TTIOIRImage.h"
#import "Image/TTIOMSImage.h"
#import "Image/TTIORamanImage.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "Providers/TTIOHDF5Provider.h"
#import "Providers/TTIOStorageProtocols.h"
#import "ValueClasses/TTIOEnums.h"

// ───────────────────────── helpers ──────────────────────────────────

static NSData *fb_f64le(const double *v, NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:n * sizeof(double)];
    for (NSUInteger i = 0; i < n; i++) {
        [d appendBytes:&v[i] length:sizeof(double)];
    }
    return d;
}

static NSData *fb_i32arr(const int32_t *v, NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:n * sizeof(int32_t)];
    for (NSUInteger i = 0; i < n; i++) {
        [d appendBytes:&v[i] length:sizeof(int32_t)];
    }
    return d;
}

static NSData *fb_u32arr(const uint32_t *v, NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:n * sizeof(uint32_t)];
    for (NSUInteger i = 0; i < n; i++) {
        [d appendBytes:&v[i] length:sizeof(uint32_t)];
    }
    return d;
}

static NSData *fb_u64arr(const uint64_t *v, NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithCapacity:n * sizeof(uint64_t)];
    for (NSUInteger i = 0; i < n; i++) {
        [d appendBytes:&v[i] length:sizeof(uint64_t)];
    }
    return d;
}

static NSData *fb_repeatByte(uint8_t b, NSUInteger n)
{
    NSMutableData *d = [NSMutableData dataWithLength:n];
    memset(d.mutableBytes, b, n);
    return d;
}

/** Build a deterministic synthetic MS run with `nSpectra` spectra of
 *  `pointsPerSpectrum` m/z points each. Pattern matches
 *  TransportConformanceTest.buildDataset (cross-language). */
static TTIOWrittenRun *fb_synthMsRun(NSUInteger nSpectra,
                                       NSUInteger pointsPerSpectrum)
{
    NSUInteger total = nSpectra * pointsPerSpectrum;
    double *mz = (double *)calloc(total, sizeof(double));
    double *intensity = (double *)calloc(total, sizeof(double));
    for (NSUInteger i = 0; i < total; i++) {
        mz[i] = 100.0 + (double)i;
        intensity[i] = 100.0 * (double)(i + 1);
    }
    uint64_t *offsets = (uint64_t *)calloc(nSpectra, sizeof(uint64_t));
    uint32_t *lengths = (uint32_t *)calloc(nSpectra, sizeof(uint32_t));
    for (NSUInteger i = 0; i < nSpectra; i++) {
        offsets[i] = (uint64_t)(i * pointsPerSpectrum);
        lengths[i] = (uint32_t)pointsPerSpectrum;
    }
    double *rts = (double *)calloc(nSpectra, sizeof(double));
    int32_t *msLevels = (int32_t *)calloc(nSpectra, sizeof(int32_t));
    int32_t *pols = (int32_t *)calloc(nSpectra, sizeof(int32_t));
    double *pmzs = (double *)calloc(nSpectra, sizeof(double));
    int32_t *pcs = (int32_t *)calloc(nSpectra, sizeof(int32_t));
    double *bpis = (double *)calloc(nSpectra, sizeof(double));
    for (NSUInteger i = 0; i < nSpectra; i++) {
        rts[i] = 1.0 + (double)i;
        msLevels[i] = (i % 2 == 0) ? 1 : 2;
        pols[i] = 1;
        pmzs[i] = msLevels[i] == 1 ? 0.0 : 500.0 + (double)i;
        pcs[i] = msLevels[i] == 1 ? 0 : 2;
        double best = 0.0;
        for (NSUInteger k = 0; k < pointsPerSpectrum; k++) {
            double v = intensity[i * pointsPerSpectrum + k];
            if (v > best) best = v;
        }
        bpis[i] = best;
    }
    TTIOWrittenRun *run = [[TTIOWrittenRun alloc]
        initWithSpectrumClassName:@"TTIOMassSpectrum"
                  acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                      channelData:@{@"mz": fb_f64le(mz, total),
                                    @"intensity": fb_f64le(intensity, total)}
                          offsets:fb_u64arr(offsets, nSpectra)
                          lengths:fb_u32arr(lengths, nSpectra)
                   retentionTimes:fb_f64le(rts, nSpectra)
                         msLevels:fb_i32arr(msLevels, nSpectra)
                       polarities:fb_i32arr(pols, nSpectra)
                     precursorMzs:fb_f64le(pmzs, nSpectra)
                 precursorCharges:fb_i32arr(pcs, nSpectra)
              basePeakIntensities:fb_f64le(bpis, nSpectra)];
    free(mz); free(intensity);
    free(offsets); free(lengths); free(rts);
    free(msLevels); free(pols); free(pmzs); free(pcs); free(bpis);
    return run;
}

/** Build a deterministic minimal WrittenGenomicRun with 4 short
 *  aligned reads. Pattern matches
 *  TestM89GenomicTransport.makeMinimalGenomicWrittenRun. */
static TTIOWrittenGenomicRun *fb_synthGenomicRun(void)
{
    const NSUInteger nReads = 4;
    const NSUInteger readLen = 12;

    NSArray<NSString *> *chroms = @[@"chr1", @"chr1", @"chr2", @"*"];

    int64_t positions[4] = {100, 200, 50, -1};
    NSData *positionsData = [NSData dataWithBytes:positions length:sizeof(positions)];

    uint8_t mapqs[4] = {60, 55, 40, 0};
    NSData *mapqData = [NSData dataWithBytes:mapqs length:sizeof(mapqs)];

    uint32_t flags[4] = {0x0003, 0x0003, 0x0003, 0x0004};
    NSData *flagsData = [NSData dataWithBytes:flags length:sizeof(flags)];

    NSMutableData *seqData = [NSMutableData dataWithCapacity:nReads * readLen];
    for (NSUInteger i = 0; i < nReads; i++) {
        [seqData appendBytes:"ACGTACGTACGT" length:readLen];
    }
    NSMutableData *qualData = [NSMutableData dataWithLength:nReads * readLen];
    memset(qualData.mutableBytes, 30, nReads * readLen);

    uint64_t offsets[4] = {0, 12, 24, 36};
    NSData *offsetsData = [NSData dataWithBytes:offsets length:sizeof(offsets)];
    uint32_t lengths[4] = {12, 12, 12, 12};
    NSData *lengthsData = [NSData dataWithBytes:lengths length:sizeof(lengths)];

    NSMutableArray *cigars = [NSMutableArray array];
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *mateChroms = [NSMutableArray array];
    for (NSUInteger i = 0; i < nReads; i++) {
        [cigars addObject:[NSString stringWithFormat:@"%luM", (unsigned long)readLen]];
        [names addObject:[NSString stringWithFormat:@"read_%03lu", (unsigned long)i]];
        [mateChroms addObject:@""];
    }
    NSMutableData *matePosData = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    int64_t *matePosBuf = (int64_t *)matePosData.mutableBytes;
    for (NSUInteger i = 0; i < nReads; i++) matePosBuf[i] = -1;
    NSMutableData *tlenData = [NSMutableData dataWithLength:nReads * sizeof(int32_t)];

    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"NA12878"
                      positions:positionsData
               mappingQualities:mapqData
                          flags:flagsData
                      sequences:seqData
                      qualities:qualData
                        offsets:offsetsData
                        lengths:lengthsData
                         cigars:cigars
                      readNames:names
                mateChromosomes:mateChroms
                  matePositions:matePosData
                templateLengths:tlenData
                    chromosomes:chroms
              signalCompression:TTIOCompressionNone];
}

/** Inline replica of TTIOMSImage's static `writeImageCubeUnderGroup`.
 *  Writes the canonical /study/image_cube group with intensity cube,
 *  scalar metadata attributes, and mz_axis dataset. Used to layer an
 *  image into a file that was created via writeMinimalToPath (which
 *  does NOT take an MSImage parameter). */
static BOOL fb_writeImageCubeUnderStudy(hid_t fid,
                                          NSUInteger w, NSUInteger h, NSUInteger sp,
                                          NSUInteger tileSize,
                                          double pxX, double pxY,
                                          NSString *scanPattern,
                                          const void *cubeBytes,
                                          NSData *mzAxis)
{
    hid_t studyGid = H5Gopen2(fid, "study", H5P_DEFAULT);
    if (studyGid < 0) return NO;

    // If /study/image_cube exists, drop it first (idempotent).
    if (H5Lexists(studyGid, "image_cube", H5P_DEFAULT) > 0) {
        H5Ldelete(studyGid, "image_cube", H5P_DEFAULT);
    }

    hid_t imageGroup = H5Gcreate2(studyGid, "image_cube",
                                   H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (imageGroup < 0) {
        H5Gclose(studyGid);
        return NO;
    }

    hsize_t dims[3]  = { (hsize_t)h, (hsize_t)w, (hsize_t)sp };
    hsize_t chunk[3] = { (hsize_t)MIN(tileSize, h),
                         (hsize_t)MIN(tileSize, w),
                         (hsize_t)sp };

    hid_t space = H5Screate_simple(3, dims, NULL);
    hid_t plist = H5Pcreate(H5P_DATASET_CREATE);
    H5Pset_chunk(plist, 3, chunk);
    H5Pset_deflate(plist, 6);

    hid_t did = H5Dcreate2(imageGroup, "intensity",
                           H5T_NATIVE_DOUBLE, space,
                           H5P_DEFAULT, plist, H5P_DEFAULT);
    if (did < 0) {
        H5Pclose(plist); H5Sclose(space);
        H5Gclose(imageGroup); H5Gclose(studyGid);
        return NO;
    }

    herr_t s = H5Dwrite(did, H5T_NATIVE_DOUBLE,
                        H5S_ALL, H5S_ALL, H5P_DEFAULT, cubeBytes);
    if (s < 0) {
        H5Dclose(did); H5Pclose(plist); H5Sclose(space);
        H5Gclose(imageGroup); H5Gclose(studyGid);
        return NO;
    }

    hid_t scalar = H5Screate(H5S_SCALAR);
    #define FB_WRITE_INT_ATTR(name, val) do { \
        hid_t a = H5Acreate2(imageGroup, (name), H5T_NATIVE_INT64, \
                              scalar, H5P_DEFAULT, H5P_DEFAULT); \
        int64_t v = (int64_t)(val); \
        H5Awrite(a, H5T_NATIVE_INT64, &v); H5Aclose(a); \
    } while (0)
    #define FB_WRITE_DBL_ATTR(name, val) do { \
        hid_t a = H5Acreate2(imageGroup, (name), H5T_NATIVE_DOUBLE, \
                              scalar, H5P_DEFAULT, H5P_DEFAULT); \
        double v = (val); \
        H5Awrite(a, H5T_NATIVE_DOUBLE, &v); H5Aclose(a); \
    } while (0)

    FB_WRITE_INT_ATTR("width",           w);
    FB_WRITE_INT_ATTR("height",          h);
    FB_WRITE_INT_ATTR("spectral_points", sp);
    FB_WRITE_INT_ATTR("tile_size",       tileSize);
    FB_WRITE_DBL_ATTR("pixel_size_x",    pxX);
    FB_WRITE_DBL_ATTR("pixel_size_y",    pxY);

    {
        hid_t strType = H5Tcopy(H5T_C_S1);
        H5Tset_size(strType, H5T_VARIABLE);
        hid_t a = H5Acreate2(imageGroup, "scan_pattern", strType, scalar,
                              H5P_DEFAULT, H5P_DEFAULT);
        const char *cs = [(scanPattern ?: @"") UTF8String];
        H5Awrite(a, strType, &cs);
        H5Aclose(a);
        H5Tclose(strType);
    }

    if (mzAxis != nil && mzAxis.length == sp * sizeof(double)) {
        hsize_t axisDims[1] = { (hsize_t)sp };
        hid_t axisSpace = H5Screate_simple(1, axisDims, NULL);
        hid_t axisPlist = H5Pcreate(H5P_DATASET_CREATE);
        H5Pset_chunk(axisPlist, 1, axisDims);
        H5Pset_deflate(axisPlist, 6);
        hid_t axisDid = H5Dcreate2(imageGroup, "mz_axis",
                                    H5T_NATIVE_DOUBLE, axisSpace,
                                    H5P_DEFAULT, axisPlist, H5P_DEFAULT);
        if (axisDid >= 0) {
            H5Dwrite(axisDid, H5T_NATIVE_DOUBLE,
                      H5S_ALL, H5S_ALL, H5P_DEFAULT, mzAxis.bytes);
            H5Dclose(axisDid);
        }
        H5Pclose(axisPlist);
        H5Sclose(axisSpace);
    }

    #undef FB_WRITE_INT_ATTR
    #undef FB_WRITE_DBL_ATTR

    H5Sclose(scalar);
    H5Dclose(did);
    H5Pclose(plist);
    H5Sclose(space);
    H5Gclose(imageGroup);
    H5Gclose(studyGid);
    return YES;
}

/** Attach a writable HDF5Provider to a stub TTIOSpectralDataset so
 *  TTIOReferenceImport's writeToDataset: can reach it through the
 *  public `-provider` accessor. Pattern from
 *  TTIOReferenceImportWriteToDatasetTests.m. */
static TTIOSpectralDataset *fb_makeWritableStub(NSString *path,
                                                  NSError **error)
{
    TTIOHDF5Provider *p = [[TTIOHDF5Provider alloc] init];
    if (![p openURL:path mode:TTIOStorageOpenModeReadWrite error:error]) {
        return nil;
    }
    TTIOSpectralDataset *ds =
        [[TTIOSpectralDataset alloc] initWithTitle:@"fixture"
                                isaInvestigationId:@""
                                            msRuns:@{}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    Ivar provIvar = class_getInstanceVariable([TTIOSpectralDataset class],
                                                "_provider");
    if (provIvar == NULL) return nil;
    object_setIvar(ds, provIvar, p);
    return ds;
}

/** Task 6.6: layer Subject + Sample per-row groups under
 *  /study/subjects/<external_id>/ and /study/samples/<sample_id>/ on
 *  a freshly-created .tio. Mirrors the production write path
 *  (writeSubjectsViaProvider / writeSamplesViaProvider on the Java
 *  side, _write_subjects_h5 / _write_samples_h5 on the Python side)
 *  exactly so the lazy -subjects / -samples accessors materialise
 *  identical rows on every SDK.
 *
 *  The Subject + Sample lists may be nil/@[] independently — only
 *  the populated side gets its parent group. */
static BOOL fb_layerSubjectsAndSamples(NSString *path,
                                         NSArray<TTIOSubject *> *subjects,
                                         NSArray<TTIOSample *> *samples,
                                         NSError **error)
{
    if (subjects.count == 0 && samples.count == 0) return YES;

    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:error];
    if (f == nil) return NO;
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (study == nil) { [f close]; return NO; }

    if (subjects.count > 0) {
        TTIOHDF5Group *sg = [study createGroupNamed:@"subjects" error:error];
        if (sg == nil) { [f close]; return NO; }
        for (TTIOSubject *s in subjects) {
            TTIOHDF5Group *row = [sg createGroupNamed:s.externalId error:error];
            if (row == nil) { [f close]; return NO; }
            if (![row setStringAttribute:@"external_id"
                                    value:s.externalId
                                    error:error]) { [f close]; return NO; }
            if (s.project.length > 0) {
                if (![row setStringAttribute:@"project"
                                        value:s.project
                                        error:error]) { [f close]; return NO; }
            }
            if (s.sex.length > 0) {
                if (![row setStringAttribute:@"sex"
                                        value:s.sex
                                        error:error]) { [f close]; return NO; }
            }
            if (![row setIntegerAttribute:@"birth_year"
                                      value:s.birthYear
                                      error:error]) { [f close]; return NO; }
            if (![row setStringAttribute:@"attributes_json"
                                    value:[s attributesJson]
                                    error:error]) { [f close]; return NO; }
        }
    }
    if (samples.count > 0) {
        TTIOHDF5Group *smg = [study createGroupNamed:@"samples" error:error];
        if (smg == nil) { [f close]; return NO; }
        for (TTIOSample *s in samples) {
            TTIOHDF5Group *row = [smg createGroupNamed:s.sampleId error:error];
            if (row == nil) { [f close]; return NO; }
            if (![row setStringAttribute:@"sample_id"
                                    value:s.sampleId
                                    error:error]) { [f close]; return NO; }
            if (s.subjectExternalId.length > 0) {
                if (![row setStringAttribute:@"subject_external_id"
                                        value:s.subjectExternalId
                                        error:error]) { [f close]; return NO; }
            }
            if (s.sampleKind.length > 0) {
                if (![row setStringAttribute:@"sample_kind"
                                        value:s.sampleKind
                                        error:error]) { [f close]; return NO; }
            }
            if (![row setIntegerAttribute:@"collected_at"
                                      value:s.collectedAt
                                      error:error]) { [f close]; return NO; }
            if (![row setStringAttribute:@"attributes_json"
                                    value:[s attributesJson]
                                    error:error]) { [f close]; return NO; }
        }
    }
    [f close];
    return YES;
}

// ─────────────────────── public builders ────────────────────────────

@implementation TTIOV011FixtureBuilder

+ (BOOL)buildReferenceOnlyAtPath:(NSString *)path
                            error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                 title:@"reference_only"
                                    isaInvestigationId:@""
                                                msRuns:@{}
                                       identifications:nil
                                       quantifications:nil
                                     provenanceRecords:nil
                                                 error:error];
    if (!ok) return NO;

    NSArray<NSString *> *names = @[@"chr_long", @"chr_medium", @"chr_short"];
    NSArray<NSData *> *seqs = @[
        fb_repeatByte((uint8_t)'A', 6000),
        fb_repeatByte((uint8_t)'C', 1000),
        [@"ACGTACGTACGTACGTAC" dataUsingEncoding:NSASCIIStringEncoding]];
    TTIOReferenceImport *ref =
        [[TTIOReferenceImport alloc] initWithUri:@"fixture-reference-only-v1"
                                     chromosomes:names
                                       sequences:seqs];

    TTIOSpectralDataset *stub = fb_makeWritableStub(path, error);
    if (stub == nil) return NO;
    BOOL wrote = [ref writeToDataset:stub error:error];
    [stub closeFile];
    return wrote;
}

+ (BOOL)buildMsRunsOnlyAtPath:(NSString *)path
                         error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    TTIOWrittenRun *run = fb_synthMsRun(5, 4);
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"ms_runs_only"
                                 isaInvestigationId:@""
                                             msRuns:@{@"run_0001": run}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

+ (BOOL)buildGenomicRunsOnlyAtPath:(NSString *)path
                              error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    TTIOWrittenGenomicRun *wgr =
        [fb_synthGenomicRun() copyWithOptLegacyWholeChannel:YES];
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"genomic_runs_only"
                                 isaInvestigationId:@""
                                             msRuns:@{}
                                        genomicRuns:@{@"genomic_0001": wgr}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

+ (BOOL)buildGenomicRunsBlocksAtPath:(NSString *)path
                                error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    TTIOWrittenGenomicRun *wgr = fb_synthGenomicRun();
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"genomic_runs_blocks"
                                 isaInvestigationId:@""
                                             msRuns:@{}
                                        genomicRuns:@{@"genomic_0001": wgr}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

+ (BOOL)buildImageMsContinuousAtPath:(NSString *)path
                                 error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    const NSUInteger w = 4, h = 4, s = 5;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    double *p = (double *)cube.mutableBytes;
    for (NSUInteger y = 0; y < h; y++) {
        for (NSUInteger x = 0; x < w; x++) {
            NSUInteger pixelIdx = x + y * w;
            NSUInteger base = (y * w + x) * s;
            for (NSUInteger k = 0; k < s; k++) {
                p[base + k] = (double)(k + 1) * (double)pixelIdx;
            }
        }
    }
    NSMutableData *mz = [NSMutableData dataWithLength:s * sizeof(double)];
    double *mzp = (double *)mz.mutableBytes;
    for (NSUInteger i = 0; i < s; i++) mzp[i] = 100.0 + (double)i * 10.0;

    TTIOMSImage *image = [[TTIOMSImage alloc]
                            initWithTitle:@"image_ms_continuous"
                       isaInvestigationId:@""
                          identifications:@[]
                          quantifications:@[]
                        provenanceRecords:@[]
                                    width:w
                                   height:h
                           spectralPoints:s
                                 tileSize:32
                               pixelSizeX:10.0
                               pixelSizeY:10.0
                              scanPattern:@"raster"
                                     cube:cube
                                   mzAxis:mz];
    return [image writeToFilePath:path error:error];
}

+ (BOOL)buildIdentificationsOnlyAtPath:(NSString *)path
                                   error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    NSArray<TTIOIdentification *> *ids = @[
        [[TTIOIdentification alloc]
            initWithRunName:@"run1"
              spectrumIndex:42
             chemicalEntity:@"CompoundA"
            confidenceScore:0.91
              evidenceChain:@[@"evidence1", @"evidence2"]],
        [[TTIOIdentification alloc]
            initWithRunName:@"run1"
              spectrumIndex:43
             chemicalEntity:@"CompoundB"
            confidenceScore:0.85
              evidenceChain:@[@"evidence3"]]
    ];
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"ids_only"
                                 isaInvestigationId:@""
                                             msRuns:@{}
                                    identifications:ids
                                    quantifications:nil
                                  provenanceRecords:nil
                                              error:error];
}

+ (BOOL)buildQuantificationsOnlyAtPath:(NSString *)path
                                   error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    NSArray<TTIOQuantification *> *quants = @[
        [[TTIOQuantification alloc]
            initWithChemicalEntity:@"CompoundA"
                         sampleRef:@"sample-1"
                         abundance:12.5
               normalizationMethod:@"intensity-sum"
                              unit:@"counts"],
        [[TTIOQuantification alloc]
            initWithChemicalEntity:@"CompoundB"
                         sampleRef:@"sample-1"
                         abundance:7.3
               normalizationMethod:@"intensity-sum"
                              unit:@"counts"]
    ];
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"quants_only"
                                 isaInvestigationId:@""
                                             msRuns:@{}
                                    identifications:nil
                                    quantifications:quants
                                  provenanceRecords:nil
                                              error:error];
}

+ (BOOL)buildDatasetProvenanceOnlyAtPath:(NSString *)path
                                     error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    NSDictionary<NSString *, NSString *> *params =
        @{@"mode": @"strict", @"threshold": @"0.5"};
    TTIOProvenanceRecord *r1 = [[TTIOProvenanceRecord alloc]
        initWithInputRefs:@[@"file:///in.raw", @"file:///in2.raw"]
                 software:@"TTI-O ObjC 1.0.0"
               parameters:params
               outputRefs:@[@"file:///out.tio"]
            timestampUnix:1700000000];
    TTIOProvenanceRecord *r2 = [[TTIOProvenanceRecord alloc]
        initWithInputRefs:@[]
                 software:@"downstream step"
               parameters:@{}
               outputRefs:@[@"file:///final.tio"]
            timestampUnix:1700000100];
    return [TTIOSpectralDataset writeMinimalToPath:path
                                              title:@"provenance_only"
                                 isaInvestigationId:@""
                                             msRuns:@{}
                                    identifications:nil
                                    quantifications:nil
                                  provenanceRecords:@[r1, r2]
                                              error:error];
}

+ (BOOL)buildEncryptionAlgorithmOnlyAtPath:(NSString *)path
                                       error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                 title:@"encryption_only"
                                    isaInvestigationId:@""
                                                msRuns:@{}
                                       identifications:nil
                                       quantifications:nil
                                     provenanceRecords:nil
                                                 error:error];
    if (!ok) return NO;

    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:error];
    if (!f) return NO;
    TTIOHDF5Group *root = [f rootGroup];
    BOOL setOk = [root setStringAttribute:@"encrypted"
                                     value:@"aes-256-gcm"
                                     error:error];
    [f close];
    return setOk;
}

+ (BOOL)buildEverythingAtPath:(NSString *)path
                          error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);

    // 1. Identifications + quantifications + provenance
    NSArray<TTIOIdentification *> *ids = @[
        [[TTIOIdentification alloc]
            initWithRunName:@"run_0001"
              spectrumIndex:0
             chemicalEntity:@"CompoundA"
            confidenceScore:0.91
              evidenceChain:@[@"evidence1", @"evidence2"]],
        [[TTIOIdentification alloc]
            initWithRunName:@"run_0001"
              spectrumIndex:1
             chemicalEntity:@"CompoundB"
            confidenceScore:0.85
              evidenceChain:@[@"evidence3"]]
    ];
    NSArray<TTIOQuantification *> *quants = @[
        [[TTIOQuantification alloc]
            initWithChemicalEntity:@"CompoundA"
                         sampleRef:@"sample-1"
                         abundance:12.5
               normalizationMethod:@"intensity-sum"
                              unit:@"counts"],
        [[TTIOQuantification alloc]
            initWithChemicalEntity:@"CompoundB"
                         sampleRef:@"sample-1"
                         abundance:7.3
               normalizationMethod:@"intensity-sum"
                              unit:@"counts"]
    ];
    NSDictionary<NSString *, NSString *> *params =
        @{@"mode": @"strict", @"threshold": @"0.5"};
    TTIOProvenanceRecord *prov1 = [[TTIOProvenanceRecord alloc]
        initWithInputRefs:@[@"file:///in.raw", @"file:///in2.raw"]
                 software:@"TTI-O ObjC 1.0.0"
               parameters:params
               outputRefs:@[@"file:///out.tio"]
            timestampUnix:1700000000];
    TTIOProvenanceRecord *prov2 = [[TTIOProvenanceRecord alloc]
        initWithInputRefs:@[]
                 software:@"downstream step"
               parameters:@{}
               outputRefs:@[@"file:///final.tio"]
            timestampUnix:1700000100];

    // 2. MS run (5 spectra of 4 m/z) + genomic run (4 short reads)
    TTIOWrittenRun *msRun = fb_synthMsRun(5, 4);
    TTIOWrittenGenomicRun *genRun = fb_synthGenomicRun();

    // 3. Seed the file with MS + genomic + ids + quants + prov
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                 title:@"everything"
                                    isaInvestigationId:@""
                                                msRuns:@{@"run_0001": msRun}
                                           genomicRuns:@{@"genomic_0001": genRun}
                                       identifications:ids
                                       quantifications:quants
                                     provenanceRecords:@[prov1, prov2]
                                                 error:error];
    if (!ok) return NO;

    // 4. Layer the 3×3×4 MSImage cube into /study/image_cube/ via
    //    direct HDF5 calls — replicates TTIOMSImage's internal helper
    //    without truncating the file.
    {
        const NSUInteger w = 3, h = 3, s = 4;
        NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
        double *p = (double *)cube.mutableBytes;
        for (NSUInteger y = 0; y < h; y++) {
            for (NSUInteger x = 0; x < w; x++) {
                NSUInteger pixelIdx = x + y * w;
                NSUInteger base = (y * w + x) * s;
                for (NSUInteger k = 0; k < s; k++) {
                    p[base + k] = (double)(k + 1) * (double)pixelIdx;
                }
            }
        }
        NSMutableData *mz = [NSMutableData dataWithLength:s * sizeof(double)];
        double *mzp = (double *)mz.mutableBytes;
        for (NSUInteger i = 0; i < s; i++) mzp[i] = 100.0 + (double)i * 10.0;

        hid_t fid = H5Fopen([path fileSystemRepresentation],
                             H5F_ACC_RDWR, H5P_DEFAULT);
        if (fid < 0) return NO;
        BOOL imgOk = fb_writeImageCubeUnderStudy(fid, w, h, s,
                                                   32,
                                                   10.0, 10.0,
                                                   @"raster",
                                                   cube.bytes,
                                                   mz);
        H5Fclose(fid);
        if (!imgOk) return NO;
    }

    // 5. Layer the reference (3 contigs) via writeToDataset
    {
        NSArray<NSString *> *names =
            @[@"chr_long", @"chr_medium", @"chr_short"];
        NSArray<NSData *> *seqs = @[
            fb_repeatByte((uint8_t)'A', 6000),
            fb_repeatByte((uint8_t)'C', 1000),
            [@"ACGTACGTACGTACGTAC" dataUsingEncoding:NSASCIIStringEncoding]];
        TTIOReferenceImport *ref =
            [[TTIOReferenceImport alloc] initWithUri:@"fixture-everything-v1"
                                         chromosomes:names
                                           sequences:seqs];
        TTIOSpectralDataset *stub = fb_makeWritableStub(path, error);
        if (stub == nil) return NO;
        BOOL refOk = [ref writeToDataset:stub error:error];
        [stub closeFile];
        if (!refOk) return NO;
    }

    // 6. Set the @encrypted root attribute = "aes-256-gcm"
    {
        TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:error];
        if (!f) return NO;
        TTIOHDF5Group *root = [f rootGroup];
        BOOL setOk = [root setStringAttribute:@"encrypted"
                                         value:@"aes-256-gcm"
                                         error:error];
        [f close];
        if (!setOk) return NO;
    }

    // 7. Task 6.6: layer 2 Subjects + 3 Samples exercising every
    //    spec §8 cross-cardinality case (matched, unmatched Subject,
    //    anonymous Sample, dangling soft-FK Sample). Same content as
    //    the Java + Python siblings.
    {
        TTIOSubject *subjA = [[TTIOSubject alloc]
            initWithExternalId:@"SUBJ-A"
                        project:@"PROJ_A"
                            sex:@"F"
                      birthYear:1985
                     attributes:@{@"notes": @"fully populated subject",
                                  @"cohort": @"control"}];
        TTIOSubject *subjB = [[TTIOSubject alloc]
            initWithExternalId:@"SUBJ-B"
                        project:nil
                            sex:nil
                      birthYear:0
                     attributes:nil];
        TTIOSample *smpl1 = [[TTIOSample alloc]
            initWithSampleId:@"SMPL-1"
           subjectExternalId:@"SUBJ-A"
                  sampleKind:@"tissue"
                 collectedAt:1700000000
                  attributes:@{@"tissue": @"liver",
                               @"notes": @"freshly collected"}];
        TTIOSample *smpl2 = [[TTIOSample alloc]
            initWithSampleId:@"SMPL-2"
           subjectExternalId:nil
                  sampleKind:@"plasma"
                 collectedAt:0
                  attributes:nil];
        TTIOSample *smpl3 = [[TTIOSample alloc]
            initWithSampleId:@"SMPL-3"
           subjectExternalId:@"SUBJ-MISSING"
                  sampleKind:nil
                 collectedAt:0
                  attributes:nil];
        if (!fb_layerSubjectsAndSamples(path,
                                          @[subjA, subjB],
                                          @[smpl1, smpl2, smpl3],
                                          error)) {
            return NO;
        }
    }

    return YES;
}

// ─────────── Stage 5 / Task 5.6 fixtures (Deferral 1) ──────────────

+ (BOOL)buildImageMsProcessedOnlyAtPath:(NSString *)path
                                    error:(NSError **)error
{
    // Same fixture shape as +buildImageMsContinuousAtPath: — the
    // encode-side override is the only knob that varies between
    // MS_IMAGE and MS_IMAGE_PROCESSED.
    return [self buildImageMsContinuousAtPath:path error:error];
}

// ─────────── Stage 6 / Task 6.6 fixtures (Deferral 2) ──────────────

+ (BOOL)buildSubjectsOnlyAtPath:(NSString *)path
                            error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"subjects_only"
                                     isaInvestigationId:@""
                                                 msRuns:@{}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:error];
    if (!ok) return NO;

    // Minimal: external_id only, all optionals at unset sentinel.
    TTIOSubject *minimal = [[TTIOSubject alloc]
        initWithExternalId:@"SUBJ-A"
                    project:nil
                        sex:nil
                  birthYear:0
                 attributes:nil];
    // Fully populated, multi-key sort-keys attributes.
    TTIOSubject *full = [[TTIOSubject alloc]
        initWithExternalId:@"SUBJ-B"
                    project:@"PROJ_A"
                        sex:@"F"
                  birthYear:1985
                 attributes:@{@"notes": @"fully populated subject",
                              @"cohort": @"control"}];
    return fb_layerSubjectsAndSamples(path,
                                       @[minimal, full],
                                       @[],
                                       error);
}

+ (BOOL)buildSamplesOnlyAtPath:(NSString *)path
                           error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"samples_only"
                                     isaInvestigationId:@""
                                                 msRuns:@{}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:error];
    if (!ok) return NO;

    TTIOSample *minimal = [[TTIOSample alloc]
        initWithSampleId:@"SMPL-1"
       subjectExternalId:nil
              sampleKind:nil
             collectedAt:0
              attributes:nil];
    // Soft-FK miss: subject_external_id refers to a Subject that
    // doesn't exist in this fixture. Spec §4.4 allows it.
    TTIOSample *danglingFk = [[TTIOSample alloc]
        initWithSampleId:@"SMPL-2"
       subjectExternalId:@"SUBJ-MISSING"
              sampleKind:@"plasma"
             collectedAt:0
              attributes:nil];
    TTIOSample *full = [[TTIOSample alloc]
        initWithSampleId:@"SMPL-3"
       subjectExternalId:nil
              sampleKind:@"tissue"
             collectedAt:1700000000
              attributes:@{@"tissue": @"liver",
                           @"notes": @"freshly collected"}];
    return fb_layerSubjectsAndSamples(path,
                                       @[],
                                       @[minimal, danglingFk, full],
                                       error);
}

+ (BOOL)buildRamanImageOnlyAtPath:(NSString *)path
                              error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    const NSUInteger w = 3, h = 3, s = 5;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    double *p = (double *)cube.mutableBytes;
    for (NSUInteger i = 0; i < w * h * s; i++) {
        p[i] = (double)i * 0.5;
    }
    NSMutableData *wn = [NSMutableData dataWithLength:s * sizeof(double)];
    double *wnp = (double *)wn.mutableBytes;
    double wnVals[5] = {1000.0, 1100.0, 1200.0, 1300.0, 1400.0};
    memcpy(wnp, wnVals, sizeof(wnVals));

    TTIORamanImage *img = [[TTIORamanImage alloc]
                            initWithTitle:@"raman_image_only"
                       isaInvestigationId:@""
                          identifications:@[]
                          quantifications:@[]
                        provenanceRecords:@[]
                                    width:w
                                   height:h
                           spectralPoints:s
                                 tileSize:32
                               pixelSizeX:10.0
                               pixelSizeY:10.0
                              scanPattern:@"raster"
                   excitationWavelengthNm:785.0
                             laserPowerMw:50.0
                                     cube:cube
                              wavenumbers:wn];
    return [img writeToFilePath:path error:error];
}

+ (BOOL)buildIrImageOnlyAtPath:(NSString *)path
                           error:(NSError **)error
{
    unlink([path fileSystemRepresentation]);
    const NSUInteger w = 3, h = 3, s = 5;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    double *p = (double *)cube.mutableBytes;
    for (NSUInteger i = 0; i < w * h * s; i++) {
        p[i] = (double)i * 0.5;
    }
    NSMutableData *wn = [NSMutableData dataWithLength:s * sizeof(double)];
    double *wnp = (double *)wn.mutableBytes;
    double wnVals[5] = {1000.0, 1100.0, 1200.0, 1300.0, 1400.0};
    memcpy(wnp, wnVals, sizeof(wnVals));

    TTIOIRImage *img = [[TTIOIRImage alloc]
                          initWithTitle:@"ir_image_only"
                     isaInvestigationId:@""
                        identifications:@[]
                        quantifications:@[]
                      provenanceRecords:@[]
                                  width:w
                                 height:h
                         spectralPoints:s
                               tileSize:32
                             pixelSizeX:10.0
                             pixelSizeY:10.0
                            scanPattern:@"raster"
                                   mode:TTIOIRModeAbsorbance
                        resolutionCmInv:4.0
                                   cube:cube
                            wavenumbers:wn];
    return [img writeToFilePath:path error:error];
}

@end
