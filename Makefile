obj-m := wireview_hwmon.o

MODULE_NAME := wireview_hwmon
KDIR ?= /lib/modules/$(shell uname -r)/build
MDIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
HOSTCC ?= cc
KERNEL_CONFIG := $(KDIR)/.config
KERNEL_MAKEFLAGS :=
MODULE_DIR ?= /lib/modules/$(shell uname -r)/updates
MODULE_PATH := $(MODULE_DIR)/$(MODULE_NAME).ko
MODULE_PATH_ZST := $(MODULE_PATH).zst
MODULE_SIGN_TOOL ?= $(KDIR)/scripts/sign-file
MODULE_SIGN_KEY ?=
MODULE_SIGN_CERT ?=

ifneq ($(wildcard $(KERNEL_CONFIG)),)
ifneq ($(shell grep -E '^CONFIG_CC_IS_CLANG=y' $(KERNEL_CONFIG) 2>/dev/null),)
KERNEL_MAKEFLAGS += LLVM=1
endif
endif

all: module wireviewd wireviewctl

module:
	$(MAKE) -C $(KDIR) $(KERNEL_MAKEFLAGS) M=$(MDIR) modules

wireviewd: wireviewd.c
	$(HOSTCC) -Wall -Wextra -Wno-format-truncation -O2 -o wireviewd wireviewd.c

wireviewctl: wireviewctl.c
	$(HOSTCC) -Wall -Wextra -O2 -o wireviewctl wireviewctl.c

clean:
	$(MAKE) -C $(KDIR) $(KERNEL_MAKEFLAGS) M=$(MDIR) clean
	rm -f wireviewd wireviewctl

install: all
	install -d $(MODULE_DIR)
	install -m 644 $(MODULE_NAME).ko $(MODULE_PATH)
	@if [ -n "$(MODULE_SIGN_KEY)" ] || [ -n "$(MODULE_SIGN_CERT)" ]; then \
		if [ -z "$(MODULE_SIGN_KEY)" ] || [ -z "$(MODULE_SIGN_CERT)" ]; then \
			echo "MODULE_SIGN_KEY and MODULE_SIGN_CERT must both be set" >&2; \
			exit 1; \
		fi; \
		"$(MODULE_SIGN_TOOL)" sha256 "$(MODULE_SIGN_KEY)" "$(MODULE_SIGN_CERT)" "$(MODULE_PATH)"; \
	fi
	@if command -v zstd >/dev/null 2>&1; then \
		zstd -f --rm "$(MODULE_PATH)"; \
	fi
	depmod -a
	install -m 755 wireviewd /usr/local/bin/wireviewd
	install -m 755 wireviewctl /usr/local/bin/wireviewctl
	install -m 644 wireviewd.service /etc/systemd/system/wireviewd.service
	install -m 644 99-wireview-hwmon.rules /etc/udev/rules.d/99-wireview-hwmon.rules
	udevadm control --reload-rules
	systemctl daemon-reload

dkms-install:
	./scripts/setup-dkms-arch.sh

uninstall:
	systemctl stop wireviewd 2>/dev/null || true
	systemctl disable wireviewd 2>/dev/null || true
	rm -f /usr/local/bin/wireviewd
	rm -f /usr/local/bin/wireviewctl
	rm -f /etc/systemd/system/wireviewd.service
	rm -f /etc/udev/rules.d/99-wireview-hwmon.rules
	rm -f $(MODULE_PATH) $(MODULE_PATH_ZST)
	depmod -a
	udevadm control --reload-rules
	systemctl daemon-reload

.PHONY: all module clean install dkms-install uninstall
