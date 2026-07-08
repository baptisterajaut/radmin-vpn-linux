CC       = gcc
MINGW32  = i686-w64-mingw32-gcc
MINGW64  = x86_64-w64-mingw32-gcc
CFLAGS   = -Wall -O2
BUILD    = build

STRIP    = strip
STRIP32  = i686-w64-mingw32-strip
STRIP64  = x86_64-w64-mingw32-strip
STRIP_FLAGS = -s -S --strip-debug --strip-unneeded

# DDK header path differs across distros:
#   Debian/Ubuntu:  /usr/x86_64-w64-mingw32/include/ddk
#   Fedora/RHEL:    /usr/x86_64-w64-mingw32/sys-root/mingw/include/ddk
DDK_INC := $(firstword $(wildcard \
    /usr/x86_64-w64-mingw32/include/ddk \
    /usr/x86_64-w64-mingw32/sys-root/mingw/include/ddk \
    /usr/x86_64-w64-mingw32/sys-root/mingw/include \
    /usr/x86_64-w64-mingw32/include \
))
ifeq ($(DDK_INC),)
DDK_INC = /usr/x86_64-w64-mingw32/include/ddk
$(warning DDK headers not found in standard paths; rvpnnetmp.sys compile may fail)
endif

# Lib path also differs (Fedora: sys-root/mingw/lib)
MINGW64_LIB := $(firstword $(wildcard \
    /usr/x86_64-w64-mingw32/lib \
    /usr/x86_64-w64-mingw32/sys-root/mingw/lib \
))

BINS = $(BUILD)/tap_bridge $(BUILD)/rvpnnetmp.sys $(BUILD)/adapter_hook.dll \
       $(BUILD)/rvpn_launcher.exe $(BUILD)/netsh.exe $(BUILD)/netsh64.exe \
       $(BUILD)/drvinst.exe $(BUILD)/rvpn_filter_ui

all: check-deps $(BINS) post-build

$(BUILD)/tap_bridge: src/tap_bridge.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $< -lpthread

$(BUILD)/rvpn_filter_ui: src/rvpn_filter_ui.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $< $(shell pkg-config --cflags --libs gtk4)

$(BUILD)/rvpnnetmp.sys: src/rvpnnetmp.c | $(BUILD)
	$(MINGW64) -shared -o $@ $< \
		-I$(DDK_INC) \
		$(if $(MINGW64_LIB),-L$(MINGW64_LIB)) \
		-lntoskrnl -lhal -nostdlib -lgcc \
		-Wl,--subsystem,native -Wl,--entry,DriverEntry

$(BUILD)/adapter_hook.dll: src/adapter_hook.c | $(BUILD)
	$(MINGW32) -shared -o $@ $< \
		-liphlpapi -lws2_32 -lole32 -Wl,--enable-stdcall-fixup

$(BUILD)/rvpn_launcher.exe: src/rvpn_launcher.c | $(BUILD)
	$(MINGW32) $(CFLAGS) -o $@ $<

$(BUILD)/netsh.exe: src/netsh_wrapper.c | $(BUILD)
	$(MINGW32) $(CFLAGS) -o $@ $< -municode

$(BUILD)/netsh64.exe: src/netsh_wrapper.c | $(BUILD)
	$(MINGW64) $(CFLAGS) -o $@ $< -municode

$(BUILD)/drvinst.exe: src/drvinst.c | $(BUILD)
	$(MINGW32) $(CFLAGS) -o $@ $<

post-build: $(BINS)
	@echo "[*] Stripping and compressing binaries..."
	$(STRIP) $(STRIP_FLAGS) $(BUILD)/tap_bridge
	$(STRIP) $(STRIP_FLAGS) $(BUILD)/rvpn_filter_ui
	$(STRIP64) $(STRIP_FLAGS) $(BUILD)/rvpnnetmp.sys
	$(STRIP32) $(STRIP_FLAGS) $(BUILD)/adapter_hook.dll
	$(STRIP32) $(STRIP_FLAGS) $(BUILD)/rvpn_launcher.exe
	$(STRIP32) $(STRIP_FLAGS) $(BUILD)/netsh.exe
	$(STRIP64) $(STRIP_FLAGS) $(BUILD)/netsh64.exe
	$(STRIP32) $(STRIP_FLAGS) $(BUILD)/drvinst.exe
	# UPX on the PEs (great on EXE/DLL, less effective on .sys)
	upx --best $(BUILD)/rvpn_launcher.exe $(BUILD)/netsh.exe $(BUILD)/netsh64.exe $(BUILD)/adapter_hook.dll $(BUILD)/drvinst.exe || true
	upx --best $(BUILD)/tap_bridge || true

$(BUILD):
	mkdir -p $(BUILD)

install-deps:
	@echo "[*] Installing dependencies (requires sudo)..."
	@if command -v apt-get >/dev/null 2>&1; then \
		sudo apt-get update -qq && \
		sudo apt-get install -y --no-install-recommends \
			gcc make mingw-w64 libgtk-4-dev upx-ucl curl; \
	elif command -v dnf >/dev/null 2>&1; then \
		sudo dnf install -y \
			gcc make mingw32-gcc mingw64-gcc gtk4-devel upx curl; \
	elif command -v pacman >/dev/null 2>&1; then \
		sudo pacman -S --noconfirm \
			gcc make mingw-w64-gcc gtk4 upx curl; \
	elif command -v zypper >/dev/null 2>&1; then \
		sudo zypper install -y \
			gcc make mingw32-cross-gcc mingw64-cross-gcc gtk4-devel upx curl; \
	else \
		echo "[-] Unsupported package manager. Install manually:"; \
		echo "    gcc make mingw-w64 (i686+x86_64) gtk4-devel upx curl"; \
		exit 1; \
	fi
	@echo "[+] Dependencies installed"

install-datacenter-deps:
	@echo "[*] Installing datacenter dependencies (requires sudo)..."
	@if command -v apt-get >/dev/null 2>&1; then \
		sudo apt-get update -qq && \
		sudo apt-get install -y --no-install-recommends \
			xvfb x11vnc novnc websockify; \
	elif command -v dnf >/dev/null 2>&1; then \
		sudo dnf install -y \
			xorg-x11-server-Xvfb x11vnc novnc python3-websockify; \
	elif command -v pacman >/dev/null 2>&1; then \
		sudo pacman -S --noconfirm \
			xorg-server-xvfb x11vnc python-websockify; \
		echo "[!] novnc: install from AUR (yay -S novnc) or manually"; \
	elif command -v zypper >/dev/null 2>&1; then \
		sudo zypper install -y \
			xorg-x11-server-extra x11vnc python3-websockify; \
		echo "[!] novnc: install from https://novnc.com or your distro's repo"; \
	else \
		echo "[-] Unsupported package manager. Install manually:"; \
		echo "    Xvfb x11vnc novnc websockify"; \
		exit 1; \
	fi
	@echo "[+] Datacenter dependencies installed"

check-deps:
	@command -v $(MINGW32) >/dev/null || { echo "Missing: $(MINGW32) (run 'make install-deps')"; exit 1; }
	@command -v $(MINGW64) >/dev/null || { echo "Missing: $(MINGW64) (run 'make install-deps')"; exit 1; }
	@pkg-config --exists gtk4 || { echo "Missing: gtk4 (run 'make install-deps')"; exit 1; }

appimage: check-build-artifacts
	chmod +x packaging/build-appimage.sh
	./packaging/build-appimage.sh

check-build-artifacts:
	@for f in tap_bridge rvpnnetmp.sys adapter_hook.dll rvpn_launcher.exe netsh.exe netsh64.exe drvinst.exe; do \
		[ -f "$(BUILD)/$$f" ] || { echo "Missing: $(BUILD)/$$f (run 'make' first)"; exit 1; }; \
	done
	@if [ ! -f "$(BUILD)/rvpn_filter_ui" ]; then echo "[!] rvpn_filter_ui not found — will be skipped"; fi

clean:
	rm -rf $(BUILD)

.PHONY: all check-deps check-build-artifacts clean install-deps install-datacenter-deps appimage post-build
