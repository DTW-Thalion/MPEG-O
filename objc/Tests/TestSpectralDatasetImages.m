/*
 * TestSpectralDatasetImages.m — P2.5 OIT2.
 *
 * Exercises the uniform image-collection accessors that replace the
 * three typed properties (-msImage / -ramanImage / -irImage) on
 * TTIOSpectralDataset:
 *
 *   - (nullable TTIOImage *)imageForKind:(TTIOImageKind)kind;
 *   - (NSArray<TTIOImage *> *)images;
 *
 * Consumers needing the concrete subclass cast the polymorphic result
 * (e.g. (TTIOMSImage *)[ds imageForKind:TTIOImageKindMS]). The lazy
 * file-backed materialisation and per-kind caching are preserved.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Dataset/TTIOSpectralDataset.h"
#import "Image/TTIOImage.h"
#import "Image/TTIOMSImage.h"
#import "Image/TTIORamanImage.h"
#import "Image/TTIOIRImage.h"
#include <unistd.h>

static NSString *makeImagesTempPath(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_dsimages_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:base];
}

static TTIOMSImage *buildMSFixture(void)
{
    const NSUInteger W = 2, H = 2, SP = 3;
    NSMutableData *cube = [NSMutableData dataWithLength:W * H * SP * sizeof(double)];
    NSMutableData *mz = [NSMutableData dataWithLength:SP * sizeof(double)];
    double *mp = (double *)mz.mutableBytes;
    for (NSUInteger i = 0; i < SP; i++) mp[i] = 100.0 * (i + 1);
    return [[TTIOMSImage alloc] initWithTitle:@"images_fixture"
                           isaInvestigationId:@""
                              identifications:@[]
                              quantifications:@[]
                            provenanceRecords:@[]
                                        width:W
                                       height:H
                               spectralPoints:SP
                                     tileSize:0
                                   pixelSizeX:1.0
                                   pixelSizeY:1.0
                                  scanPattern:@"raster"
                                         cube:cube
                                       mzAxis:mz];
}

// -- 1. imageForKind: returns the MS image and nil for absent kinds --------

static void testImageForKindMSPresentRamanNil(void)
{
    TTIOMSImage *img = buildMSFixture();
    NSString *path = makeImagesTempPath(@"forkind");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:path error:&err] && err == nil,
         "imageForKind: wrote MS image .tio");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil && err == nil, "imageForKind: opened dataset");

    TTIOImage *result = [ds imageForKind:TTIOImageKindMS];
    PASS(result != nil, "imageForKind:MS returns non-nil for MS-bearing dataset");
    PASS([result isKindOfClass:[TTIOMSImage class]],
         "imageForKind:MS returns a TTIOMSImage instance");

    PASS([ds imageForKind:TTIOImageKindRaman] == nil,
         "imageForKind:Raman is nil when no raman_image_cube present");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

// -- 2. -images contains only the present kinds ----------------------------

static void testImagesCollectionPresentOnly(void)
{
    TTIOMSImage *img = buildMSFixture();
    NSString *path = makeImagesTempPath(@"images");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:path error:&err] && err == nil,
         "images: wrote MS image .tio");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil && err == nil, "images: opened dataset");

    NSArray<TTIOImage *> *images = [ds images];
    PASS(images.count == 1,
         "images contains exactly the one present (MS) image");
    PASS(images.count == 1
         && [images[0] isKindOfClass:[TTIOMSImage class]],
         "images[0] is the MS image");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

void testSpectralDatasetImages(void);
void testSpectralDatasetImages(void)
{
    testImageForKindMSPresentRamanNil();
    testImagesCollectionPresentOnly();
}
