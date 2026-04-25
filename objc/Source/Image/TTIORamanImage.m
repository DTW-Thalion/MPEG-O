#import "TTIORamanImage.h"
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
                         msRuns:@{}
                        nmrRuns:@{}
                identifications:identifications
                quantifications:quantifications
              provenanceRecords:provenance
                    transitions:nil];
    if (self) {
        _width                  = width;
        _height                 = height;
        _spectralPoints         = spectralPoints;
        _tileSize               = tileSize > 0 ? tileSize : 32;
        _pixelSizeX             = pixelSizeX;
        _pixelSizeY             = pixelSizeY;
        _scanPattern            = [scanPattern copy];
        _excitationWavelengthNm = excitationNm;
        _laserPowerMw           = laserPowerMw;
        _cube                   = [cube copy];
        _wavenumbers            = [wavenumbers copy];
    }
    return self;
}

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

#pragma mark - TTIOSpectralDataset hooks

- (BOOL)writeAdditionalStudyContent:(TTIOHDF5Group *)studyGroup
                              error:(NSError **)error
{
    if (_width == 0 || _height == 0 || _spectralPoints == 0) return YES;
    return writeCubeGroup(studyGroup.groupId,
                           TTIO_RAMAN_IMAGE_GROUP,
                           _width, _height, _spectralPoints, _tileSize,
                           _pixelSizeX, _pixelSizeY, _scanPattern,
                           _cube.bytes, _wavenumbers.bytes,
                           @{ @"excitation_wavelength_nm": @(_excitationWavelengthNm),
                              @"laser_power_mw":           @(_laserPowerMw) },
                           @{},
                           error);
}

- (BOOL)readAdditionalStudyContent:(TTIOHDF5Group *)studyGroup
                             error:(NSError **)error
{
    if (![studyGroup hasChildNamed:@TTIO_RAMAN_IMAGE_GROUP]) return YES;
    hid_t g = H5Gopen2(studyGroup.groupId, TTIO_RAMAN_IMAGE_GROUP, H5P_DEFAULT);
    if (g < 0) return YES;

    ttio_img_core_t meta; memset(&meta, 0, sizeof(meta));
    readCoreMeta(g, &meta);
    double excNm = readDoubleAttr(g, "excitation_wavelength_nm");
    double pwMw  = readDoubleAttr(g, "laser_power_mw");

    NSData *cube = readCube(g, meta.width, meta.height, meta.sp, error);
    NSData *wv   = readWavenumbers(g, meta.sp, error);
    H5Gclose(g);
    if (!cube || !wv) { if (meta.scanPattern) free(meta.scanPattern); return NO; }

    _width                  = meta.width;
    _height                 = meta.height;
    _spectralPoints         = meta.sp;
    _tileSize               = meta.tileSize;
    _pixelSizeX             = meta.pixelSizeX;
    _pixelSizeY             = meta.pixelSizeY;
    _scanPattern            = meta.scanPattern
                                ? [[NSString alloc] initWithUTF8String:meta.scanPattern]
                                : @"";
    if (meta.scanPattern) free(meta.scanPattern);
    _excitationWavelengthNm = excNm;
    _laserPowerMw           = pwMw;
    _cube                   = [cube copy];
    _wavenumbers            = [wv copy];
    return YES;
}

#pragma mark - Equality

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[TTIORamanImage class]]) return NO;
    TTIORamanImage *o = (TTIORamanImage *)other;
    return _width == o.width
        && _height == o.height
        && _spectralPoints == o.spectralPoints
        && _tileSize == o.tileSize
        && _excitationWavelengthNm == o.excitationWavelengthNm
        && _laserPowerMw == o.laserPowerMw
        && [_cube isEqualToData:o.cube]
        && [_wavenumbers isEqualToData:o.wavenumbers];
}

- (NSUInteger)hash { return _width ^ _height ^ _spectralPoints ^ [_cube hash]; }

@end
