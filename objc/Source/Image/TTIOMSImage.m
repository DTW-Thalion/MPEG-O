/*
 * TTIOMSImage.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOMSImage
 * Inherits From: TTIOSpectralDataset : NSObject
 * Conforms To:   TTIOEncryptable (inherited)
 * Declared In:   Image/TTIOMSImage.h
 *
 * Mass-spectrometry imaging dataset (3-D cube of float64 spectral
 * profiles per pixel). Persists under /study/image_cube/ with
 * tile-aligned chunking; auto-detects the legacy /image_cube path
 * on read.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOMSImage.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <hdf5.h>
#import <sys/stat.h>

@implementation TTIOMSImage

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube
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
                          cube:cube];
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
                         cube:(NSData *)cube
{
    NSParameterAssert(cube.length == width * height * spectralPoints * sizeof(double));
    self = [super initWithTitle:title
             isaInvestigationId:isaId
                         msRuns:@{}
                        nmrRuns:@{}
                identifications:identifications
                quantifications:quantifications
              provenanceRecords:provenance
                    transitions:nil];
    if (self) {
        _width          = width;
        _height         = height;
        _spectralPoints = spectralPoints;
        _tileSize       = tileSize > 0 ? tileSize : 32;
        _pixelSizeX     = pixelSizeX;
        _pixelSizeY     = pixelSizeY;
        _scanPattern    = [scanPattern copy];
        _cube           = [cube copy];
    }
    return self;
}

#pragma mark - Internal: write/read the 3-D cube under a given group

static BOOL writeImageCubeUnderGroup(hid_t parentGid,
                                      NSUInteger width,
                                      NSUInteger height,
                                      NSUInteger sp,
                                      NSUInteger tileSize,
                                      double pxX, double pxY,
                                      NSString *scanPattern,
                                      const void *cubeBytes,
                                      NSError **error)
{
    hid_t imageGroup = H5Gcreate2(parentGid, "image_cube",
                                   H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (imageGroup < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorGroupCreate,
            @"H5Gcreate2 image_cube failed");
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

    hid_t did = H5Dcreate2(imageGroup, "intensity",
                           H5T_NATIVE_DOUBLE, space,
                           H5P_DEFAULT, plist, H5P_DEFAULT);
    if (did < 0) {
        H5Pclose(plist); H5Sclose(space); H5Gclose(imageGroup);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetCreate,
            @"H5Dcreate2 intensity failed");
        return NO;
    }

    herr_t s = H5Dwrite(did, H5T_NATIVE_DOUBLE,
                        H5S_ALL, H5S_ALL, H5P_DEFAULT, cubeBytes);
    if (s < 0) {
        H5Dclose(did); H5Pclose(plist); H5Sclose(space); H5Gclose(imageGroup);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetWrite,
            @"H5Dwrite intensity failed");
        return NO;
    }

    hid_t scalar = H5Screate(H5S_SCALAR);
    #define WRITE_INT_ATTR(name, val) do { \
        hid_t a = H5Acreate2(imageGroup, (name), H5T_NATIVE_INT64, \
                              scalar, H5P_DEFAULT, H5P_DEFAULT); \
        int64_t v = (int64_t)(val); H5Awrite(a, H5T_NATIVE_INT64, &v); H5Aclose(a); \
    } while (0)
    #define WRITE_DBL_ATTR(name, val) do { \
        hid_t a = H5Acreate2(imageGroup, (name), H5T_NATIVE_DOUBLE, \
                              scalar, H5P_DEFAULT, H5P_DEFAULT); \
        double v = (val); H5Awrite(a, H5T_NATIVE_DOUBLE, &v); H5Aclose(a); \
    } while (0)

    WRITE_INT_ATTR("width",           width);
    WRITE_INT_ATTR("height",          height);
    WRITE_INT_ATTR("spectral_points", sp);
    WRITE_INT_ATTR("tile_size",       tileSize);
    WRITE_DBL_ATTR("pixel_size_x",    pxX);
    WRITE_DBL_ATTR("pixel_size_y",    pxY);

    // scan_pattern as a variable-length string attribute
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

    #undef WRITE_INT_ATTR
    #undef WRITE_DBL_ATTR

    H5Sclose(scalar);
    H5Dclose(did); H5Pclose(plist); H5Sclose(space); H5Gclose(imageGroup);
    return YES;
}

typedef struct {
    NSUInteger width, height, sp, tileSize;
    double pixelSizeX, pixelSizeY;
    char *scanPattern;   // owned, must free
} ttio_image_meta_t;

static BOOL readImageMetaFromGroup(hid_t imageGroup,
                                    ttio_image_meta_t *out)
{
    int64_t v;
    hid_t a;
    a = H5Aopen(imageGroup, "width",  H5P_DEFAULT);  H5Aread(a, H5T_NATIVE_INT64, &v); H5Aclose(a); out->width  = (NSUInteger)v;
    a = H5Aopen(imageGroup, "height", H5P_DEFAULT);  H5Aread(a, H5T_NATIVE_INT64, &v); H5Aclose(a); out->height = (NSUInteger)v;
    a = H5Aopen(imageGroup, "spectral_points", H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &v); H5Aclose(a); out->sp = (NSUInteger)v;
    a = H5Aopen(imageGroup, "tile_size",       H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &v); H5Aclose(a); out->tileSize = (NSUInteger)v;

    out->pixelSizeX = 0.0;
    out->pixelSizeY = 0.0;
    if (H5Aexists(imageGroup, "pixel_size_x") > 0) {
        a = H5Aopen(imageGroup, "pixel_size_x", H5P_DEFAULT);
        H5Aread(a, H5T_NATIVE_DOUBLE, &out->pixelSizeX); H5Aclose(a);
    }
    if (H5Aexists(imageGroup, "pixel_size_y") > 0) {
        a = H5Aopen(imageGroup, "pixel_size_y", H5P_DEFAULT);
        H5Aread(a, H5T_NATIVE_DOUBLE, &out->pixelSizeY); H5Aclose(a);
    }

    out->scanPattern = NULL;
    if (H5Aexists(imageGroup, "scan_pattern") > 0) {
        a = H5Aopen(imageGroup, "scan_pattern", H5P_DEFAULT);
        hid_t t = H5Aget_type(a);
        char *cs = NULL;
        H5Aread(a, t, &cs);
        if (cs) {
            out->scanPattern = strdup(cs);
            hid_t aSpace = H5Aget_space(a);
            H5Dvlen_reclaim(t, aSpace, H5P_DEFAULT, &cs);
            H5Sclose(aSpace);
        }
        H5Tclose(t);
        H5Aclose(a);
    }
    return YES;
}

static NSData *readImageCubeFromGroup(hid_t imageGroup,
                                       NSUInteger w, NSUInteger h, NSUInteger sp,
                                       NSError **error)
{
    hid_t did = H5Dopen2(imageGroup, "intensity", H5P_DEFAULT);
    if (did < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetOpen,
            @"intensity dataset missing");
        return nil;
    }
    NSUInteger total = w * h * sp;
    NSMutableData *cube = [NSMutableData dataWithLength:total * sizeof(double)];
    herr_t s = H5Dread(did, H5T_NATIVE_DOUBLE,
                       H5S_ALL, H5S_ALL, H5P_DEFAULT, cube.mutableBytes);
    H5Dclose(did);
    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead,
            @"intensity H5Dread failed");
        return nil;
    }
    return cube;
}

#pragma mark - TTIOSpectralDataset hooks

- (BOOL)writeAdditionalStudyContent:(TTIOHDF5Group *)studyGroup
                              error:(NSError **)error
{
    if (_width == 0 || _height == 0 || _spectralPoints == 0) return YES;
    return writeImageCubeUnderGroup(studyGroup.groupId,
                                     _width, _height, _spectralPoints, _tileSize,
                                     _pixelSizeX, _pixelSizeY, _scanPattern,
                                     _cube.bytes, error);
}

- (BOOL)readAdditionalStudyContent:(TTIOHDF5Group *)studyGroup
                             error:(NSError **)error
{
    if (![studyGroup hasChildNamed:@"image_cube"]) return YES;
    hid_t imageGroup = H5Gopen2(studyGroup.groupId, "image_cube", H5P_DEFAULT);
    if (imageGroup < 0) return YES;

    ttio_image_meta_t meta;
    memset(&meta, 0, sizeof(meta));
    readImageMetaFromGroup(imageGroup, &meta);

    NSData *cube = readImageCubeFromGroup(imageGroup, meta.width, meta.height, meta.sp, error);
    H5Gclose(imageGroup);
    if (!cube) { if (meta.scanPattern) free(meta.scanPattern); return NO; }

    _width          = meta.width;
    _height         = meta.height;
    _spectralPoints = meta.sp;
    _tileSize       = meta.tileSize;
    _pixelSizeX     = meta.pixelSizeX;
    _pixelSizeY     = meta.pixelSizeY;
    _scanPattern    = meta.scanPattern
                        ? [[NSString alloc] initWithUTF8String:meta.scanPattern]
                        : @"";
    if (meta.scanPattern) free(meta.scanPattern);
    _cube           = [cube copy];
    return YES;
}

#pragma mark - Read with v0.1 fallback

+ (instancetype)readFromFilePath:(NSString *)path error:(NSError **)error
{
    // Legacy v0.1 detection: if the file has /image_cube at root but
    // no /study group, bypass the TTIOSpectralDataset reader entirely
    // and load just the cube. This keeps v0.1 MSImage files readable
    // after the M12 subclass refactor.
    hid_t probe = H5Fopen([path fileSystemRepresentation],
                           H5F_ACC_RDONLY, H5P_DEFAULT);
    if (probe >= 0) {
        BOOL hasStudy = (H5Lexists(probe, "study", H5P_DEFAULT) > 0);
        BOOL hasRootImage = (H5Lexists(probe, "image_cube", H5P_DEFAULT) > 0);
        if (!hasStudy && hasRootImage) {
            hid_t legacyGroup = H5Gopen2(probe, "image_cube", H5P_DEFAULT);
            ttio_image_meta_t meta; memset(&meta, 0, sizeof(meta));
            readImageMetaFromGroup(legacyGroup, &meta);
            NSData *cube = readImageCubeFromGroup(legacyGroup,
                                                    meta.width, meta.height, meta.sp,
                                                    error);
            H5Gclose(legacyGroup);
            H5Fclose(probe);
            if (!cube) return nil;
            TTIOMSImage *img = [[TTIOMSImage alloc]
                                 initWithWidth:meta.width
                                        height:meta.height
                                spectralPoints:meta.sp
                                      tileSize:meta.tileSize
                                          cube:cube];
            if (meta.scanPattern) free(meta.scanPattern);
            return img;
        }
        H5Fclose(probe);
    }

    // v0.2 path: super reader invokes -readAdditionalStudyContent:
    // which populates the image fields from /study/image_cube.
    return (TTIOMSImage *)[super readFromFilePath:path error:error];
}

#pragma mark - Tile read

+ (NSData *)readTileFromFilePath:(NSString *)path
                             atX:(NSUInteger)x
                               y:(NSUInteger)y
                           width:(NSUInteger)tw
                          height:(NSUInteger)th
                           error:(NSError **)error
{
    hid_t fid = H5Fopen([path fileSystemRepresentation],
                        H5F_ACC_RDONLY, H5P_DEFAULT);
    if (fid < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorFileOpen, @"H5Fopen failed");
        return nil;
    }

    // Prefer /study/image_cube, fall back to /image_cube.
    hid_t imageGroup = -1;
    if (H5Lexists(fid, "study", H5P_DEFAULT) > 0) {
        hid_t study = H5Gopen2(fid, "study", H5P_DEFAULT);
        if (H5Lexists(study, "image_cube", H5P_DEFAULT) > 0) {
            imageGroup = H5Gopen2(study, "image_cube", H5P_DEFAULT);
        }
        H5Gclose(study);
    }
    if (imageGroup < 0 && H5Lexists(fid, "image_cube", H5P_DEFAULT) > 0) {
        imageGroup = H5Gopen2(fid, "image_cube", H5P_DEFAULT);
    }
    if (imageGroup < 0) {
        H5Fclose(fid);
        if (error) *error = TTIOMakeError(TTIOErrorGroupOpen, @"image_cube missing");
        return nil;
    }

    int64_t sp = 0;
    hid_t a = H5Aopen(imageGroup, "spectral_points", H5P_DEFAULT);
    H5Aread(a, H5T_NATIVE_INT64, &sp); H5Aclose(a);

    hid_t did = H5Dopen2(imageGroup, "intensity", H5P_DEFAULT);
    if (did < 0) {
        H5Gclose(imageGroup); H5Fclose(fid);
        if (error) *error = TTIOMakeError(TTIOErrorDatasetOpen,
            @"intensity dataset missing");
        return nil;
    }

    hid_t fspace = H5Dget_space(did);
    hsize_t off[3] = { (hsize_t)y,  (hsize_t)x,  0 };
    hsize_t cnt[3] = { (hsize_t)th, (hsize_t)tw, (hsize_t)sp };
    H5Sselect_hyperslab(fspace, H5S_SELECT_SET, off, NULL, cnt, NULL);

    hid_t mspace = H5Screate_simple(3, cnt, NULL);

    NSUInteger total = (NSUInteger)(th * tw * sp);
    NSMutableData *out = [NSMutableData dataWithLength:total * sizeof(double)];
    herr_t s = H5Dread(did, H5T_NATIVE_DOUBLE, mspace, fspace,
                       H5P_DEFAULT, out.mutableBytes);

    H5Sclose(mspace); H5Sclose(fspace); H5Dclose(did);
    H5Gclose(imageGroup); H5Fclose(fid);

    if (s < 0) {
        if (error) *error = TTIOMakeError(TTIOErrorDatasetRead, @"tile H5Dread failed");
        return nil;
    }
    return out;
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIOMSImage class]]) return NO;
    TTIOMSImage *o = (TTIOMSImage *)other;
    return _width == o.width
        && _height == o.height
        && _spectralPoints == o.spectralPoints
        && _tileSize == o.tileSize
        && [_cube isEqualToData:o.cube];
}

- (NSUInteger)hash { return _width ^ _height ^ _spectralPoints ^ [_cube hash]; }

@end
