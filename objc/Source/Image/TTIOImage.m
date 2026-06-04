/*
 * TTIOImage.m
 * TTI-O Objective-C Implementation
 *
 * Class:         TTIOImage
 * Inherits From: NSObject
 * Declared In:   Image/TTIOImage.h
 *
 * Shared base for the spectral imaging datasets (MS / Raman / IR).
 * Owns the dataset-level metadata and the common image geometry +
 * cube; persistence and the spectral axis are provided by the
 * concrete subclasses.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import "TTIOImage.h"

@implementation TTIOImage

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
    self = [super init];
    if (self) {
        _title              = [title copy];
        _isaInvestigationId = [isaId copy];
        _identifications    = [identifications copy] ?: @[];
        _quantifications    = [quantifications copy] ?: @[];
        _provenanceRecords  = [provenance copy] ?: @[];
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

#pragma mark - Polymorphic modality accessors (subclasses override)

- (TTIOImageKind)kind
{
    [NSException raise:NSInternalInconsistencyException
                format:@"%@ must override -kind", NSStringFromClass([self class])];
    return TTIOImageKindMS;  // unreachable
}

- (NSData *)spectralAxis
{
    [NSException raise:NSInternalInconsistencyException
                format:@"%@ must override -spectralAxis", NSStringFromClass([self class])];
    return nil;  // unreachable
}

- (TTIOSpectralAxisKind)spectralAxisKind
{
    [NSException raise:NSInternalInconsistencyException
                format:@"%@ must override -spectralAxisKind", NSStringFromClass([self class])];
    return TTIOSpectralAxisKindMZ;  // unreachable
}

@end
