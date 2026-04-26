include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = TTIOTests

TTIOTests_OBJC_FILES = \
	TTIOTestRunner.m \
	TestValueRange.m \
	TestIsolationWindow.m \
	TestEncodingSpec.m \
	TestAxisDescriptor.m \
	TestCVParam.m \
	TestHDF5.m \
	TestSignalArray.m \
	TestSpectra.m \
	TestAcquisitionRun.m \
	TestSpectralDataset.m \
	TestMSImage.m \
	TestEncryption.m \
	TestQueryAndStreaming.m \
	TestMzMLReader.m \
	TestMilestone10.m \
	TestMilestone11.m \
	TestMilestone12.m \
	TestMilestone13.m \
	TestMilestone14.m \
	TestMilestone17.m \
	TestMilestone18.m \
	TestMilestone19.m \
	TestMilestone21.m \
	TestMilestone23.m \
	TestMilestone24.m \
	TestMilestone25.m \
	TestMilestone27.m \
	TestMilestone28.m \
	TestMilestone29.m \
	TestMilestone39.m \
	TestMilestone49.m \
	TestMilestone52.m \
	TestMilestone53.m \
	TestImzMLReader.m \
	TestMzTabReader.m \
	TestStress.m \
	TestWatersMassLynxReader.m \
	TestWriteMinimal.m \
	TestImzMLWriter.m \
	TestMzTabWriter.m \
	TestSqliteProvider.m \
	TestCloudAccess.m \
	TestCanonicalBytesCrossBackend.m \
	TestCipherSuite.m \
	TestNdDatasetCrossBackend.m \
	TestTransportCodec.m \
	TestTransportClient.m \
	TestAcquisitionSimulator.m \
	TestTransportServer.m \
	TestTransportConformance.m \
	TestSelectiveAccess.m \
	TestPerAUEncryption.m \
	TestPerAUFile.m \
	TestEncryptedTransport.m \
	TestMilestone73.m \
	TestMilestone73_1.m \
	TestM76JcampConformance.m \
	TestMilestone77.m \
	TestMilestone78.m \
	TestV11EncryptionParity.m \
	TestV111DecryptInPlace.m \
	TestM79GenomicEnums.m \
	TestM82GenomicRun.m \
	TestM83Rans.m \
	TestM84BasePack.m

TTIOTests_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3
TTIOTests_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

ADDITIONAL_CPPFLAGS += -I../Source

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/test-tool.make
-include GNUmakefile.postamble
