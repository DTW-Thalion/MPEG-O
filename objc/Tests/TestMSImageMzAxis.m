#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Image/TTIOMSImage.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Image/TTIOPixelSpectrum.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <unistd.h>

static NSString *axisPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_test_axis_%d_%@.tio",
            (int)getpid(), suffix];
}

void testMSImageMzAxis(void)
{
    const NSUInteger W = 4, H = 3, SP = 8;
    NSMutableData *cube = [NSMutableData dataWithLength:W * H * SP * sizeof(double)];
    double *p = cube.mutableBytes;
    for (NSUInteger i = 0; i < W * H * SP; i++) p[i] = i * 0.1;

    NSMutableData *mz = [NSMutableData dataWithLength:SP * sizeof(double)];
    double *m = mz.mutableBytes;
    for (NSUInteger i = 0; i < SP; i++) m[i] = 100.0 + i * 100.0;

    TTIOMSImage *img =
        [[TTIOMSImage alloc] initWithTitle:@""
                        isaInvestigationId:@""
                           identifications:@[]
                           quantifications:@[]
                         provenanceRecords:@[]
                                     width:W
                                    height:H
                            spectralPoints:SP
                                  tileSize:0
                                pixelSizeX:10.0
                                pixelSizeY:10.0
                               scanPattern:@"raster"
                                      cube:cube
                                    mzAxis:mz];
    PASS(img != nil, "TTIOMSImage with mzAxis constructible");
    PASS(img.mzAxis.length == SP * sizeof(double), "mzAxis length matches");

    NSString *path = axisPath(@"image");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:path error:&err], "writes to HDF5");
    PASS(err == nil, "no error on write");

    TTIOMSImage *back = [TTIOMSImage readFromFilePath:path error:&err];
    PASS(back != nil, "reads back");
    PASS([back.mzAxis isEqualToData:mz], "mzAxis bytes round-trip exactly");
    PASS([back.cube isEqualToData:cube], "cube bytes round-trip exactly");

    NSArray<TTIOPixelSpectrum *> *pixels = [back pixelSpectra];
    PASS(pixels.count == W * H, "pixelSpectra returns one per pixel");
    TTIOPixelSpectrum *p0 = pixels[0];
    PASS(p0.x == 0 && p0.y == 0, "first pixel at (0, 0)");
    PASS([p0.mz isEqualToData:mz], "shared mz axis");

    unlink([path fileSystemRepresentation]);
}

void testMSImageLegacyMzAxisAbsent(void)
{
    // Use the 5-arg ctor (no mzAxis) -- legacy round-trip.
    const NSUInteger W = 2, H = 2, SP = 3;
    NSMutableData *cube = [NSMutableData dataWithLength:W * H * SP * sizeof(double)];
    TTIOMSImage *img = [[TTIOMSImage alloc] initWithWidth:W
                                                    height:H
                                            spectralPoints:SP
                                                  tileSize:0
                                                      cube:cube];
    PASS(img.mzAxis == nil || img.mzAxis.length == 0,
         "legacy ctor leaves mzAxis nil/empty");

    NSString *path = axisPath(@"legacy");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:path error:&err], "writes legacy file");

    TTIOMSImage *back = [TTIOMSImage readFromFilePath:path error:&err];
    PASS(back != nil, "reads back");
    PASS(back.mzAxis == nil || back.mzAxis.length == 0,
         "legacy file -> empty mzAxis");
    unlink([path fileSystemRepresentation]);
}

void testSpectralDatasetMsImageAccessor(void)
{
    const NSUInteger W = 2, H = 2, SP = 3;
    NSMutableData *cube = [NSMutableData dataWithLength:W * H * SP * sizeof(double)];
    NSMutableData *mz = [NSMutableData dataWithLength:SP * sizeof(double)];
    double *mp = mz.mutableBytes;
    for (NSUInteger i = 0; i < SP; i++) mp[i] = 100.0 * (i + 1);

    TTIOMSImage *img =
        [[TTIOMSImage alloc] initWithTitle:@"" isaInvestigationId:@""
                           identifications:@[] quantifications:@[]
                         provenanceRecords:@[]
                                     width:W height:H spectralPoints:SP
                                  tileSize:0 pixelSizeX:1.0 pixelSizeY:1.0
                               scanPattern:@"raster" cube:cube mzAxis:mz];

    NSString *path = axisPath(@"accessor");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:path error:&err], "wrote image .tio");

    TTIOSpectralDataset *plain =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(plain != nil, "opened as plain TTIOSpectralDataset");
    TTIOMSImage *via = plain.msImage;
    PASS(via != nil, "msImage accessor materialises image");
    PASS([via.mzAxis isEqualToData:mz], "mzAxis byte-equal via accessor");
    unlink([path fileSystemRepresentation]);
}

void testPixelSpectraRaisesWhenMzAxisAbsent(void)
{
    const NSUInteger W = 2, H = 2, SP = 3;
    NSMutableData *cube = [NSMutableData dataWithLength:W * H * SP * sizeof(double)];

    // Use the legacy 5-arg ctor (no mzAxis) to construct an MSImage
    // without an axis.
    TTIOMSImage *img = [[TTIOMSImage alloc] initWithWidth:W
                                                    height:H
                                            spectralPoints:SP
                                                  tileSize:0
                                                      cube:cube];
    PASS(img.mzAxis == nil, "ctor leaves mzAxis nil");

    BOOL raised = NO;
    @try {
        [img pixelSpectra];
    } @catch (NSException *e) {
        raised = YES;
        PASS([e.name isEqualToString:NSInternalInconsistencyException],
             "raised NSInternalInconsistencyException");
        PASS([e.reason rangeOfString:@"mz_axis"].location != NSNotFound,
             "exception reason mentions mz_axis");
    }
    PASS(raised, "pixelSpectra raised exception when mzAxis is nil");
}
