#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Image/MPGOMSImage.h"
#import "Spectra/MPGONMR2DSpectrum.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOEnums.h"
#import "Dataset/MPGOSpectralDataset.h"
#import "Dataset/MPGOIdentification.h"
#import "Dataset/MPGOQuantification.h"
#import "Dataset/MPGOProvenanceRecord.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOFeatureFlags.h"
#import "HDF5/MPGOHDF5Errors.h"
#import <hdf5.h>
#import <hdf5_hl.h>
#import <math.h>
#import <unistd.h>

static NSString *m12path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_m12_%d_%@.mpgo",
            (int)getpid(), suffix];
}

void testMilestone12(void)
{
    // ---- 1. MSImage inherits MPGOSpectralDataset; 64x64x8 round-trip
    //         with idents + quants + provenance
    {
        const NSUInteger W = 64, H = 64, SP = 8, TS = 32;
        NSMutableData *cube = [NSMutableData dataWithLength:W * H * SP * sizeof(double)];
        double *p = cube.mutableBytes;
        for (NSUInteger y = 0; y < H; y++) {
            for (NSUInteger x = 0; x < W; x++) {
                for (NSUInteger s = 0; s < SP; s++) {
                    p[(y * W + x) * SP + s] = (double)(x * 1000 + y * 13) + (double)s * 0.001;
                }
            }
        }

        MPGOIdentification *ident =
            [[MPGOIdentification alloc] initWithRunName:@"image"
                                          spectrumIndex:0
                                         chemicalEntity:@"CHEBI:16526"
                                        confidenceScore:0.91
                                          evidenceChain:@[@"MS:1002217"]];
        MPGOQuantification *quant =
            [[MPGOQuantification alloc] initWithChemicalEntity:@"CHEBI:16526"
                                                      sampleRef:@"tissue_A"
                                                      abundance:1.5e6
                                            normalizationMethod:@"TIC"];
        MPGOProvenanceRecord *prov =
            [[MPGOProvenanceRecord alloc] initWithInputRefs:@[@"raw:slide_001"]
                                                    software:@"msi_convert"
                                                  parameters:@{@"tile": @32}
                                                  outputRefs:@[@"mpgo:img_001"]
                                               timestampUnix:1700000500];

        MPGOMSImage *img =
            [[MPGOMSImage alloc] initWithTitle:@"MSImage test"
                            isaInvestigationId:@"I-12"
                               identifications:@[ident]
                               quantifications:@[quant]
                             provenanceRecords:@[prov]
                                         width:W
                                        height:H
                                spectralPoints:SP
                                      tileSize:TS
                                    pixelSizeX:10.0
                                    pixelSizeY:10.0
                                   scanPattern:@"raster"
                                          cube:cube];
        PASS([img isKindOfClass:[MPGOSpectralDataset class]],
             "MPGOMSImage is-a MPGOSpectralDataset");
        PASS(img.identifications.count == 1,
             "MSImage carries inherited identifications");
        PASS([img.scanPattern isEqualToString:@"raster"], "scanPattern stored");
        PASS(img.pixelSizeX == 10.0, "pixelSizeX stored");

        NSString *path = m12path(@"msimg");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        PASS([img writeToFilePath:path error:&err],
             "inherited MSImage writes via super");

        MPGOMSImage *back = [MPGOMSImage readFromFilePath:path error:&err];
        PASS(back != nil, "inherited MSImage reads back");
        PASS(back.width == W && back.height == H && back.spectralPoints == SP,
             "dimensions round-trip");
        PASS([back.cube isEqualToData:cube], "cube bytes round-trip");
        PASS(back.identifications.count == 1, "inherited idents round-trip");
        PASS(back.quantifications.count == 1, "inherited quants round-trip");
        PASS(back.provenanceRecords.count == 1, "inherited provenance round-trip");
        PASS([back.scanPattern isEqualToString:@"raster"], "scanPattern round-trips");
        PASS(back.pixelSizeX == 10.0, "pixelSizeX round-trips");

        // Tile read still works on new /study/image_cube layout
        NSData *tile = [MPGOMSImage readTileFromFilePath:path
                                                      atX:0 y:0
                                                    width:TS height:TS
                                                    error:&err];
        PASS(tile.length == TS * TS * SP * sizeof(double),
             "tile read via /study/image_cube layout");
        [back closeFile];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 2. MSImage v0.1 fallback: /image_cube at root
    {
        const NSUInteger W = 16, H = 16, SP = 4;
        NSString *path = m12path(@"legacy_img");
        unlink([path fileSystemRepresentation]);

        hid_t fid = H5Fcreate([path fileSystemRepresentation],
                              H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
        hid_t imageGroup = H5Gcreate2(fid, "image_cube",
                                       H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
        hsize_t dims[3] = { H, W, SP };
        hid_t space = H5Screate_simple(3, dims, NULL);
        hid_t did = H5Dcreate2(imageGroup, "intensity",
                               H5T_NATIVE_DOUBLE, space,
                               H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
        NSUInteger total = W * H * SP;
        double *buf = malloc(total * sizeof(double));
        for (NSUInteger i = 0; i < total; i++) buf[i] = (double)i * 0.5;
        H5Dwrite(did, H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, buf);
        free(buf);

        hid_t scalar = H5Screate(H5S_SCALAR);
        int64_t v;
        hid_t a;
        a = H5Acreate2(imageGroup, "width", H5T_NATIVE_INT64, scalar, H5P_DEFAULT, H5P_DEFAULT);
        v = (int64_t)W; H5Awrite(a, H5T_NATIVE_INT64, &v); H5Aclose(a);
        a = H5Acreate2(imageGroup, "height", H5T_NATIVE_INT64, scalar, H5P_DEFAULT, H5P_DEFAULT);
        v = (int64_t)H; H5Awrite(a, H5T_NATIVE_INT64, &v); H5Aclose(a);
        a = H5Acreate2(imageGroup, "spectral_points", H5T_NATIVE_INT64, scalar, H5P_DEFAULT, H5P_DEFAULT);
        v = (int64_t)SP; H5Awrite(a, H5T_NATIVE_INT64, &v); H5Aclose(a);
        a = H5Acreate2(imageGroup, "tile_size", H5T_NATIVE_INT64, scalar, H5P_DEFAULT, H5P_DEFAULT);
        v = 16; H5Awrite(a, H5T_NATIVE_INT64, &v); H5Aclose(a);
        H5Sclose(scalar);

        H5Dclose(did); H5Sclose(space); H5Gclose(imageGroup); H5Fclose(fid);

        NSError *err = nil;
        MPGOMSImage *back = [MPGOMSImage readFromFilePath:path error:&err];
        PASS(back != nil, "v0.1 /image_cube layout loads via fallback");
        PASS(back.width == W && back.height == H && back.spectralPoints == SP,
             "legacy dimensions");
        PASS(back.cube.length == total * sizeof(double),
             "legacy cube bytes recovered");
        unlink([path fileSystemRepresentation]);
    }

    // ---- 3. Native 2D NMR: 256x128 HSQC round-trip + dim scales + feature flag
    {
        const NSUInteger WIDTH = 128, HEIGHT = 256;
        const NSUInteger total = WIDTH * HEIGHT;
        double *mat = malloc(total * sizeof(double));
        for (NSUInteger i = 0; i < total; i++) mat[i] = sin((double)i * 0.01) * 1000.0;
        NSData *matData = [NSData dataWithBytes:mat length:total * sizeof(double)];
        free(mat);

        MPGOAxisDescriptor *f1 =
            [MPGOAxisDescriptor descriptorWithName:@"F1"
                                              unit:@"ppm"
                                        valueRange:[MPGOValueRange rangeWithMinimum:0 maximum:200]
                                      samplingMode:MPGOSamplingModeUniform];
        MPGOAxisDescriptor *f2 =
            [MPGOAxisDescriptor descriptorWithName:@"F2"
                                              unit:@"ppm"
                                        valueRange:[MPGOValueRange rangeWithMinimum:0 maximum:12]
                                      samplingMode:MPGOSamplingModeUniform];

        NSError *err = nil;
        MPGONMR2DSpectrum *hsqc =
            [[MPGONMR2DSpectrum alloc] initWithIntensityMatrix:matData
                                                          width:WIDTH
                                                         height:HEIGHT
                                                         f1Axis:f1
                                                         f2Axis:f2
                                                      nucleusF1:@"13C"
                                                      nucleusF2:@"1H"
                                                  indexPosition:0
                                                          error:&err];
        PASS(hsqc != nil, "HSQC 2D NMR constructible");

        NSString *path = m12path(@"hsqc");
        unlink([path fileSystemRepresentation]);
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([hsqc writeToGroup:[f rootGroup] name:@"hsqc" error:&err],
             "HSQC writes via MPGOSpectrum writer");
        [f close];

        // Inspect the file directly to confirm intensity_matrix_2d is a
        // rank-2 dataset with dim scales.
        @autoreleasepool {
            hid_t fid = H5Fopen([path fileSystemRepresentation],
                                H5F_ACC_RDONLY, H5P_DEFAULT);
            hid_t specGroup = H5Gopen2(fid, "hsqc", H5P_DEFAULT);
            PASS(H5Lexists(specGroup, "intensity_matrix_2d", H5P_DEFAULT) > 0,
                 "native intensity_matrix_2d present in spectrum group");
            PASS(H5Lexists(specGroup, "f1_scale", H5P_DEFAULT) > 0,
                 "f1_scale dataset present");
            PASS(H5Lexists(specGroup, "f2_scale", H5P_DEFAULT) > 0,
                 "f2_scale dataset present");

            hid_t did = H5Dopen2(specGroup, "intensity_matrix_2d", H5P_DEFAULT);
            hid_t space = H5Dget_space(did);
            int rank = H5Sget_simple_extent_ndims(space);
            hsize_t sdims[2] = {0, 0};
            H5Sget_simple_extent_dims(space, sdims, NULL);
            PASS(rank == 2, "intensity_matrix_2d has rank 2");
            PASS(sdims[0] == HEIGHT && sdims[1] == WIDTH,
                 "rank-2 dataset dims match height x width");

            // Dim scales attached?
            int f1Count = H5DSget_num_scales(did, 0);
            int f2Count = H5DSget_num_scales(did, 1);
            PASS(f1Count == 1, "F1 dimension has one scale attached");
            PASS(f2Count == 1, "F2 dimension has one scale attached");

            H5Sclose(space); H5Dclose(did); H5Gclose(specGroup); H5Fclose(fid);
        }

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGONMR2DSpectrum *back =
            [MPGONMR2DSpectrum readFromGroup:[g rootGroup] name:@"hsqc" error:&err];
        PASS(back != nil, "HSQC reads back");
        PASS(back.width == WIDTH && back.height == HEIGHT,
             "HSQC dims round-trip");
        PASS([back.intensityMatrix isEqualToData:matData],
             "HSQC matrix bytes match via native 2-D path");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 4. opt_native_2d_nmr flag emitted in MPGOSpectralDataset files
    {
        MPGOSpectralDataset *ds =
            [[MPGOSpectralDataset alloc] initWithTitle:@"m12_flags"
                                    isaInvestigationId:@""
                                                msRuns:@{}
                                               nmrRuns:@{}
                                       identifications:@[]
                                       quantifications:@[]
                                     provenanceRecords:@[]
                                           transitions:nil];
        NSString *path = m12path(@"flags");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        [ds writeToFilePath:path error:&err];

        MPGOHDF5File *f = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        NSArray *features = [MPGOFeatureFlags featuresForRoot:[f rootGroup]];
        PASS([features containsObject:@"opt_native_2d_nmr"],
             "opt_native_2d_nmr feature flag emitted");
        PASS([features containsObject:@"opt_native_msimage_cube"],
             "opt_native_msimage_cube feature flag emitted");
        [f close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 5. v0.1 flattened 2D NMR fallback: no intensity_matrix_2d,
    //         must fall back to flattened 1-D array in /arrays/
    {
        const NSUInteger WIDTH = 4, HEIGHT = 3;
        const NSUInteger total = WIDTH * HEIGHT;
        double mat[12];
        for (NSUInteger i = 0; i < total; i++) mat[i] = (double)(i + 1);
        NSData *matData = [NSData dataWithBytes:mat length:total * sizeof(double)];

        MPGOAxisDescriptor *f1 =
            [MPGOAxisDescriptor descriptorWithName:@"F1" unit:@"ppm"
                                        valueRange:[MPGOValueRange rangeWithMinimum:0 maximum:1]
                                      samplingMode:MPGOSamplingModeUniform];
        MPGOAxisDescriptor *f2 =
            [MPGOAxisDescriptor descriptorWithName:@"F2" unit:@"ppm"
                                        valueRange:[MPGOValueRange rangeWithMinimum:0 maximum:1]
                                      samplingMode:MPGOSamplingModeUniform];

        NSError *err = nil;
        MPGONMR2DSpectrum *small =
            [[MPGONMR2DSpectrum alloc] initWithIntensityMatrix:matData
                                                          width:WIDTH
                                                         height:HEIGHT
                                                         f1Axis:f1
                                                         f2Axis:f2
                                                      nucleusF1:@"13C"
                                                      nucleusF2:@"1H"
                                                  indexPosition:0
                                                          error:&err];
        NSString *path = m12path(@"nmr2d_legacy");
        unlink([path fileSystemRepresentation]);
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        [small writeToGroup:[f rootGroup] name:@"spec" error:&err];
        [f close];

        // Delete the native 2-D dataset + scales to simulate a v0.1 file.
        @autoreleasepool {
            hid_t fid = H5Fopen([path fileSystemRepresentation],
                                H5F_ACC_RDWR, H5P_DEFAULT);
            hid_t specGroup = H5Gopen2(fid, "spec", H5P_DEFAULT);
            // Detach scales first so H5Ldelete can proceed cleanly.
            hid_t did = H5Dopen2(specGroup, "intensity_matrix_2d", H5P_DEFAULT);
            hid_t fs = H5Dopen2(specGroup, "f1_scale", H5P_DEFAULT);
            hid_t fs2 = H5Dopen2(specGroup, "f2_scale", H5P_DEFAULT);
            H5DSdetach_scale(did, fs, 0);
            H5DSdetach_scale(did, fs2, 1);
            H5Dclose(fs); H5Dclose(fs2); H5Dclose(did);
            H5Ldelete(specGroup, "intensity_matrix_2d", H5P_DEFAULT);
            H5Ldelete(specGroup, "f1_scale", H5P_DEFAULT);
            H5Ldelete(specGroup, "f2_scale", H5P_DEFAULT);
            H5Gclose(specGroup);
            H5Fclose(fid);
        }

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGONMR2DSpectrum *back =
            [MPGONMR2DSpectrum readFromGroup:[g rootGroup] name:@"spec" error:&err];
        PASS(back != nil, "legacy flattened 2D NMR reads via fallback");
        PASS(back.width == WIDTH && back.height == HEIGHT,
             "legacy dims preserved");
        PASS([back.intensityMatrix isEqualToData:matData],
             "legacy matrix bytes recovered via fallback");
        [g close];
        unlink([path fileSystemRepresentation]);
    }
}
