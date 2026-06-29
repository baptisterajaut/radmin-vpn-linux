/*
 * netsh_wrapper.exe - Replaces Wine's stub netsh.exe
 * Intercepts "interface ip add address" commands and executes
 * them on the Linux TAP device via system().
 *
 * Build:
 *   i686-w64-mingw32-gcc -o netsh.exe netsh_wrapper.c -mconsole
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>

#define NETSH_CMD_DELAY_MS    1500
#define NETSH_ENABLE_DELAY_MS  500

/* Convert wide string arg to narrow */
static char *to_narrow(const WCHAR *w) {
    int len = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char *buf = malloc(len + 1);
    if (!buf) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, buf, len + 1, NULL, NULL);
    return buf;
}

static void spy_log(const char *fmt, ...) {
    FILE *f = _wfopen(L"Z:\\tmp\\radmin_netsh_all.log", L"a");
    if (f) {
        SYSTEMTIME st;
        GetLocalTime(&st);
        fprintf(f, "[%02d:%02d:%02d.%03d] ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
        va_list ap;
        va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fprintf(f, "\n");
        fclose(f);
    }
}

int wmain(int argc, WCHAR *argv[])
{
    char cmdline[2048] = "";
    int i;
    char *addr = NULL, *mask = NULL;

    /* Reconstruct command line */
    for (i = 1; i < argc; i++) {
        char *a = to_narrow(argv[i]);
        if (!a) continue;
        
        size_t current_len = strlen(cmdline);
        size_t arg_len = strlen(a);
        size_t space_needed = arg_len + 1; /* +1 for space */
        
        if (i > 1) space_needed += 1; /* Account for the space we'll add */
        
        if (current_len + space_needed >= sizeof(cmdline)) {
            fprintf(stderr, "netsh_wrapper: command line too long\n");
            free(a);
            break;
        }
        
        if (i > 1) strcat(cmdline, " ");
        strcat(cmdline, a);
        free(a);
    }

    spy_log("args(%d): %s", argc - 1, cmdline);
    fprintf(stderr, "netsh_wrapper: %s\n", cmdline);

    /* Parse "interface ip add address name=XXX addr=YYY mask=ZZZ" */
    /* Also: "interface ip set address name=XXX source=static address=YYY mask=ZZZ" */
    /* Also: "interface set interface XXX ENABLE" */
    /* Also: "interface ipv6 add address interface=XXX address=YYY" */

    if (strstr(cmdline, "interface") &&
        (strstr(cmdline, "add address") || strstr(cmdline, "set address"))) {
        char *p;
        /* Extract addr= or address= (use address= first for "set address") */
        if (strstr(cmdline, "set address")) {
            p = strstr(cmdline, "address=");
            if (p) { p = strchr(p, '=') + 1; addr = p; }
        } else {
            p = strstr(cmdline, "addr=");
            if (!p) p = strstr(cmdline, "address=");
            if (p) { p = strchr(p, '=') + 1; addr = p; }
        }
        if (addr) {
            char *end = strchr(addr, ' ');
            if (end) *end = '\0';
        }
        /* Extract mask= */
        p = strstr(cmdline, "mask=");
        if (p) {
            p = strchr(p, '=') + 1;
            mask = p;
            char *end = strchr(p, ' ');
            if (end) *end = '\0';
        }

        if (addr) {
            /* Convert mask to CIDR if present */
            const char *cidr = "8"; /* default for 26.x.x.x */
            if (mask) {
                if (strcmp(mask, "255.0.0.0") == 0) cidr = "8";
                else if (strcmp(mask, "255.255.0.0") == 0) cidr = "16";
                else if (strcmp(mask, "255.255.255.0") == 0) cidr = "24";
            }

            /* Skip IPv6 link-local only */
            if (strstr(addr, "fe80")) {
                spy_log("skipping link-local %s", addr);
                return 0;
            }

            /* Write command to relay file — a background Linux process
             * with sudo will pick it up and execute it. Wine can't
             * run ip commands directly. Use Z: drive = / on Linux. */
            {
                FILE *f = _wfopen(L"Z:\\tmp\\radmin_netsh_cmd", L"a");
                if (f) {
                    fprintf(f, "ip addr add %s/%s dev radminvpn0 2>/dev/null; "
                               "ip link set radminvpn0 up 2>/dev/null\n",
                            addr, cidr);
                    fclose(f);
                    Sleep(NETSH_CMD_DELAY_MS);
                }
            }
            return 0;
        }
    }

    if (strstr(cmdline, "interface set interface") && strstr(cmdline, "ENABLE")) {
        FILE *f = _wfopen(L"Z:\\tmp\\radmin_netsh_cmd", L"a");
        if (f) { fprintf(f, "ip link set radminvpn0 up\n"); fclose(f); Sleep(NETSH_ENABLE_DELAY_MS); }
        return 0;
    }

    if (strstr(cmdline, "interface ipv6 add address")) {
        char *p = strstr(cmdline, "address=");
        if (p) {
            p += 8; /* skip "address=" */
            char *end = strchr(p, ' ');
            if (end) *end = '\0';
            /* Skip fe80 link-local */
            if (strstr(p, "fe80")) { spy_log("skipping link-local v6 %s", p); return 0; }
            FILE *f = _wfopen(L"Z:\\tmp\\radmin_netsh_cmd", L"a");
            if (f) {
                fprintf(f, "ip -6 addr add %s/128 dev radminvpn0 2>/dev/null\n", p);
                fclose(f);
                spy_log("ipv6 add: %s", p);
                Sleep(NETSH_CMD_DELAY_MS);
            }
        }
        return 0;
    }

    if (strstr(cmdline, "interface ip delete") && strstr(cmdline, "address")) {
        FILE *f = _wfopen(L"Z:\\tmp\\radmin_netsh_cmd", L"a");
        if (f) { fprintf(f, "ip addr flush dev radminvpn0\n"); fclose(f); Sleep(NETSH_ENABLE_DELAY_MS); }
        return 0;
    }

    /* Anything else: silently succeed */
    return 0;
}
