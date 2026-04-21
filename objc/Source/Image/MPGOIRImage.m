#import "MPGOIRImage.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Errors.h"
#import <hdf5.h>

#define MPGO_IR_IMAGE_GROUP "ir_image_cube"

@implementation MPGOIRImage

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                         cube:(NSData *)cube
                  wavenumbers:(NSData *)wavenumbers
                         mode:(MPGOIRMode)mode
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
                         mode:(MPGOIRMode)mode
              resolutionCmInv:(double)resolutionCmInv
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
                        MPGOIRMode mode,
                        double resolution,
                        const void *cubeBytes,
                        const void *wavenumberBytes,
                        NSError **error)
{
    hid_t g = H5Gcreate2(parentGid, MPGO_IR_IMAGE_GROUP,
                          H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
    if (g < 0) {
        if (error) *error = MPGOMakeError(MPGOErrorGroupCreate,
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
        if (error) *error = MPGOMakeError(MPGOErrorDatasetCreate,
            @"H5Dcreate2 intensity failed");
        return NO;
    }
    herr_t s = H5Dwrite(did, H5T_NATIVE_DOUBLE,
                        H5S_ALL, H5S_ALL, H5P_DEFAULT, cubeBytes);
    H5Dclose(did); H5Pclose(plist); H5Sclose(space);
    if (s < 0) {
        H5Gclose(g);
        if (error) *error = MPGOMakeError(MPGOErrorDatasetWrite,
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
              (mode == MPGOIRModeAbsorbance) ? @"absorbance" : @"transmittance");
    WRITE_STR("scan_pattern", (scanPattern ?: @""));

    #undef WRITE_INT
    #undef WRITE_DBL
    #undef WRITE_STR
    H5Sclose(scalar);
    H5Gclose(g);
    return YES;
}

- (BOOL)writeAdditionalStudyContent:(MPGOHDF5Group *)studyGroup
                              error:(NSError **)error
{
    if (_width == 0 || _height == 0 || _spectralPoints == 0) return YES;
    return writeIRCube(studyGroup.groupId,
                        _width, _height, _spectralPoints, _tileSize,
                        _pixelSizeX, _pixelSizeY, _scanPattern,
                        _mode, _resolutionCmInv,
                        _cube.bytes, _wavenumbers.bytes, error);
}

- (BOOL)readAdditionalStudyContent:(MPGOHDF5Group *)studyGroup
                             error:(NSError **)error
{
    if (![studyGroup hasChildNamed:@MPGO_IR_IMAGE_GROUP]) return YES;
    hid_t g = H5Gopen2(studyGroup.groupId, MPGO_IR_IMAGE_GROUP, H5P_DEFAULT);
    if (g < 0) return YES;

    int64_t vi; double vd;
    hid_t a;
    a = H5Aopen(g, "width",           H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &vi); H5Aclose(a); _width  = (NSUInteger)vi;
    a = H5Aopen(g, "height",          H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &vi); H5Aclose(a); _height = (NSUInteger)vi;
    a = H5Aopen(g, "spectral_points", H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &vi); H5Aclose(a); _spectralPoints = (NSUInteger)vi;
    a = H5Aopen(g, "tile_size",       H5P_DEFAULT); H5Aread(a, H5T_NATIVE_INT64, &vi); H5Aclose(a); _tileSize = (NSUInteger)vi;

    _pixelSizeX = 0; _pixelSizeY = 0;
    if (H5Aexists(g, "pixel_size_x") > 0) {
        a = H5Aopen(g, "pixel_size_x", H5P_DEFAULT);
        H5Aread(a, H5T_NATIVE_DOUBLE, &vd); H5Aclose(a); _pixelSizeX = vd;
    }
    if (H5Aexists(g, "pixel_size_y") > 0) {
        a = H5Aopen(g, "pixel_size_y", H5P_DEFAULT);
        H5Aread(a, H5T_NATIVE_DOUBLE, &vd); H5Aclose(a); _pixelSizeY = vd;
    }
    _resolutionCmInv = 0;
    if (H5Aexists(g, "resolution_cm_inv") > 0) {
        a = H5Aopen(g, "resolution_cm_inv", H5P_DEFAULT);
        H5Aread(a, H5T_NATIVE_DOUBLE, &vd); H5Aclose(a); _resolutionCmInv = vd;
    }
    _mode = MPGOIRModeTransmittance;
    if (H5Aexists(g, "ir_mode") > 0) {
        a = H5Aopen(g, "ir_mode", H5P_DEFAULT);
        hid_t t = H5Aget_type(a);
        char *cs = NULL; H5Aread(a, t, &cs);
        if (cs && strcmp(cs, "absorbance") == 0) _mode = MPGOIRModeAbsorbance;
        if (cs) {
            hid_t sp = H5Aget_space(a);
            H5Dvlen_reclaim(t, sp, H5P_DEFAULT, &cs);
            H5Sclose(sp);
        }
        H5Tclose(t); H5Aclose(a);
    }
    _scanPattern = @"";
    if (H5Aexists(g, "scan_pattern") > 0) {
        a = H5Aopen(g, "scan_pattern", H5P_DEFAULT);
        hid_t t = H5Aget_type(a);
        char *cs = NULL; H5Aread(a, t, &cs);
        if (cs) {
            _scanPattern = [[NSString alloc] initWithUTF8String:cs];
            hid_t sp = H5Aget_space(a);
            H5Dvlen_reclaim(t, sp, H5P_DEFAULT, &cs);
            H5Sclose(sp);
        }
        H5Tclose(t); H5Aclose(a);
    }

    hid_t did = H5Dopen2(g, "intensity", H5P_DEFAULT);
    if (did < 0) {
        H5Gclose(g);
        if (error) *error = MPGOMakeError(MPGOErrorDatasetOpen,
            @"intensity dataset missing");
        return NO;
    }
    NSMutableData *cube = [NSMutableData dataWithLength:_width*_height*_spectralPoints*sizeof(double)];
    herr_t s = H5Dread(did, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL,
                       H5P_DEFAULT, cube.mutableBytes);
    H5Dclose(did);
    if (s < 0) {
        H5Gclose(g);
        if (error) *error = MPGOMakeError(MPGOErrorDatasetRead,
            @"intensity H5Dread failed");
        return NO;
    }
    _cube = [cube copy];

    hid_t wDid = H5Dopen2(g, "wavenumbers", H5P_DEFAULT);
    if (wDid < 0) { H5Gclose(g); return NO; }
    NSMutableData *wv = [NSMutableData dataWithLength:_spectralPoints*sizeof(double)];
    H5Dread(wDid, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, wv.mutableBytes);
    H5Dclose(wDid);
    _wavenumbers = [wv copy];

    H5Gclose(g);
    return YES;
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[MPGOIRImage class]]) return NO;
    MPGOIRImage *o = (MPGOIRImage *)other;
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
