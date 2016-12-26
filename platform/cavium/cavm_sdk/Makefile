include $(PLATFORM_PATH)/cavm-sai.mk

SHELL = /bin/bash
.ONESHELL:

MAIN_TARGET = $(addprefix $(DEST)/, $(CAVM_LIBSAI)) $(addprefix $(DEST)/, $(CAVM_SAI)) $(addprefix $(DEST)/, $(XPSHELL)) $(addprefix $(DEST)/, $(XP_TOOLS))

$(MAIN_TARGET): $(DEST)/% :
	rm -rf OpenXPS
	git clone -b sai_0.9.5 https://github.com/garyachy/OpenXPS.git
	pushd OpenXPS/SAI/cavm-sai
	mv $* $(DEST)/
	popd
