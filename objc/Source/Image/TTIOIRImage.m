/*
 * TTIOIRImage.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOIRImage
 * Inherits From: NSObject  (composition pattern - dataset-level fields owned directly)
 * Declared In:   Image/TTIOIRImage.h
 *
 * Mid-IR imaging dataset (transmittance or absorbance). 3-D cube +
 * shared 1-D wavenumbers axis; persists under
 * /study/ir_image_cube/.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOIRImage.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <hdf5.h>

#define TTIO_IR_IMAGE_GROUP "ir_image_cube"

@implementation TTIOIRImage

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers
                         mode:(TTIOIRMode)mode
              resolutionCmInv:(double)resolutionCmInv
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
                          mode:mode
               resolutionCmInv:resolutionCmInv
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
                         mode:(TTIOIRMode)mode
              resolutionCmInv:(double)resolutionCmInv
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers
{
    NSParameterAssert(cube.length == width * height * spectralPoints * sizeof(double));
    NSParameterAssert(wavenumbers.length == spectralPoints * sizeof(double));
    self = [super init];
    if (self) {
        _title              = [title copy];
        _isaInvestigationId = [isaId copy];
        _identifications    = [identifications copy] ?: @[];
        _quantifications    = [quantifications copy] ?: @[];
        _provenanceRecords  = [provenance copy] ?: @[];
        _width           = width;
        _height          = height;
        _spectralPoints  = spectralPoints;
        _tileSize        = tileSize > 0 ? tileSize : 32;
        _pixelSizeX      = pixelSizeX;
        _pixelSizeY      = pixelSizeY;
        _scanPattern     = [scanPattern copy];
        _mode            = mode;
        _resolutionCmInv = resolutionCmInv;
        _cube            = [cube copy];
        _wavenumbers     = [wavenumbers copy];
    }
    return self;
}

#pragma mark - HDF5 helpers (ir-image-cube local)

static BOOL writeIRCube(hid_t parentGid,
                        NSUInteger width, NSUInteger height,
                        NSUInteger sp, NSUInteger tileSize,
                        double pxX, double pxY,
                        NSString *scanPattern,
                        TTIOIRMode mode,
                        double resolution,
                        const void *cubeBytes,
                        const void *wavenumberBytes,
                        NSError **error)
{
    hid_t g = H5Gcreate2(parentGid, TTIO_IR_IMAGE_GROUP,
                          H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (g < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorGroupCreate,
            @"H5Gcreate2 ir_image_cube failed");
        return NO;
    }

    hsize_t dims[3]  = { (hsize_t)height, (hsize_t)width, (hsize_t)sp };
    hsize_t chunk[3] = { (hsize_t)MIN(tileSize, height),
                         (hsize_t)MIN(tileSize, width),
                         (hsize_t)sp };

    hid_t space = H5Screate_simple(3, dims, NULL);
    hid_t plist = H5Pcreate(H5P_DATASET_CREATE);
    H5Pset_chunk(plist, 3, chunk);
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
    #define WRITE_STR(name, val) do { \
        hid_t t = H5Tcopy(H5T_C_S1); H5Tset_size(t, H5T_VARIABLE); \
        hid_t a = H5Acreate2(g, (name), t, scalar, H5P_DEFAULT, H5P_DEFAULT); \
        const char *cs = [(val) UTF8String]; H5Awrite(a, t, &cs); \
        H5Aclose(a); H5Tclose(t); \
    } while (0)

    WRITE_INT("width",           width);
    WRITE_INT("height",          height);
    WRITE_INT("spectral_points", sp);
    WRITE_INT("tile_size",       tileSize);
    WRITE_DBL("pixel_size_x",    pxX);
    WRITE_DBL("pixel_size_y",    pxY);
    WRITE_DBL("resolution_cm_inv", resolution);
    WRITE_STR("ir_mode",
              (mode == TTIOIRModeAbsorbance) ? @"absorbance" : @"transmittance");
    WRITE_STR("scan_pattern", (scanPattern ?: @""));

    #undef WRITE_INT
    #undef WRITE_DBL
    #undef WRITE_STR
    H5Sclose(scalar);
    H5Gclose(g);
    return YES;
}

- (BOOL)writeToFilePath:(NSString *)path error:(NSError **)error
{
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                               title:_title
                                  isaInvestigationId:_isaInvestigationId
                                              msRuns:@{}
                                     identifications:_identifications
                                     quantifications:_quantifications
                                   provenanceRecords:_provenanceRecords
                                               error:error];
    if (!ok) return NO;
    if (_width == 0 || _height == 0 || _spectralPoints == 0) return YES;
    hid_t fid = H5Fopen([path fileSystemRepresentation], H5F_ACC_RDWR, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen, @"H5Fopen RDWR failed");
        return NO;
    }
    hid_t studyGid = H5Gopen2(fid, "study", H5P_DEFAULT);
    if (studyGid < 0) { H5Fclose(fid);
        if (error) *error = TTIOMakeError(TTIOErrorGroupOpen, @"H5Gopen2 /study failed");
        return NO;
    }
    ok = writeIRCube(studyGid,
                      _width, _height, _spectralPoints, _tileSize,
                      _pixelSizeX, _pixelSizeY, _scanPattern,
                      _mode, _resolutionCmInv,
                      _cube.bytes, _wavenumbers.bytes, error);
    H5Gclose(studyGid);
    H5Fclose(fid);
    return ok;
}

+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error
{
    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path error:error];
    if (!ds) return nil;
    hid_t fid = H5Fopen([path fileSystemRepresentation], H5F_ACC_RDONLY, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen, @"H5Fopen failed");
        return nil;
    }
    hid_t studyGid = H5Gopen2(fid, "study", H5P_DEFAULT);
    if (studyGid < 0 || H5Lexists(studyGid, TTIO_IR_IMAGE_GROUP, H5P_DEFAULT) <= 0) {
        if (studyGid >= 0) H5Gclose(studyGid);
        H5Fclose(fid);
        return nil;
    }
    hid_t g = H5Gopen2(studyGid, TTIO_IR_IMAGE_GROUP, H5P_DEFAULT);
    H5Gclose(studyGid);
    if (g < 0) { H5Fclose(fid);
        if (error) *error = TTIOMakeError(TTIOErrorGroupOpen, @"ir_image_cube open failed");
        return nil;
    }
    int64_t vi; double vd; hid_t a;
    NSUInteger rWidth, rHeight, rSp, rTileSize;
    a = H5Aopen(g, "width",           H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &vi); H5Aclose(a); rWidth  = (NSUInteger)vi;
    a = H5Aopen(g, "height",          H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &vi); H5Aclose(a); rHeight = (NSUInteger)vi;
    a = H5Aopen(g, "spectral_points", H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &vi); H5Aclose(a); rSp = (NSUInteger)vi;
    a = H5Aopen(g, "tile_size",       H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &vi); H5Aclose(a); rTileSize = (NSUInteger)vi;
    double pxX = 0, pxY = 0, resCmInv = 0;
    if (H5Aexists(g, "pixel_size_x") > 0)      { a = H5Aopen(g, "pixel_size_x",      H5P_DEFAULT); H5Aread(a, H5T_NATIVE_DOUBLE, &vd); H5Aclose(a); pxX = vd; }
    if (H5Aexists(g, "pixel_size_y") > 0)      { a = H5Aopen(g, "pixel_size_y",      H5P_DEFAULT); H5Aread(a, H5T_NATIVE_DOUBLE, &vd); H5Aclose(a); pxY = vd; }
    if (H5Aexists(g, "resolution_cm_inv") > 0) { a = H5Aopen(g, "resolution_cm_inv", H5P_DEFAULT); H5Aread(a, H5T_NATIVE_DOUBLE, &vd); H5Aclose(a); resCmInv = vd; }
    TTIOIRMode rMode = TTIOIRModeTransmittance;
    if (H5Aexists(g, "ir_mode") > 0) {
        a = H5Aopen(g, "ir_mode", H5P_DEFAULT); hid_t t = H5Aget_type(a);
        char *cs = NULL; H5Aread(a, t, &cs);
        if (cs && strcmp(cs, "absorbance") == 0) rMode = TTIOIRModeAbsorbance;
        if (cs) { hid_t ssp = H5Aget_space(a); H5Dvlen_reclaim(t, ssp, H5P_DEFAULT, &cs); H5Sclose(ssp); }
        H5Tclose(t); H5Aclose(a);
    }
    NSString *scanPat = @"";
    if (H5Aexists(g, "scan_pattern") > 0) {
        a = H5Aopen(g, "scan_pattern", H5P_DEFAULT); hid_t t = H5Aget_type(a);
        char *cs = NULL; H5Aread(a, t, &cs);
        if (cs) { scanPat = [[NSString alloc] initWithUTF8String:cs];
                  hid_t ssp = H5Aget_space(a); H5Dvlen_reclaim(t, ssp, H5P_DEFAULT, &cs); H5Sclose(ssp); }
        H5Tclose(t); H5Aclose(a);
    }
    hid_t did = H5Dopen2(g, "intensity", H5P_DEFAULT);
    if (did < 0) { H5Gclose(g); H5Fclose(fid);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetOpen, @"intensity dataset missing");
        return nil;
    }
    NSMutableData *cube = [NSMutableData dataWithLength:rWidth*rHeight*rSp*sizeof(double)];
    herr_t hs = H5Dread(did, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, cube.mutableBytes);
    H5Dclose(did);
    if (hs < 0) { H5Gclose(g); H5Fclose(fid);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead, @"intensity H5Dread failed");
        return nil;
    }
    hid_t wDid = H5Dopen2(g, "wavenumbers", H5P_DEFAULT);
    if (wDid < 0) { H5Gclose(g); H5Fclose(fid); return nil; }
    NSMutableData *wv = [NSMutableData dataWithLength:rSp*sizeof(double)];
    H5Dread(wDid, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, wv.mutableBytes);
    H5Dclose(wDid); H5Gclose(g); H5Fclose(fid);
    return [[TTIOIRImage alloc]
            initWithTitle:ds.title
       isaInvestigationId:ds.isaInvestigationId
          identifications:ds.identifications
          quantifications:ds.quantifications
        provenanceRecords:ds.provenanceRecords
                    width:rWidth height:rHeight
           spectralPoints:rSp tileSize:rTileSize
               pixelSizeX:pxX pixelSizeY:pxY
              scanPattern:scanPat mode:rMode
             resolutionCmInv:resCmInv
                         cube:[cube copy] wavenumbers:[wv copy]];
}
- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOIRImage class]]) return NO;
    TTIOIRImage *o = (TTIOIRImage *)other;
    return _width == o.width
        && _height == o.height
        && _spectralPoints == o.spectralPoints
        && _tileSize == o.tileSize
        && _mode == o.mode
        && _resolutionCmInv == o.resolutionCmInv
        && [_cube isEqualToData:o.cube]
        && [_wavenumbers isEqualToData:o.wavenumbers];
}

- (NSUInteger)hash { return _width ^ _height ^ _spectralPoints ^ [_cube hash]; }

@end
