#import <Foundation/Foundation.h>
#import "Testing.h"

extern void testValueRange(void);
extern void testEncodingSpec(void);
extern void testAxisDescriptor(void);
extern void testCVParam(void);
extern void testHDF5(void);
extern void testSignalArray(void);
extern void testSpectra(void);
extern void testAcquisitionRun(void);
extern void testSpectralDataset(void);
extern void testMSImage(void);
extern void testEncryption(void);
extern void testQueryAndStreaming(void);

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        START_SET("MPGOValueRange")
            testValueRange();
        END_SET("MPGOValueRange")

        START_SET("MPGOEncodingSpec")
            testEncodingSpec();
        END_SET("MPGOEncodingSpec")

        START_SET("MPGOAxisDescriptor")
            testAxisDescriptor();
        END_SET("MPGOAxisDescriptor")

        START_SET("MPGOCVParam")
            testCVParam();
        END_SET("MPGOCVParam")

        START_SET("MPGOHDF5 wrappers")
            testHDF5();
        END_SET("MPGOHDF5 wrappers")

        START_SET("MPGOSignalArray")
            testSignalArray();
        END_SET("MPGOSignalArray")

        START_SET("Spectrum classes")
            testSpectra();
        END_SET("Spectrum classes")

        START_SET("AcquisitionRun + SpectrumIndex")
            testAcquisitionRun();
        END_SET("AcquisitionRun + SpectrumIndex")

        START_SET("SpectralDataset (multi-run)")
            testSpectralDataset();
        END_SET("SpectralDataset (multi-run)")

        START_SET("MSImage")
            testMSImage();
        END_SET("MSImage")

        START_SET("Encryption (AES-256-GCM)")
            testEncryption();
        END_SET("Encryption (AES-256-GCM)")

        START_SET("Query + Streaming")
            testQueryAndStreaming();
        END_SET("Query + Streaming")
    }
    return 0;
}
