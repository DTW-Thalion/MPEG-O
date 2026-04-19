include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = MPGOTests

MPGOTests_OBJC_FILES = \
	MPGOTestRunner.m \
	TestValueRange.m \
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
	TestTransportCodec.m

MPGOTests_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3
MPGOTests_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

ADDITIONAL_CPPFLAGS += -I../Source

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/test-tool.make
-include GNUmakefile.postamble
