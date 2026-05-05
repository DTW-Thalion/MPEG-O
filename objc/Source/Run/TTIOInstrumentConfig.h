#ifndef TTIO_INSTRUMENT_CONFIG_H
#define TTIO_INSTRUMENT_CONFIG_H

#import <Foundation/Foundation.h>
#import "Providers/TTIOStorageProtocols.h"

/**
 * <heading>TTIOInstrumentConfig</heading>
 *
 * <p><em>Inherits From:</em> NSObject</p>
 * <p><em>Conforms To:</em> NSCoding, NSCopying</p>
 * <p><em>Declared In:</em> Run/TTIOInstrumentConfig.h</p>
 *
 * <p>Immutable value class describing the instrument used to
 * acquire a run. Persisted as a small group of string attributes
 * under <code>instrument_config/</code> within the parent run group.</p>
 *
 * <p><strong>API status:</strong> Stable.</p>
 *
 * <p><strong>Cross-language equivalents:</strong><br/>
 * Python: <code>ttio.instrument_config.InstrumentConfig</code><br/>
 * Java: <code>global.thalion.ttio.InstrumentConfig</code></p>
 */
@interface TTIOInstrumentConfig : NSObject <NSCopying, NSCoding>

/** Instrument manufacturer name. */
@property (readonly, copy) NSString *manufacturer;

/** Instrument model identifier. */
@property (readonly, copy) NSString *model;

/** Manufacturer-assigned serial number. */
@property (readonly, copy) NSString *serialNumber;

/** Ion source type (e.g. <code>@"ESI"</code>,
 *  <code>@"MALDI"</code>). */
@property (readonly, copy) NSString *sourceType;

/** Mass analyser type (e.g. <code>@"Orbitrap"</code>,
 *  <code>@"TOF"</code>). */
@property (readonly, copy) NSString *analyzerType;

/** Detector type. */
@property (readonly, copy) NSString *detectorType;

/**
 * Designated initialiser.
 *
 * @param manufacturer Manufacturer name.
 * @param model        Model identifier.
 * @param serialNumber Serial number.
 * @param sourceType   Ion source type.
 * @param analyzerType Mass analyser type.
 * @param detectorType Detector type.
 * @return An initialised instrument configuration.
 */
- (instancetype)initWithManufacturer:(NSString *)manufacturer
                               model:(NSString *)model
                        serialNumber:(NSString *)serialNumber
                          sourceType:(NSString *)sourceType
                        analyzerType:(NSString *)analyzerType
                        detectorType:(NSString *)detectorType;

/**
 * Writes the configuration to <code>parent/instrument_config/</code>.
 *
 * @param parent Destination group.
 * @param error  Out-parameter populated on failure.
 * @return <code>YES</code> on success.
 */
- (BOOL)writeToGroup:(id<TTIOStorageGroup>)parent error:(NSError **)error;

/**
 * Reads the configuration from
 * <code>parent/instrument_config/</code>.
 *
 * @param parent Source group.
 * @param error  Out-parameter populated on failure.
 * @return The materialised configuration, or <code>nil</code> on
 *         failure.
 */
+ (instancetype)readFromGroup:(id<TTIOStorageGroup>)parent error:(NSError **)error;

@end

#endif
