# Copyright (c) 2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# This is the Nim version used locally and in regular CI builds.
# Can be a specific version tag, a branch name, or a commit hash.
# Can be overridden by setting the NIM_COMMIT environment variable
# before calling make.
#
# For readability in CI, if NIM_COMMIT is set to "pinned",
# this will also default to the version pinned here.
#
# If NIM_COMMIT is set to "nimbusbuild", this will use the
# version pinned by nimbus-build-system.
PINNED_NIM_VERSION := 38640664088251bbc88917b4bacfd86ec53014b8 # 1.6.21

ifeq ($(NIM_COMMIT),)
NIM_COMMIT := $(PINNED_NIM_VERSION)
else ifeq ($(NIM_COMMIT),pinned)
NIM_COMMIT := $(PINNED_NIM_VERSION)
endif

ifeq ($(NIM_COMMIT),nimbusbuild)
undefine NIM_COMMIT
else
export NIM_COMMIT
endif

SHELL := bash # the shell used internally by Make

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# -d:insecure - Necessary to enable Prometheus HTTP endpoint for metrics
# -d:chronicles_colors:none - Necessary to disable colors in logs for Docker
DOCKER_IMAGE_NIM_PARAMS ?= -d:chronicles_colors:none -d:insecure

LINK_PCRE := 0

ifeq ($(OS),Windows_NT)
    ifeq ($(PROCESSOR_ARCHITECTURE), AMD64)
        ARCH = x86_64
    endif
    ifeq ($(PROCESSOR_ARCHITECTURE), ARM64)
        ARCH = arm64
    endif
else
    UNAME_P := $(shell uname -p)
    ifneq ($(filter $(UNAME_P), i686 i386 x86_64),)
        ARCH = x86_64
    endif
    ifneq ($(filter $(UNAME_P), aarch64 arm),)
        ARCH = arm64
    endif
endif

ifeq ($(ARCH), x86_64)
    CXXFLAGS ?= -std=c++17 -mssse3
else
    CXXFLAGS ?= -std=c++17
endif
export CXXFLAGS

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

.PHONY: \
	all \
	clean \
	coverage \
	deps \
	libbacktrace \
	test \
	update

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE); \
		echo
# Now that the included *.mk files appeared, and are newer than this file, Make will restart itself:
# https://www.gnu.org/software/make/manual/make.html#Remaking-Makefiles
#
# After restarting, it will execute its original goal, so we don't have to start a child Make here
# with "$(MAKE) $(MAKECMDGOALS)". Isn't hidden control flow great?

else # "variables.mk" was included. Business as usual until the end of this file.

# default target, because it's the first one that doesn't start with '.'

# Builds the codex binary
all: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim codex $(NIM_PARAMS) build.nims

# Build tools/cirdl
cirdl: | deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim toolsCirdl $(NIM_PARAMS) build.nims

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

deps: | deps-common nat-libs
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

update: | update-common

# detecting the os
ifeq ($(OS),Windows_NT) # is Windows_NT on XP, 2000, 7, Vista, 10...
 detected_OS := Windows
else ifeq ($(strip $(shell uname)),Darwin)
 detected_OS := macOS
else
 # e.g. Linux
 detected_OS := $(strip $(shell uname))
endif

# Builds and run a part of the test suite
test: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim test $(NIM_PARAMS) build.nims

# Builds and runs the smart contract tests
testContracts: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim testContracts $(NIM_PARAMS) build.nims

# Builds and runs the integration tests
testIntegration: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim testIntegration $(NIM_PARAMS) build.nims

# Builds and runs all tests (except for Taiko L2 tests)
testAll: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim testAll $(NIM_PARAMS) build.nims

# Builds and runs Taiko L2 tests
testTaiko: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim testTaiko $(NIM_PARAMS) build.nims

# Builds and runs tool tests
testTools: | cirdl
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim testTools $(NIM_PARAMS) build.nims

# nim-libbacktrace
LIBBACKTRACE_MAKE_FLAGS := -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0
libbacktrace:
ifeq ($(detected_OS), Windows)
# MSYS2 detection
ifneq ($(MSYSTEM),)
	+ $(MAKE) $(LIBBACKTRACE_MAKE_FLAGS) CMAKE_ARGS="-G'MSYS Makefiles'"
else
	+ $(MAKE) $(LIBBACKTRACE_MAKE_FLAGS)
endif
else
	+ $(MAKE) $(LIBBACKTRACE_MAKE_FLAGS)
endif

coverage:
	$(MAKE) NIMFLAGS="$(NIMFLAGS) --lineDir:on --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-fprofile-arcs --passL:-ftest-coverage" test
	cd nimcache/release/testCodex && rm -f *.c
	mkdir -p coverage
	lcov --capture --directory nimcache/release/testCodex --output-file coverage/coverage.info
	shopt -s globstar && ls $$(pwd)/codex/{*,**/*}.nim
	shopt -s globstar && lcov --extract coverage/coverage.info $$(pwd)/codex/{*,**/*}.nim --output-file coverage/coverage.f.info
	echo -e $(BUILD_MSG) "coverage/report/index.html"
	genhtml coverage/coverage.f.info --output-directory coverage/report

show-coverage:
	if which open >/dev/null; then (echo -e "\e[92mOpening\e[39m HTML coverage report in browser..." && open coverage/report/index.html) || true; fi

coverage-script: build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim coverage $(NIM_PARAMS) build.nims
	echo "Run `make show-coverage` to view coverage results"

# usual cleaning
clean: | clean-common
	rm -rf build
ifneq ($(USE_LIBBACKTRACE), 0)
	+ $(MAKE) -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
endif

endif # "variables.mk" was not included
