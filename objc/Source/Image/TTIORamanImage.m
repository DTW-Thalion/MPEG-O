/*
 * TTIORamanImage.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIORamanImage
 * Inherits From: NSObject  (composition pattern — dataset-level fields owned directly)
 * Declared In:   Image/TTIORamanImage.h
 *
 * Raman imaging dataset. 3-D cube + shared 1-D wavenumbers axis;
 * persists under /study/raman_image_cube/.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIORamanImage.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <hdf5.h>

#define TTIO_RAMAN_IMAGE_GROUP "raman_image_cube"

@implementation TTIORamanImage

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers
       excitationWavelengthNm:(double)excitationNm
                 laserPowerMw:(double)laserPowerMw
{
    return [self initWithTitle:@""
            isaInvestigationId:@""
               identifications:@[]
               quantifications:@[]
             provenanceRecords:@[]
                         width:width
                        height:height
                spectralPoints:spectralPoints
                      tileSize:tileSize
                    pixelSizeX:0.0
                    pixelSizeY:0.0
                   scanPattern:@""
        excitationWavelengthNm:excitationNm
                  laserPowerMw:laserPowerMw
                          cube:cube
                   wavenumbers:wavenumbers];
}

- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                        width:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                   pixelSizeX:(double)pixelSizeX
                   pixelSizeY:(double)pixelSizeY
                  scanPattern:(NSString *)scanPattern
       excitationWavelengthNm:(double)excitationNm
                 laserPowerMw:(double)laserPowerMw
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers
{
    NSParameterAssert(cube.length == width * height * spectralPoints * sizeof(double));
    NSParameterAssert(wavenumbers.length == spectralPoints * sizeof(double));
    self = [super initWithTitle:title
             isaInvestigationId:isaId
                identifications:identifications
                quantifications:quantifications
              provenanceRecords:provenance
                          width:width
                         height:height
                 spectralPoints:spectralPoints
                       tileSize:tileSize
                     pixelSizeX:pixelSizeX
                     pixelSizeY:pixelSizeY
                    scanPattern:scanPattern
                           cube:cube];
    if (self) {
        _excitationWavelengthNm = excitationNm;
        _laserPowerMw           = laserPowerMw;
        _wavenumbers            = [wavenumbers copy];
    }
    return self;
}

#pragma mark - Polymorphic modality accessors

- (TTIOImageKind)kind { return TTIOImageKindRaman; }
- (nullable NSData *)spectralAxis { return self.wavenumbers; }
- (TTIOSpectralAxisKind)spectralAxisKind { return TTIOSpectralAxisKindWavenumber; }

#pragma mark - HDF5 helpers

static BOOL writeCubeGroup(hid_t parentGid,
                           const char *groupName,
                           NSUInteger width, NSUInteger height,
                           NSUInteger sp, NSUInteger tileSize,
                           double pxX, double pxY,
                           NSString *scanPattern,
                           const void *cubeBytes,
                           const void *wavenumberBytes,
                           NSDictionary<NSString *, NSNumber *> *doubleAttrs,
                           NSDictionary<NSString *, NSString *> *stringAttrs,
                           NSError **error)
{
    hid_t g = H5Gcreate2(parentGid, groupName,
                          H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (g < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorGroupCreate,
            @"H5Gcreate2 imaging cube group failed");
        return NO;
    }

    hsize_t dims[3]  = { (hsize_t)height, (hsize_t)width, (hsize_t)sp };
    hsize_t chunk[3] = { (hsize_t)MIN(tileSize, height),
                         (hsize_t)MIN(tileSize, width),
                         (hsize_t)sp };

    hid_t space = H5Screate_simple(3, dims, NULL);
    hid_t plist = H5Pcreate(H5P_DATASET_CREATE);
    H5Pset_chunk(plist, 3, chunk);
    H5Pset_shuffle(plist);   /* byte-shuffle before deflate; core HDF5, self-describing */
    H5Pset_deflate(plist, 6);

    hid_t did = H5Dcreate2(g, "intensity",
                           H5T_NATIVE_DOUBLE, space,
                           H5P_DEFAULT, plist, H5P_DEFAULT);
    if (did < 0) {
        H5Pclose(plist); H5Sclose(space); H5Gclose(g);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetCreate,
            @"H5Dcreate2 intensity failed");
        return NO;
    }
    herr_t s = H5Dwrite(did, H5T_NATIVE_DOUBLE,
                        H5S_ALL, H5S_ALL, H5P_DEFAULT, cubeBytes);
    H5Dclose(did); H5Pclose(plist); H5Sclose(space);
    if (s < 0) {
        H5Gclose(g);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dwrite intensity failed");
        return NO;
    }

    // 1-D wavenumbers
    hsize_t wDims[1] = { (hsize_t)sp };
    hid_t wSpace = H5Screate_simple(1, wDims, NULL);
    hid_t wDid = H5Dcreate2(g, "wavenumbers",
                             H5T_NATIVE_DOUBLE, wSpace,
                             H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    H5Dwrite(wDid, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, wavenumberBytes);
    H5Dclose(wDid); H5Sclose(wSpace);

    hid_t scalar = H5Screate(H5S_SCALAR);
    #define WRITE_INT(name, val) do { \
        hid_t a = H5Acreate2(g, (name), H5T_NATIVE_INT64, \
                              scalar, H5P_DEFAULT, H5P_DEFAULT); \
        int64_t v = (int64_t)(val); H5Awrite(a, H5T_NATIVE_INT64, &v); H5Aclose(a); \
    } while (0)
    #define WRITE_DBL(name, val) do { \
        hid_t a = H5Acreate2(g, (name), H5T_NATIVE_DOUBLE, \
                              scalar, H5P_DEFAULT, H5P_DEFAULT); \
        double v = (val); H5Awrite(a, H5T_NATIVE_DOUBLE, &v); H5Aclose(a); \
    } while (0)

    WRITE_INT("width",           width);
    WRITE_INT("height",          height);
    WRITE_INT("spectral_points", sp);
    WRITE_INT("tile_size",       tileSize);
    WRITE_DBL("pixel_size_x",    pxX);
    WRITE_DBL("pixel_size_y",    pxY);
    for (NSString *k in doubleAttrs) {
        WRITE_DBL([k UTF8String], [doubleAttrs[k] doubleValue]);
    }

    // variable-length string attributes
    for (NSString *k in stringAttrs) {
        hid_t strType = H5Tcopy(H5T_C_S1);
        H5Tset_size(strType, H5T_VARIABLE);
        hid_t a = H5Acreate2(g, [k UTF8String], strType, scalar,
                              H5P_DEFAULT, H5P_DEFAULT);
        const char *cs = [stringAttrs[k] UTF8String];
        H5Awrite(a, strType, &cs);
        H5Aclose(a);
        H5Tclose(strType);
    }
    // scan_pattern
    {
        hid_t strType = H5Tcopy(H5T_C_S1);
        H5Tset_size(strType, H5T_VARIABLE);
        hid_t a = H5Acreate2(g, "scan_pattern", strType, scalar,
                              H5P_DEFAULT, H5P_DEFAULT);
        const char *cs = [(scanPattern ?: @"") UTF8String];
        H5Awrite(a, strType, &cs);
        H5Aclose(a);
        H5Tclose(strType);
    }

    #undef WRITE_INT
    #undef WRITE_DBL
    H5Sclose(scalar);
    H5Gclose(g);
    return YES;
}

typedef struct {
    NSUInteger width, height, sp, tileSize;
    double pixelSizeX, pixelSizeY;
    char *scanPattern;    // owned
} ttio_img_core_t;

static void readCoreMeta(hid_t g, ttio_img_core_t *out)
{
    int64_t v;
    hid_t a;
    a = H5Aopen(g, "width",  H5P_DEFAULT);  H5Aread(a, H5T_NATIVE_INT64, &v); H5Aclose(a); out->width  = (NSUInteger)v;
    a = H5Aopen(g, "height", H5P_DEFAULT);  H5Aread(a, H5T_NATIVE_INT64, &v); H5Aclose(a); out->height = (NSUInteger)v;
    a = H5Aopen(g, "spectral_points", H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &v); H5Aclose(a); out->sp = (NSUInteger)v;
    a = H5Aopen(g, "tile_size",       H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &v); H5Aclose(a); out->tileSize = (NSUInteger)v;

    out->pixelSizeX = 0; out->pixelSizeY = 0; out->scanPattern = NULL;
    if (H5Aexists(g, "pixel_size_x") > 0) {
        a = H5Aopen(g, "pixel_size_x", H5P_DEFAULT);
        H5Aread(a, H5T_NATIVE_DOUBLE, &out->pixelSizeX); H5Aclose(a);
    }
    if (H5Aexists(g, "pixel_size_y") > 0) {
        a = H5Aopen(g, "pixel_size_y", H5P_DEFAULT);
        H5Aread(a, H5T_NATIVE_DOUBLE, &out->pixelSizeY); H5Aclose(a);
    }
    if (H5Aexists(g, "scan_pattern") > 0) {
        a = H5Aopen(g, "scan_pattern", H5P_DEFAULT);
        hid_t t = H5Aget_type(a);
        char *cs = NULL;
        H5Aread(a, t, &cs);
        if (cs) {
            out->scanPattern = strdup(cs);
            hid_t sp = H5Aget_space(a);
            H5Dvlen_reclaim(t, sp, H5P_DEFAULT, &cs);
            H5Sclose(sp);
        }
        H5Tclose(t);
        H5Aclose(a);
    }
}

static double readDoubleAttr(hid_t g, const char *name)
{
    if (H5Aexists(g, name) <= 0) return 0.0;
    hid_t a = H5Aopen(g, name, H5P_DEFAULT);
    double v = 0.0;
    H5Aread(a, H5T_NATIVE_DOUBLE, &v);
    H5Aclose(a);
    return v;
}

static NSData *readCube(hid_t g, NSUInteger w, NSUInteger h, NSUInteger sp,
                        NSError **error)
{
    hid_t did = H5Dopen2(g, "intensity", H5P_DEFAULT);
    if (did < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetOpen,
            @"intensity dataset missing");
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithLength:w*h*sp*sizeof(double)];
    herr_t s = H5Dread(did, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL,
                       H5P_DEFAULT, out.mutableBytes);
    H5Dclose(did);
    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
            @"intensity H5Dread failed");
        return nil;
    }
    return out;
}

static NSData *readWavenumbers(hid_t g, NSUInteger sp, NSError **error)
{
    hid_t did = H5Dopen2(g, "wavenumbers", H5P_DEFAULT);
    if (did < 0) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:sp*sizeof(double)];
    herr_t s = H5Dread(did, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL,
                       H5P_DEFAULT, out.mutableBytes);
    H5Dclose(did);
    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
            @"wavenumbers H5Dread failed");
        return nil;
    }
    return out;
}


#pragma mark - Persistence

- (BOOL)writeToFilePath:(NSString *)path error:(NSError **)error
{
    // Write dataset-level structure using TTIOSpectralDataset as a write helper,
    // then append the raman_image_cube group directly under /study/.
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                               title:self.title
                                  isaInvestigationId:self.isaInvestigationId
                                              msRuns:@{}
                                     identifications:self.identifications
                                     quantifications:self.quantifications
                                   provenanceRecords:self.provenanceRecords
                                               error:error];
    if (!ok) return NO;

    if (self.width == 0 || self.height == 0 || self.spectralPoints == 0) return YES;

    hid_t fid = H5Fopen([path fileSystemRepresentation],
                         H5F_ACC_RDWR, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen,
            @"H5Fopen RDWR failed for raman_image_cube append");
        return NO;
    }
    hid_t studyGid = H5Gopen2(fid, "study", H5P_DEFAULT);
    if (studyGid < 0) {
        H5Fclose(fid);
        if (error) *error = TTIOMakeError(TTIOErrorGroupOpen,
            @"H5Gopen2 /study failed");
        return NO;
    }
    ok = writeCubeGroup(studyGid,
                         TTIO_RAMAN_IMAGE_GROUP,
                         self.width, self.height, self.spectralPoints, self.tileSize,
                         self.pixelSizeX, self.pixelSizeY, self.scanPattern,
                         self.cube.bytes, _wavenumbers.bytes,
                         @{ @"excitation_wavelength_nm": @(_excitationWavelengthNm),
                            @"laser_power_mw":           @(_laserPowerMw) },
                         @{},
                         error);
    H5Gclose(studyGid);
    H5Fclose(fid);
    return ok;
}

+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error
{
    // Read dataset-level metadata via TTIOSpectralDataset, then
    // read the raman_image_cube group directly.
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:error];
    if (!ds) return nil;

    hid_t fid = H5Fopen([path fileSystemRepresentation],
                         H5F_ACC_RDONLY, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen, @"H5Fopen failed");
        return nil;
    }
    hid_t studyGid = H5Gopen2(fid, "study", H5P_DEFAULT);
    if (studyGid < 0 || H5Lexists(studyGid, TTIO_RAMAN_IMAGE_GROUP, H5P_DEFAULT) <= 0) {
        if (studyGid >= 0) H5Gclose(studyGid);
        H5Fclose(fid);
        return nil;  // No raman_image_cube in this file.
    }
    hid_t g = H5Gopen2(studyGid, TTIO_RAMAN_IMAGE_GROUP, H5P_DEFAULT);
    H5Gclose(studyGid);
    if (g < 0) {
        H5Fclose(fid);
        if (error) *error = TTIOMakeError(TTIOErrorGroupOpen, @"raman_image_cube open failed");
        return nil;
    }
    ttio_img_core_t meta; memset(&meta, 0, sizeof(meta));
    readCoreMeta(g, &meta);
    double excNm = readDoubleAttr(g, "excitation_wavelength_nm");
    double pwMw  = readDoubleAttr(g, "laser_power_mw");
    NSData *cube = readCube(g, meta.width, meta.height, meta.sp, error);
    NSData *wv   = readWavenumbers(g, meta.sp, error);
    H5Gclose(g);
    H5Fclose(fid);
    if (!cube || !wv) { if (meta.scanPattern) free(meta.scanPattern); return nil; }

    NSString *scanPat = meta.scanPattern
                          ? [[NSString alloc] initWithUTF8String:meta.scanPattern]
                          : @"";
    if (meta.scanPattern) free(meta.scanPattern);

    return [[TTIORamanImage alloc]
            initWithTitle:ds.title
       isaInvestigationId:ds.isaInvestigationId
          identifications:ds.identifications
          quantifications:ds.quantifications
        provenanceRecords:ds.provenanceRecords
                    width:meta.width height:meta.height
           spectralPoints:meta.sp tileSize:meta.tileSize
               pixelSizeX:meta.pixelSizeX pixelSizeY:meta.pixelSizeY
              scanPattern:scanPat
       excitationWavelengthNm:excNm laserPowerMw:pwMw
                         cube:cube wavenumbers:wv];
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIORamanImage class]]) return NO;
    TTIORamanImage *o = (TTIORamanImage *)other;
    return self.width == o.width
        && self.height == o.height
        && self.spectralPoints == o.spectralPoints
        && self.tileSize == o.tileSize
        && _excitationWavelengthNm == o.excitationWavelengthNm
        && _laserPowerMw == o.laserPowerMw
        && [self.cube isEqualToData:o.cube]
        && [_wavenumbers isEqualToData:o.wavenumbers];
}

- (NSUInteger)hash { return self.width ^ self.height ^ self.spectralPoints ^ [self.cube hash]; }

@end
