/*
 * TestIRImageWriteReadTypedAttrs.m
 *
 * Stage 5.6 cross-language conformance follow-up: verify that
 * -[TTIOIRImage writeToFilePath:] now writes ir_mode as a typed
 * H5T_NATIVE_INT64 enum (0=transmittance, 1=absorbance) instead of
 * the legacy VL string, and that the reader still accepts the legacy
 * VL-string wire-form for backward compat with pre-fix .tio files.
 *
 * Mirrors java/.../IRImageWriteReadTypedAttrsTest.java; companion
 * fix to commit 56f54fdf (xlang accessor matrix surfaced 8 skipped
 * IR_IMAGE cells, all caused by this attr-type drift).
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Image/TTIOIRImage.h"
#import "ValueClasses/TTIOEnums.h"
#import <hdf5.h>
#include <unistd.h>

static NSString *makeTempPath(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_irtyped_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:base];
}

static TTIOIRImage *buildFixture(TTIOIRMode mode, double resolution)
{
    const NSUInteger w = 2, h = 2, s = 3;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    double *p = (double *)cube.mutableBytes;
    for (NSUInteger i = 0; i < w * h * s; i++) p[i] = (double)i * 0.125;
    NSMutableData *wn = [NSMutableData dataWithLength:s * sizeof(double)];
    double *wnp = (double *)wn.mutableBytes;
    for (NSUInteger i = 0; i < s; i++) wnp[i] = 1000.0 + (double)i * 4.0;
    return [[TTIOIRImage alloc]
                initWithTitle:@""
           isaInvestigationId:@""
              identifications:@[]
              quantifications:@[]
            provenanceRecords:@[]
                        width:w
                       height:h
               spectralPoints:s
                     tileSize:2
                   pixelSizeX:0.5
                   pixelSizeY:0.5
                  scanPattern:@"raster"
                         mode:mode
              resolutionCmInv:resolution
                         cube:cube
                  wavenumbers:wn];
}

// Probe the HDF5 type class (H5T_INTEGER / H5T_FLOAT / H5T_STRING)
// of a named scalar attribute on /study/ir_image_cube.
static H5T_class_t attrTypeClass(NSString *path, const char *name)
{
    hid_t fid = H5Fopen([path fileSystemRepresentation], H5F_ACC_RDONLY, H5P_DEFAULT);
    hid_t g = H5Gopen2(fid, "/study/ir_image_cube", H5P_DEFAULT);
    hid_t a = H5Aopen(g, name, H5P_DEFAULT);
    hid_t t = H5Aget_type(a);
    H5T_class_t cls = H5Tget_class(t);
    H5Tclose(t); H5Aclose(a); H5Gclose(g); H5Fclose(fid);
    return cls;
}

// ─── 1. Typed wire-form: writer emits f64/i64; round-trips. ─────────────
static void testTypedAttrsRoundTrip(void)
{
    TTIOIRImage *img = buildFixture(TTIOIRModeAbsorbance, 4.0);
    NSString *path = makeTempPath(@"rt");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:path error:&err] && err == nil,
         "typed-attrs: writeToFilePath: succeeded");

    // Probe raw HDF5 wire types.
    PASS(attrTypeClass(path, "pixel_size_x") == H5T_FLOAT,
         "typed-attrs: pixel_size_x stored as H5T_FLOAT");
    PASS(attrTypeClass(path, "pixel_size_y") == H5T_FLOAT,
         "typed-attrs: pixel_size_y stored as H5T_FLOAT");
    PASS(attrTypeClass(path, "resolution_cm_inv") == H5T_FLOAT,
         "typed-attrs: resolution_cm_inv stored as H5T_FLOAT");
    PASS(attrTypeClass(path, "ir_mode") == H5T_INTEGER,
         "typed-attrs: ir_mode stored as H5T_INTEGER (i64) — Python/Java parity");

    // Read back and verify.
    TTIOIRImage *back = [TTIOIRImage readFromFilePath:path error:&err];
    PASS(back != nil && err == nil, "typed-attrs: readFromFilePath: succeeded");
    PASS(back.mode == TTIOIRModeAbsorbance, "typed-attrs: ir_mode (ABSORBANCE) round-trip");
    PASS(back.resolutionCmInv == 4.0, "typed-attrs: resolution_cm_inv round-trip");
    PASS(back.pixelSizeX == 0.5 && back.pixelSizeY == 0.5,
         "typed-attrs: pixel_size_x/y round-trip");
    PASS([back.cube isEqualToData:img.cube], "typed-attrs: cube byte-equal");

    unlink([path fileSystemRepresentation]);
}

// ─── 2. TRANSMITTANCE round-trips as i64 = 0. ────────────────────────────
static void testTransmittanceI64Zero(void)
{
    TTIOIRImage *img = buildFixture(TTIOIRModeTransmittance, 2.0);
    NSString *path = makeTempPath(@"trans");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:path error:&err],
         "typed-attrs trans: writeToFilePath: succeeded");
    PASS(attrTypeClass(path, "ir_mode") == H5T_INTEGER,
         "typed-attrs trans: ir_mode stored as H5T_INTEGER");
    // Read raw to verify value == 0.
    hid_t fid = H5Fopen([path fileSystemRepresentation], H5F_ACC_RDONLY, H5P_DEFAULT);
    hid_t g = H5Gopen2(fid, "/study/ir_image_cube", H5P_DEFAULT);
    hid_t a = H5Aopen(g, "ir_mode", H5P_DEFAULT);
    int64_t mv = -1;
    H5Aread(a, H5T_NATIVE_INT64, &mv);
    H5Aclose(a); H5Gclose(g); H5Fclose(fid);
    PASS(mv == 0, "typed-attrs trans: ir_mode i64 value = 0 (TRANSMITTANCE)");

    TTIOIRImage *back = [TTIOIRImage readFromFilePath:path error:&err];
    PASS(back.mode == TTIOIRModeTransmittance,
         "typed-attrs trans: TRANSMITTANCE round-trip");

    unlink([path fileSystemRepresentation]);
}

// ─── 3. Legacy VL-string wire-form: write by hand, verify reader. ───────
//
// Build a .tio via the current writer (produces typed attrs), then
// rewrite the four legacy attrs as VL strings to simulate a pre-fix
// .tio file. The reader must still parse it correctly.
static void testLegacyStringAttrsStillReadable(void)
{
    TTIOIRImage *seed = buildFixture(TTIOIRModeTransmittance, 0.0);
    NSString *path = makeTempPath(@"legacy");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([seed writeToFilePath:path error:&err], "legacy: seed write succeeded");

    // Reopen RDWR and replace ir_mode + the three doubles with VL strings.
    hid_t fid = H5Fopen([path fileSystemRepresentation], H5F_ACC_RDWR, H5P_DEFAULT);
    hid_t g = H5Gopen2(fid, "/study/ir_image_cube", H5P_DEFAULT);

    // Helper: delete (if present) and recreate as VL_STRING with `value`.
    void (^replaceWithVLString)(const char *, NSString *) = ^(const char *name, NSString *value) {
        if (H5Aexists(g, name) > 0) H5Adelete(g, name);
        hid_t st = H5Tcopy(H5T_C_S1);
        H5Tset_size(st, H5T_VARIABLE);
        hid_t sp = H5Screate(H5S_SCALAR);
        hid_t a = H5Acreate2(g, name, st, sp, H5P_DEFAULT, H5P_DEFAULT);
        const char *cs = [value UTF8String];
        H5Awrite(a, st, &cs);
        H5Aclose(a); H5Sclose(sp); H5Tclose(st);
    };
    replaceWithVLString("pixel_size_x",      @"0.75");
    replaceWithVLString("pixel_size_y",      @"0.75");
    replaceWithVLString("resolution_cm_inv", @"6.5");
    replaceWithVLString("ir_mode",           @"absorbance");

    H5Gclose(g);
    H5Fclose(fid);

    // Confirm probing now sees H5T_STRING for those four attrs.
    PASS(attrTypeClass(path, "ir_mode") == H5T_STRING,
         "legacy: ir_mode rewritten as H5T_STRING");
    PASS(attrTypeClass(path, "pixel_size_x") == H5T_STRING,
         "legacy: pixel_size_x rewritten as H5T_STRING");

    // Reader must still parse it correctly.
    TTIOIRImage *back = [TTIOIRImage readFromFilePath:path error:&err];
    PASS(back != nil && err == nil, "legacy: readFromFilePath: succeeded on legacy .tio");
    PASS(back.mode == TTIOIRModeAbsorbance,
         "legacy: ir_mode='absorbance' VL string parses to ABSORBANCE");
    PASS(back.pixelSizeX == 0.75,
         "legacy: pixel_size_x VL string '0.75' parses to 0.75");
    PASS(back.pixelSizeY == 0.75,
         "legacy: pixel_size_y VL string '0.75' parses to 0.75");
    PASS(back.resolutionCmInv == 6.5,
         "legacy: resolution_cm_inv VL string '6.5' parses to 6.5");

    unlink([path fileSystemRepresentation]);
}

// ─── entry point ─────────────────────────────────────────────────────────
void testIRImageWriteReadTypedAttrs(void);
void testIRImageWriteReadTypedAttrs(void)
{
    testTypedAttrsRoundTrip();
    testTransmittanceI64Zero();
    testLegacyStringAttrsStillReadable();
}
