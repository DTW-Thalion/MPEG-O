#import <Foundation/Foundation.h>
#import "Testing.h"

extern void testValueRange(void);
extern void testIsolationWindow(void);
extern void testActivationMethodEnum(void);
extern void testMassSpectrumActivationAndIsolationFields(void);
extern void testSpectrumIndexM74RoundTrip(void);
extern void testSpectralDatasetM74FeatureFlag(void);
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
extern void testMzMLReader(void);
extern void testMzMLReaderM74(void);
extern void testMilestone10(void);
extern void testMilestone11(void);
extern void testMilestone12(void);
extern void testMilestone13(void);
extern void testMilestone14(void);
extern void testMilestone17(void);
extern void testMilestone18(void);
extern void testMilestone19(void);
extern void testMilestone19M74(void);
extern void testMilestone21(void);
extern void testMilestone23(void);
extern void testMilestone24(void);
extern void testMilestone25(void);
extern void testMilestone27(void);
extern void testMilestone28(void);
extern void testMilestone29(void);
extern void testMilestone39(void);
extern void testMilestone49(void);
extern void testMilestone52(void);
extern void testMilestone53(void);
extern void testImzMLReader(void);
extern void testMzTabReader(void);
extern void testStress(void);
extern void testWatersMassLynxReader(void);
extern void testWriteMinimal(void);
extern void testImzMLWriter(void);
extern void testMzTabWriter(void);
extern void testSqliteProvider(void);
extern void testCloudAccess(void);
extern void testCanonicalBytesCrossBackend(void);
extern void testCipherSuite(void);
extern void testNdDatasetCrossBackend(void);
extern void testTransportCodec(void);
extern void testTransportClient(void);
extern void testAcquisitionSimulator(void);
extern void testTransportServer(void);
extern void testTransportConformance(void);
extern void testSelectiveAccess(void);
extern void testPerAUEncryption(void);
extern void testPerAUFile(void);
extern void testEncryptedTransport(void);
extern void testMilestone73(void);
extern void testMilestone73_1(void);
extern void testM76JcampConformance(void);
extern void testMilestone77(void);
extern void testMilestone78(void);
extern void testV11EncryptionParity(void);
extern void testV111DecryptInPlace(void);
extern void testM79GenomicEnums(void);
extern void testM82GenomicRun(void);
extern void testM83Rans(void);
extern void testM84BasePack(void);
extern void testM85Quality(void);
extern void testM85bNameTokenizer(void);
extern void testM86GenomicCodecWiring(void);

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        START_SET("TTIOValueRange")
            testValueRange();
        END_SET("TTIOValueRange")

        START_SET("TTIOIsolationWindow")
            testIsolationWindow();
        END_SET("TTIOIsolationWindow")

        START_SET("TTIOActivationMethod")
            testActivationMethodEnum();
        END_SET("TTIOActivationMethod")

        START_SET("TTIOMassSpectrum M74 fields")
            testMassSpectrumActivationAndIsolationFields();
        END_SET("TTIOMassSpectrum M74 fields")

        START_SET("TTIOSpectrumIndex M74 round-trip")
            testSpectrumIndexM74RoundTrip();
        END_SET("TTIOSpectrumIndex M74 round-trip")

        START_SET("M74 Slice E: opt_ms2_activation_detail + format 1.3")
            testSpectralDatasetM74FeatureFlag();
        END_SET("M74 Slice E: opt_ms2_activation_detail + format 1.3")

        START_SET("TTIOEncodingSpec")
            testEncodingSpec();
        END_SET("TTIOEncodingSpec")

        START_SET("TTIOAxisDescriptor")
            testAxisDescriptor();
        END_SET("TTIOAxisDescriptor")

        START_SET("TTIOCVParam")
            testCVParam();
        END_SET("TTIOCVParam")

        START_SET("TTIOHDF5 wrappers")
            testHDF5();
        END_SET("TTIOHDF5 wrappers")

        START_SET("TTIOSignalArray")
            testSignalArray();
        END_SET("TTIOSignalArray")

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

        START_SET("mzML Reader (Milestone 9)")
            testMzMLReader();
        END_SET("mzML Reader (Milestone 9)")

        START_SET("mzML Reader M74 (activation + isolation)")
            testMzMLReaderM74();
        END_SET("mzML Reader M74 (activation + isolation)")

        START_SET("Milestone 10: protocols + modality-agnostic")
            testMilestone10();
        END_SET("Milestone 10: protocols + modality-agnostic")

        START_SET("Milestone 11: compound types + dataset encryption")
            testMilestone11();
        END_SET("Milestone 11: compound types + dataset encryption")

        START_SET("Milestone 12: MSImage inheritance + native 2D NMR")
            testMilestone12();
        END_SET("Milestone 12: MSImage inheritance + native 2D NMR")

        START_SET("Milestone 13: nmrML reader")
            testMilestone13();
        END_SET("Milestone 13: nmrML reader")

        START_SET("Milestone 14: digital signatures + verification")
            testMilestone14();
        END_SET("Milestone 14: digital signatures + verification")

        START_SET("Milestone 17: compound per-run provenance")
            testMilestone17();
        END_SET("Milestone 17: compound per-run provenance")

        START_SET("Milestone 18: canonical byte-order signatures")
            testMilestone18();
        END_SET("Milestone 18: canonical byte-order signatures")

        START_SET("Milestone 19: mzML writer + indexedmzML")
            testMilestone19();
        END_SET("Milestone 19: mzML writer + indexedmzML")

        START_SET("Milestone 19 M74: writer activation + isolation")
            testMilestone19M74();
        END_SET("Milestone 19 M74: writer activation + isolation")

        START_SET("Milestone 21: LZ4 + Numpress-delta codecs")
            testMilestone21();
        END_SET("Milestone 21: LZ4 + Numpress-delta codecs")

        START_SET("Milestone 23: thread-safe TTIOHDF5File")
            testMilestone23();
        END_SET("Milestone 23: thread-safe TTIOHDF5File")

        START_SET("Milestone 24: chromatogram API + mzML writer completion")
            testMilestone24();
        END_SET("Milestone 24: chromatogram API + mzML writer completion")

        START_SET("Milestone 25: envelope encryption + key rotation")
            testMilestone25();
        END_SET("Milestone 25: envelope encryption + key rotation")

        START_SET("Milestone 27: ISA-Tab / ISA-JSON exporter")
            testMilestone27();
        END_SET("Milestone 27: ISA-Tab / ISA-JSON exporter")

        START_SET("Milestone 28: spectral anonymization")
            testMilestone28();
        END_SET("Milestone 28: spectral anonymization")

        START_SET("Milestone 29: nmrML writer + Thermo RAW stub")
            testMilestone29();
        END_SET("Milestone 29: nmrML writer + Thermo RAW stub")

        START_SET("Milestone 39: provider abstraction")
            testMilestone39();
        END_SET("Milestone 39: provider abstraction")

        START_SET("Milestone 41: SQLite storage provider")
            testSqliteProvider();
        END_SET("Milestone 41: SQLite storage provider")

        START_SET("Cloud access (ROS3 / S3)")
            testCloudAccess();
        END_SET("Cloud access (ROS3 / S3)")

        START_SET("M43: canonical bytes cross-backend")
            testCanonicalBytesCrossBackend();
        END_SET("M43: canonical bytes cross-backend")

        START_SET("M48: cipher suite catalog")
            testCipherSuite();
        END_SET("M48: cipher suite catalog")

        START_SET("M45: N-D dataset cross-backend")
            testNdDatasetCrossBackend();
        END_SET("M45: N-D dataset cross-backend")

        START_SET("M49: post-quantum crypto (liboqs)")
            testMilestone49();
        END_SET("M49: post-quantum crypto (liboqs)")

        START_SET("M52: ObjC ZarrProvider")
            testMilestone52();
        END_SET("M52: ObjC ZarrProvider")

        START_SET("M53: ObjC Bruker TDF reader")
            testMilestone53();
        END_SET("M53: ObjC Bruker TDF reader")

        START_SET("M59: ObjC imzML reader")
            testImzMLReader();
        END_SET("M59: ObjC imzML reader")

        START_SET("M60: ObjC mzTab reader")
            testMzTabReader();
        END_SET("M60: ObjC mzTab reader")

        START_SET("M62: ObjC stress + concurrency")
            testStress();
        END_SET("M62: ObjC stress + concurrency")

        START_SET("M63: ObjC Waters MassLynx reader")
            testWatersMassLynxReader();
        END_SET("M63: ObjC Waters MassLynx reader")

        START_SET("writeMinimal flat-buffer fast path")
            testWriteMinimal();
        END_SET("writeMinimal flat-buffer fast path")

        START_SET("imzML writer (v0.9+)")
            testImzMLWriter();
        END_SET("imzML writer (v0.9+)")

        START_SET("mzTab writer (v0.9+)")
            testMzTabWriter();
        END_SET("mzTab writer (v0.9+)")

        START_SET("M67: transport codec (v0.10)")
            testTransportCodec();
        END_SET("M67: transport codec (v0.10)")

        START_SET("M68: transport client (WebSocket, v0.10)")
            testTransportClient();
        END_SET("M68: transport client (WebSocket, v0.10)")

        START_SET("M69: acquisition simulator (v0.10)")
            testAcquisitionSimulator();
        END_SET("M69: acquisition simulator (v0.10)")

        START_SET("M68.5: transport server (v0.10)")
            testTransportServer();
        END_SET("M68.5: transport server (v0.10)")

        START_SET("M70: bidirectional conformance (v0.10)")
            testTransportConformance();
        END_SET("M70: bidirectional conformance (v0.10)")

        START_SET("M71: selective access + protection metadata (v0.10)")
            testSelectiveAccess();
        END_SET("M71: selective access + protection metadata (v0.10)")

        START_SET("v1.0: per-AU encryption primitives")
            testPerAUEncryption();
        END_SET("v1.0: per-AU encryption primitives")

        START_SET("v1.0: per-AU encryption file round-trip")
            testPerAUFile();
        END_SET("v1.0: per-AU encryption file round-trip")

        START_SET("v1.0: encrypted transport emission")
            testEncryptedTransport();
        END_SET("v1.0: encrypted transport emission")

        START_SET("M73: Raman / IR spectra + imaging (v0.11)")
            testMilestone73();
        END_SET("M73: Raman / IR spectra + imaging (v0.11)")

        START_SET("M73.1: JCAMP-DX compression + UV-Vis + 2D-COS (v0.11.1)")
            testMilestone73_1();
        END_SET("M73.1: JCAMP-DX compression + UV-Vis + 2D-COS (v0.11.1)")

        START_SET("M76: JCAMP-DX compressed writer cross-language byte-parity")
            testM76JcampConformance();
        END_SET("M76: JCAMP-DX compressed writer cross-language byte-parity")

        START_SET("M77: 2D-COS compute primitives (v0.12.0)")
            testMilestone77();
        END_SET("M77: 2D-COS compute primitives (v0.12.0)")

        START_SET("M78: mzTab PEH/PEP + SFH/SMF + SEH/SME (v0.12.0)")
            testMilestone78();
        END_SET("M78: mzTab PEH/PEP + SFH/SMF + SEH/SME (v0.12.0)")

        START_SET("v1.1 parity: encrypt -> close -> reopen -> decrypt -> read")
            testV11EncryptionParity();
        END_SET("v1.1 parity: encrypt -> close -> reopen -> decrypt -> read")

        START_SET("v1.1.1 parity: decryptInPlaceAtPath:withKey:error:")
            testV111DecryptInPlace();
        END_SET("v1.1.1 parity: decryptInPlaceAtPath:withKey:error:")

        START_SET("M79: modality + genomic enums (v0.11)")
            testM79GenomicEnums();
        END_SET("M79: modality + genomic enums (v0.11)")

        START_SET("M82: GenomicRun + AlignedRead + signal channels (v0.11)")
            testM82GenomicRun();
        END_SET("M82: GenomicRun + AlignedRead + signal channels (v0.11)")

        START_SET("M83: rANS codec")
            testM83Rans();
        END_SET("M83: rANS codec")

        START_SET("M84: BASE_PACK codec")
            testM84BasePack();
        END_SET("M84: BASE_PACK codec")

        START_SET("M85: QUALITY_BINNED codec")
            testM85Quality();
        END_SET("M85: QUALITY_BINNED codec")

        START_SET("M85B: NAME_TOKENIZED codec")
            testM85bNameTokenizer();
        END_SET("M85B: NAME_TOKENIZED codec")

        START_SET("M86: codec wiring")
            testM86GenomicCodecWiring();
        END_SET("M86: codec wiring")
    }
    return 0;
}
