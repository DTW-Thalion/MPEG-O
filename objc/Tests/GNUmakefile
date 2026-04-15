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
	TestMilestone14.m

MPGOTests_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto
MPGOTests_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

ADDITIONAL_CPPFLAGS += -I../Source

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/test-tool.make
-include GNUmakefile.postamble
