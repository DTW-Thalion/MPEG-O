#ifndef TTIO_IMAGE_H
#define TTIO_IMAGE_H

#import <Foundation/Foundation.h>

/**
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Declared In:</em> Image/TTIOImage.h</p>
 *
 * <p>Shared base for the spectral imaging datasets
 * (<code>TTIOMSImage</code>, <code>TTIORamanImage</code>,
 * <code>TTIOIRImage</code>). Holds the dataset-level metadata
 * (title, ISA investigation id, identifications, quantifications,
 * provenance) plus the common image geometry (width, height,
 * spectral points, tile size, pixel sizes, scan pattern) and the
 * float64 row-major <code>cube</code>.</p>
 *
 * <p>Each concrete subclass owns its on-disk HDF5 group and its
 * own <code>writeToFilePath:</code> / <code>readFromFilePath:</code>;
 * this base imposes no wire format. The polymorphic
 * <code>kind</code>, <code>spectralAxis</code> and
 * <code>spectralAxisKind</code> accessors are overridden by each
 * subclass to expose its modality and spectral axis (m/z or
 * wavenumbers) uniformly.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.image.Image</code><br/>
 * Java: <code>global.thalion.ttio.Image</code></p>
 */

/** Imaging modality of a TTIOImage. */
typedef NS_ENUM(NSInteger, TTIOImageKind) {
    TTIOImageKindMS    = 0,
    TTIOImageKindRaman = 1,
    TTIOImageKindIR    = 2
};

/** Physical meaning of a TTIOImage's spectral axis. */
typedef NS_ENUM(NSInteger, TTIOSpectralAxisKind) {
    TTIOSpectralAxisKindMZ         = 0,
    TTIOSpectralAxisKindWavenumber = 1
};

NS_ASSUME_NONNULL_BEGIN

@interface TTIOImage : NSObject

#pragma mark - Dataset-level fields

/** Free-form dataset title. */
@property (readonly, copy) NSString *title;

/** ISA-Tab investigation identifier this dataset belongs to. */
@property (readonly, copy) NSString *isaInvestigationId;

/** Dataset-wide identifications. */
@property (readonly, copy) NSArray *identifications;

/** Dataset-wide quantifications. */
@property (readonly, copy) NSArray *quantifications;

/** Dataset-wide provenance records. */
@property (readonly, copy) NSArray *provenanceRecords;

#pragma mark - Image-specific fields

/** Image width in pixels. */
@property (readonly) NSUInteger width;

/** Image height in pixels. */
@property (readonly) NSUInteger height;

/** Spectral points per pixel. */
@property (readonly) NSUInteger spectralPoints;

/** Tile size in pixels for chunked storage. */
@property (readonly) NSUInteger tileSize;

/** Float64 row-major image cube. */
@property (readonly, copy) NSData *cube;

/** Pixel size in the X dimension; <code>0</code> when unknown. */
@property (readonly) double pixelSizeX;

/** Pixel size in the Y dimension; <code>0</code> when unknown. */
@property (readonly) double pixelSizeY;

/** Scan pattern identifier; empty when unknown. */
@property (readonly, copy) NSString *scanPattern;

#pragma mark - Polymorphic modality accessors (overridden by subclasses)

/** Imaging modality. Overridden by each concrete subclass. */
@property (readonly) TTIOImageKind kind;

/** The shared 1-D spectral axis (m/z or wavenumbers); nil when
 *  absent. Overridden by each concrete subclass. */
@property (readonly, nullable) NSData *spectralAxis;

/** Physical meaning of <code>spectralAxis</code>. Overridden by
 *  each concrete subclass. */
@property (readonly) TTIOSpectralAxisKind spectralAxisKind;

#pragma mark - Initialisation

/**
 * Designated initialiser for the common image fields. Subclasses
 * call this from their own designated initialisers and then store
 * their modality-specific fields.
 */
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
                         cube:(NSData *)cube;

@end

NS_ASSUME_NONNULL_END

#endif /* TTIO_IMAGE_H */
