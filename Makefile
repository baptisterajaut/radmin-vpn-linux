CC       = gcc
MINGW32  = i686-w64-mingw32-gcc
MINGW64  = x86_64-w64-mingw32-gcc
CFLAGS   = -Wall -O2
BUILD    = build

all: check-deps $(BUILD)/tap_bridge $(BUILD)/rvpnnetmp.sys $(BUILD)/adapter_hook.dll $(BUILD)/rvpn_launcher.exe $(BUILD)/netsh.exe $(BUILD)/drvinst.exe

$(BUILD)/tap_bridge: src/tap_bridge.c | $(BUILD)
	$(CC) $(CFLAGS) -o $@ $<

$(BUILD)/rvpnnetmp.sys: src/rvpnnetmp.c | $(BUILD)
	$(MINGW64) -shared -o $@ $< \
		-I/usr/x86_64-w64-mingw32/include/ddk \
		-lntoskrnl -lhal -nostdlib \
		-Wl,--subsystem,native -Wl,--entry,DriverEntry

$(BUILD)/adapter_hook.dll: src/adapter_hook.c | $(BUILD)
	$(MINGW32) -shared -o $@ $< \
		-liphlpapi -lws2_32 -Wl,--enable-stdcall-fixup

$(BUILD)/rvpn_launcher.exe: src/rvpn_launcher.c | $(BUILD)
	$(MINGW32) $(CFLAGS) -o $@ $<

$(BUILD)/netsh.exe: src/netsh_wrapper.c | $(BUILD)
	$(MINGW32) $(CFLAGS) -o $@ $< -municode

$(BUILD)/drvinst.exe: src/drvinst.c | $(BUILD)
	$(MINGW32) $(CFLAGS) -o $@ $<

$(BUILD):
	mkdir -p $(BUILD)

check-deps:
	@command -v $(MINGW32) >/dev/null || { echo "Missing: $(MINGW32) (install mingw-w64)"; exit 1; }
	@command -v $(MINGW64) >/dev/null || { echo "Missing: $(MINGW64) (install mingw-w64)"; exit 1; }

clean:
	rm -rf $(BUILD)

.PHONY: all check-deps clean
