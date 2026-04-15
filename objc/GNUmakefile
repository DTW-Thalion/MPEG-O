include $(GNUSTEP_MAKEFILES)/common.make

SUBPROJECTS = Source Tests

include $(GNUSTEP_MAKEFILES)/aggregate.make

# ---------------------------------------------------------------------------
# `make check` — build everything, then execute the test binary.
# ---------------------------------------------------------------------------
# gnustep-make's test-tool.make does not auto-run the binary on `make check`,
# so we invoke it explicitly. LD_LIBRARY_PATH is extended with the in-tree
# Source obj dir and the common gnustep-base install prefixes so the freshly
# built libMPGO and the system libgnustep-base are both resolvable.
check:: all
	@echo "==> Running MPGO test suite"
	@LD_LIBRARY_PATH="$(CURDIR)/Source/$(GNUSTEP_OBJ_DIR):/usr/local/lib:$$LD_LIBRARY_PATH" \
	    Tests/$(GNUSTEP_OBJ_DIR)/MPGOTests

# ---------------------------------------------------------------------------
# `make docs` — generate GSDoc HTML API documentation via autogsdoc.
# ---------------------------------------------------------------------------
# The Documentation/ subproject is intentionally NOT in SUBPROJECTS so the
# default build does not depend on autogsdoc being installed. Run explicitly:
#
#     ./build.sh docs        # via the wrapper (sources GNUstep.sh + clang)
#     make docs              # if the GNUstep environment is already loaded
#
# Output lands in objc/Documentation/html/.
.PHONY: docs docs-clean
docs:
	@echo "==> Generating libMPGO API documentation (autogsdoc)"
	$(MAKE) -C Documentation

docs-clean:
	$(MAKE) -C Documentation clean
