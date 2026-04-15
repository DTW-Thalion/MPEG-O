include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = MakeFixtures

MakeFixtures_OBJC_FILES = MakeFixtures.m

MakeFixtures_TOOL_LIBS += -lMPGO -lhdf5 -lhdf5_hl -lz -lcrypto
MakeFixtures_LIB_DIRS  += -L../Source/$(GNUSTEP_OBJ_DIR)

ADDITIONAL_CPPFLAGS += -I../Source

-include ../GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/tool.make
