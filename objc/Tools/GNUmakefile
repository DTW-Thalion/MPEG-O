include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = MakeFixtures TtioVerify TtioWriteGenomicFixture TtioSign TtioToMzML TtioDumpIdentifications TtioPQCTool TtioSimulator TtioTransportServer TtioTransportEncode TtioTransportDecode TtioPerAU TtioJcampDxDump

MakeFixtures_OBJC_FILES = MakeFixtures.m
MakeFixtures_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto
MakeFixtures_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioVerify_OBJC_FILES = TtioVerify.m
TtioVerify_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto
TtioVerify_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioWriteGenomicFixture_OBJC_FILES = TtioWriteGenomicFixture.m
TtioWriteGenomicFixture_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto
TtioWriteGenomicFixture_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioSign_OBJC_FILES = TtioSign.m
TtioSign_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto
TtioSign_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioToMzML_OBJC_FILES = TtioToMzML.m
TtioToMzML_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto
TtioToMzML_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioDumpIdentifications_OBJC_FILES = TtioDumpIdentifications.m
TtioDumpIdentifications_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto
TtioDumpIdentifications_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioPQCTool_OBJC_FILES = TtioPQCTool.m
TtioPQCTool_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3
TtioPQCTool_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioSimulator_OBJC_FILES = TtioSimulator.m
TtioSimulator_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3 -lwebsockets
TtioSimulator_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioTransportServer_OBJC_FILES = TtioTransportServer.m
TtioTransportServer_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3 -lwebsockets
TtioTransportServer_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioTransportEncode_OBJC_FILES = TtioTransportEncode.m
TtioTransportEncode_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3 -lwebsockets
TtioTransportEncode_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioTransportDecode_OBJC_FILES = TtioTransportDecode.m
TtioTransportDecode_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3 -lwebsockets
TtioTransportDecode_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioPerAU_OBJC_FILES = TtioPerAU.m
TtioPerAU_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3 -lwebsockets
TtioPerAU_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

TtioJcampDxDump_OBJC_FILES = TtioJcampDxDump.m
TtioJcampDxDump_TOOL_LIBS += -lTTIO -lhdf5 -lhdf5_hl -lz -lcrypto
TtioJcampDxDump_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

ADDITIONAL_CPPFLAGS += -I../Source

-include ../GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/tool.make
