include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = MakeFixtures MpgoVerify MpgoSign MpgoToMzML MpgoDumpIdentifications MpgoPQCTool MpgoSimulator MpgoTransportServer MpgoTransportEncode MpgoTransportDecode MpgoPerAU MpgoJcampDxDump

MakeFixtures_OBJC_FILES = MakeFixtures.m
MakeFixtures_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto
MakeFixtures_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

MpgoVerify_OBJC_FILES = MpgoVerify.m
MpgoVerify_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto
MpgoVerify_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

MpgoSign_OBJC_FILES = MpgoSign.m
MpgoSign_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto
MpgoSign_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

MpgoToMzML_OBJC_FILES = MpgoToMzML.m
MpgoToMzML_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto
MpgoToMzML_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

MpgoDumpIdentifications_OBJC_FILES = MpgoDumpIdentifications.m
MpgoDumpIdentifications_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto
MpgoDumpIdentifications_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

MpgoPQCTool_OBJC_FILES = MpgoPQCTool.m
MpgoPQCTool_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3
MpgoPQCTool_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

MpgoSimulator_OBJC_FILES = MpgoSimulator.m
MpgoSimulator_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3 -lwebsockets
MpgoSimulator_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

MpgoTransportServer_OBJC_FILES = MpgoTransportServer.m
MpgoTransportServer_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3 -lwebsockets
MpgoTransportServer_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

MpgoTransportEncode_OBJC_FILES = MpgoTransportEncode.m
MpgoTransportEncode_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3 -lwebsockets
MpgoTransportEncode_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

MpgoTransportDecode_OBJC_FILES = MpgoTransportDecode.m
MpgoTransportDecode_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3 -lwebsockets
MpgoTransportDecode_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

MpgoPerAU_OBJC_FILES = MpgoPerAU.m
MpgoPerAU_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto -lsqlite3 -lwebsockets
MpgoPerAU_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

MpgoJcampDxDump_OBJC_FILES = MpgoJcampDxDump.m
MpgoJcampDxDump_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto
MpgoJcampDxDump_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

ADDITIONAL_CPPFLAGS += -I../Source

-include ../GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/tool.make
