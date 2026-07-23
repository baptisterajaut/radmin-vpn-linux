/*
 * adapter_hook.dll — Wine compatibility hooks for Radmin VPN
 *
 * Injected into RvControlSvc.exe by rvpn_launcher.exe.
 * IAT hooks (in RvControlSvc.exe AND RvROLClient.dll):
 *   - GetAdaptersAddresses: renames Linux TAP to Radmin adapter name, and hides
 *     every interface except the default route + our TAP (issue #16 fix).
 *   - GetAdaptersInfo: same interface filtering (the ROL connector reads both).
 *   - RegSetKeySecurity: no-op (Wine SCM lacks SYSTEM SID)
 *   - LoadLibraryW/A/ExW: catch RvROLClient.dll's dynamic load so we can hook
 *     its (own) iphlpapi imports too.
 *
 * Build:
 *   i686-w64-mingw32-gcc -shared -o adapter_hook.dll adapter_hook.c \
 *       -liphlpapi -lws2_32 -Wl,--enable-stdcall-fixup
 */

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <ctype.h>

#define TAP_DESC     L"radminvpn0"
#define RADMIN_DESC  L"Famatech Radmin VPN Ethernet Adapter"
#define RADMIN_FRIENDLY L"Radmin VPN"

/* ====== Logging ====== */

static void dbg(const char *msg)
{
    HANDLE f = CreateFileA("C:\\radmin_hook_debug.log",
        FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return;
    {
        DWORD w;
        WriteFile(f, msg, strlen(msg), &w, NULL);
        WriteFile(f, "\r\n", 2, &w, NULL);
        CloseHandle(f);
    }
}

/* ====== Crash capture (vectored exception handler) ======
 *
 * RvControlSvc.exe is spawned by rvpn_launcher with bInheritHandles=FALSE, so
 * its stderr never reaches /tmp/radmin_service.log and Wine's +seh backtrace is
 * lost. Since this DLL is injected into the service, we install our own handler
 * that writes a full crash dump (code, faulting address, module+offset,
 * registers, stack backtrace) straight to a file we control. This is the
 * authoritative service-side crash capture. */

#define CRASH_LOG "C:\\radmin_crash.log"

static void crashlog(const char *msg)
{
    HANDLE f = CreateFileA(CRASH_LOG, FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE)
        return;
    {
        DWORD w;
        WriteFile(f, msg, (DWORD)strlen(msg), &w, NULL);
        CloseHandle(f);
    }
}

/* RtlCaptureStackBackTrace lives in ntdll, resolve at runtime */
static USHORT (WINAPI *p_CaptureStack)(ULONG, ULONG, PVOID *, PULONG) = NULL;

/* Resolve an address to "module.dll+0xoffset" for IDA correlation. */
static void module_at(void *addr, char *out, size_t outsz)
{
    HMODULE hm = NULL;
    if (GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCSTR)addr, &hm) && hm) {
        char path[MAX_PATH];
        if (GetModuleFileNameA(hm, path, MAX_PATH)) {
            const char *base = strrchr(path, '\\');
            base = base ? base + 1 : path;
            snprintf(out, outsz, "%s+0x%lx", base,
                     (unsigned long)((uintptr_t)addr - (uintptr_t)hm));
            return;
        }
    }
    snprintf(out, outsz, "%p", addr);
}

static volatile LONG in_crash = 0;

/* Per-thread TLS slot holding a jmp_buf* while inside the guarded CSetupAdapter
 * teardown. Native Win32 TLS (not __thread, which mingw lowers to emutls ->
 * runtime locks/alloc unsafe in an exception handler). TlsGetValue is a
 * lock-free TEB-array read. */
static DWORD g_jmp_tls = TLS_OUT_OF_INDEXES;
static void longjmp_tramp(void);   /* forward decl: redirected-to on recovery */

static LONG CALLBACK crash_handler(PEXCEPTION_POINTERS ep)
{
    DWORD code = ep->ExceptionRecord->ExceptionCode;

    /* Only error-severity (0xCxxxxxxx) exceptions; skip C++ EH (0xE06D7363). */
    if ((code & 0xC0000000) != 0xC0000000)
        return EXCEPTION_CONTINUE_SEARCH;
    if (code == 0xE06D7363u)
        return EXCEPTION_CONTINUE_SEARCH;

    /* Recovery: an access violation happened inside a guarded thread-pool task
     * (which touched a dangling COM object -- memory queries can't distinguish
     * reused heap from valid under Wine). The fault can be arbitrarily deep, so
     * we redirect EIP to a trampoline that longjmp()s back to the task-boundary
     * setjmp point in hook_dispatch(). That abandons the one faulting task and
     * lets the worker thread continue. Resume runs on the still-valid stack. */
    if (code == 0xC0000005u && g_jmp_tls != TLS_OUT_OF_INDEXES &&
        TlsGetValue(g_jmp_tls)) {
        crashlog("[task-guard] recovered from fault in worker task "
                 "(task dropped, service alive)\r\n");
        ep->ContextRecord->Eip = (DWORD)(ULONG_PTR)&longjmp_tramp;
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    /* Re-entrancy guard: a fault inside the handler must not loop. */
    if (InterlockedExchange(&in_crash, 1) != 0)
        return EXCEPTION_CONTINUE_SEARCH;

    {
        char buf[1024];
        char modbuf[MAX_PATH + 32];
        CONTEXT *c = ep->ContextRecord;
        void *pc = ep->ExceptionRecord->ExceptionAddress;
        SYSTEMTIME st;

        module_at(pc, modbuf, sizeof(modbuf));
        GetLocalTime(&st);
        snprintf(buf, sizeof(buf),
            "\r\n===== CRASH %04d-%02d-%02d %02d:%02d:%02d.%03d =====\r\n"
            "code=0x%08lx  pc=%p  (%s)\r\n",
            st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute,
            st.wSecond, st.wMilliseconds,
            (unsigned long)code, pc, modbuf);
        crashlog(buf);

        if (code == 0xC0000005u &&
            ep->ExceptionRecord->NumberParameters >= 2) {
            ULONG_PTR kind = ep->ExceptionRecord->ExceptionInformation[0];
            const char *op = kind == 0 ? "read" : kind == 1 ? "write" : "exec";
            snprintf(buf, sizeof(buf), "access-violation: %s @ %p\r\n",
                     op, (void *)ep->ExceptionRecord->ExceptionInformation[1]);
            crashlog(buf);
        }

#ifdef __i386__
        snprintf(buf, sizeof(buf),
            "EAX=%08lx EBX=%08lx ECX=%08lx EDX=%08lx\r\n"
            "ESI=%08lx EDI=%08lx EBP=%08lx ESP=%08lx\r\n"
            "EIP=%08lx EFL=%08lx\r\n",
            c->Eax, c->Ebx, c->Ecx, c->Edx,
            c->Esi, c->Edi, c->Ebp, c->Esp,
            c->Eip, c->EFlags);
        crashlog(buf);
#else
        (void)c;
#endif

        if (!p_CaptureStack) {
            HMODULE nt = GetModuleHandleA("ntdll.dll");
            if (nt)
                p_CaptureStack = (void *)GetProcAddress(nt,
                    "RtlCaptureStackBackTrace");
        }
        if (p_CaptureStack) {
            void *frames[48];
            USHORT i, n = p_CaptureStack(0, 48, frames, NULL);
            crashlog("backtrace (innermost first):\r\n");
            for (i = 0; i < n; i++) {
                module_at(frames[i], modbuf, sizeof(modbuf));
                snprintf(buf, sizeof(buf), "  #%02u  %p  %s\r\n",
                         i, frames[i], modbuf);
                crashlog(buf);
            }
        }
        crashlog("===== END CRASH =====\r\n");
    }

    in_crash = 0;
    /* Let Wine/winedbg still see it (AeDebug, default handler). */
    return EXCEPTION_CONTINUE_SEARCH;
}

/* ====== CSetupAdapter teardown guard ======
 *
 * The crashing object is a dangling COM INetwork (and other freed members)
 * cached by ControlSvc::task::CSetupAdapter. When a network is removed/left the
 * Network List Manager (Wine netprofm) frees the object, but the service keeps
 * a stale pointer and later calls through its vtable -> 0xc0000005 (observed
 * pc=0x043304A3, deterministic when joining a busy server with many networks).
 * The bad pointer is reached from MULTIPLE sites (CSetupAdapter teardown
 * sub_459B70, INetwork::GetName/SetName sub_45B460, ...) so guarding one
 * function is whack-a-mole. Memory-validity checks can't help: under Wine the
 * reused heap reads back committed + executable + MEM_IMAGE.
 *
 * Fix: guard at the thread-pool task boundary. sub_4636A0 (RvControlSvc+0x636A0)
 * is the worker that runs each queued task:
 *      unsigned __stdcall sub_4636A0(Block) {
 *        if (Block) { fn=Block[0]; arg=Block[1]; free(Block,8);
 *                     if (fn) fn(arg);            // __stdcall(arg) -- THE TASK
 *                     _InterlockedDecrement(&pending); }
 *        return 0;
 *      }
 * We detour it to hook_dispatch, which reimplements it but runs fn(arg) under
 * __builtin_setjmp. ANY access violation anywhere in the task is caught by the
 * crash handler (which redirects EIP to longjmp_tramp -> longjmp back here),
 * the whole task is abandoned, the pending counter is still decremented, and
 * the worker thread continues. One faulting task is dropped; the service lives.
 * The setjmp scope == the entire task, so recovery never unwinds to a stale
 * frame. Installed from DllMain before any task runs. */

#define DISPATCH_RVA 0x636A0        /* sub_4636A0 worker entry          */
#define FREE_RVA     0xC9001        /* sub_4C9001 = operator delete(p,n) */
#define COUNTER_RVA  0x13F1D8       /* dword_53F1D8 pending-task count   */

static BYTE *g_rvbase = NULL;       /* RvControlSvc.exe load base */

/* The crash handler redirects EIP here on a recoverable fault. Runs on the
 * faulting thread's still-valid stack; longjmp restores esp/ebp/eip to the
 * active hook_dispatch() setjmp point (the task boundary). */
static void longjmp_tramp(void)
{
    if (g_jmp_tls != TLS_OUT_OF_INDEXES) {
        void **e = (void **)TlsGetValue(g_jmp_tls);
        if (e)
            __builtin_longjmp(e, 1);            /* raw fp/sp/pc restore */
    }
    for (;;)                                     /* TLS broken: contain, don't loop wild */
        Sleep(1000);
}

/* Reimplementation of sub_4636A0 (__stdcall, retn 4) with the task call run
 * under fault recovery. */
static unsigned __stdcall hook_dispatch(void **Block)
{
    if (Block) {
        void *fn  = Block[0];
        void *arg = Block[1];
        /* free the work block: __cdecl operator delete(ptr, 8) */
        ((void (__cdecl *)(void *, unsigned))(g_rvbase + FREE_RVA))(Block, 8);
        if (fn) {
            void *env[5];                        /* __builtin_setjmp buffer */
            void **prev;
            if (g_jmp_tls != TLS_OUT_OF_INDEXES) {
                prev = (void **)TlsGetValue(g_jmp_tls);
                TlsSetValue(g_jmp_tls, env);
                if (__builtin_setjmp(env) == 0)
                    ((void (__stdcall *)(void *))fn)(arg);  /* may fault */
                TlsSetValue(g_jmp_tls, prev);
            } else {
                ((void (__stdcall *)(void *))fn)(arg);
            }
        }
        /* Always decrement, even for an abandoned task, so the pool accounting
         * doesn't leak a phantom pending task. */
        _InterlockedDecrement((long *)(g_rvbase + COUNTER_RVA));
    }
    return 0;
}

#define GETINETWORK_RVA 0x5BA70     /* sub_45BA70 rvpn::GetINetwork getter */

static void install_release_guard(void)
{
    /* sub_4636A0 prologue: push ebp; mov ebp,esp; push -1 (55 8B EC 6A FF). */
    static const BYTE expect[5] = { 0x55, 0x8B, 0xEC, 0x6A, 0xFF };
    HMODULE base = GetModuleHandleA(NULL);
    BYTE *t;
    DWORD old;

    if (!base) {
        dbg("task-guard: no module base");
        return;
    }
    g_rvbase = (BYTE *)base;

    /* PRIMARY FIX -- neutralise rvpn::GetINetwork (sub_45BA70, +0x5BA70). It
     * caches a Wine netprofm INetwork at CSetupAdapter+0x1D4; Wine frees that
     * object on network changes ("netprofm: no support for detecting network
     * changes"), so every later GetName/SetName/release through the stale
     * pointer faults (0xc0000005 @ 0x043304A3) when joining a busy server. The
     * function already has a handled "failed -> return 0" path, so stub it to
     * always return 0: the service skips the network naming (a no-op under
     * Wine's stub netprofm anyway) and the setup task completes normally, adapter
     * intact. __thiscall, bool in AL, no stack args -> `xor al,al; ret`. */
    {
        static const BYTE gi_expect[3] = { 0x56, 0x57, 0x8B };  /* push esi;push edi;mov edi,ecx */
        BYTE *g = (BYTE *)base + GETINETWORK_RVA;
        DWORD go;
        if (memcmp(g, gi_expect, sizeof(gi_expect)) != 0) {
            dbg("GetINetwork stub: prologue mismatch, skip");
        } else if (!VirtualProtect(g, 3, PAGE_EXECUTE_READWRITE, &go)) {
            dbg("GetINetwork stub: VirtualProtect failed");
        } else {
            g[0] = 0x30; g[1] = 0xC0;            /* xor al, al */
            g[2] = 0xC3;                         /* ret        */
            VirtualProtect(g, 3, go, &go);
            FlushInstructionCache(GetCurrentProcess(), g, 3);
            dbg("GetINetwork stubbed at RvControlSvc+0x5BA70 (always return 0)");
        }
    }

    /* SAFETY NET -- task-level fault guard (see hook_dispatch). */
    t = (BYTE *)base + DISPATCH_RVA;
    if (memcmp(t, expect, sizeof(expect)) != 0) {
        dbg("task-guard: prologue mismatch -- wrong RvControlSvc, skip");
        return;
    }
    if (!VirtualProtect(t, 6, PAGE_EXECUTE_READWRITE, &old)) {
        dbg("task-guard: VirtualProtect failed");
        return;
    }
    /* Absolute `push hook; ret` (range-independent under LARGE_ADDRESS_AWARE).
     * Overwrites 6 bytes; the original body is never executed -- hook_dispatch
     * reimplements it. */
    t[0] = 0x68;
    *(DWORD *)(t + 1) = (DWORD)(ULONG_PTR)hook_dispatch;
    t[5] = 0xC3;
    VirtualProtect(t, 6, old, &old);
    FlushInstructionCache(GetCurrentProcess(), t, 6);
    dbg("task-guard installed at RvControlSvc+0x636A0");
}

/* ====== Adapter-list filtering (issue #16) ======
 *
 * Radmin's connector (RvROLClient.dll: InitConnector -> ... -> FUN_1004b3e0)
 * builds an ICE-style NAT-traversal candidate set from every local IP on every
 * host interface, via GetAdaptersAddresses AND GetAdaptersInfo (plus a third
 * gethostbyname source we don't touch). With several interfaces present
 * (docker0, vmnet, dummy, tailscale, ...) it advertises a pile of private,
 * unroutable candidates; the transport never converges to "connected" (state 5),
 * CMsgStarted / ROL event 0xc never fires, and the service hangs at "registered
 * but never ready".
 *
 * Fix: show Radmin only the interface that owns the default route (the one that
 * actually reaches Famatech) + our TAP, and hide the rest. Done without relinking
 * the caller's list: for GAA we NULL FirstUnicastAddress; for GAI we blank the
 * address to 0.0.0.0 — both make the adapter contribute zero candidates (the
 * gatherer already skips 0.0.0.0). If the default route can't be resolved we
 * leave the list untouched, so we never risk hiding the only path to the net. */

static ULONG (WINAPI *real_GetAdaptersAddresses)(
    ULONG, ULONG, PVOID, PIP_ADAPTER_ADDRESSES, PULONG) = NULL;
static ULONG (WINAPI *real_GetAdaptersInfo)(PIP_ADAPTER_INFO, PULONG) = NULL;

static DWORD g_tap_ifindex = 0;   /* our TAP's IfIndex, learned in the GAA hook */

/* TRUE if `s_addr_net` (network byte order) is a plausible uplink IPv4: not
 * 0.0.0.0, not loopback (127/8), not link-local/APIPA (169.254/16), not CGNAT
 * (100.64/10, Tailscale). RFC1918 private (192.168/10/172.16) IS allowed — a
 * home uplink is almost always private, so rejecting it would reject everyone. */
static BOOL is_uplink_v4(DWORD s_addr_net)
{
    DWORD h = ntohl(s_addr_net);
    if (h == 0) return FALSE;
    if ((h & 0xFF000000u) == 0x7F000000u) return FALSE;   /* 127.0.0.0/8   */
    if ((h & 0xFFFF0000u) == 0xA9FE0000u) return FALSE;   /* 169.254.0.0/16 */
    if ((h & 0xFFC00000u) == 0x64400000u) return FALSE;   /* 100.64.0.0/10  */
    return TRUE;
}

/* IfIndex of the interface carrying the default route (route to the internet),
 * or 0 if it can't be resolved *unambiguously*.
 *
 * Issue #19: on some hosts (Arch/zen, Fedora reporters) Wine's
 * GetBestInterface(8.8.8.8) either fails or returns an IfIndex that matches no
 * adapter enumerated by GetAdaptersAddresses. The callers then can't confirm the
 * uplink (best_ok stays FALSE) and fall back to leaking every interface's IPs as
 * NAT candidates -> ROL never registers.
 *
 * Layered, and always keyed on a REAL enumerated IfIndex so the result is
 * directly usable by the callers:
 *   1. Fast path: GetBestInterface(8.8.8.8), but only trust it if its IfIndex is
 *      actually one of the enumerated adapters (the check the reporters failed).
 *   2. Fallback: the single UP adapter that owns a FirstGatewayAddress AND a
 *      routable IPv4. Wine mirrors the host forward table into FirstGatewayAddress
 *      (populated ONLY on the default-route iface — verified empirically: docker0,
 *      bridges, veth, lo all show no gateway), a signal it fills even when
 *      GetBestInterface's index is unusable.
 * CONSERVATISM: picking the wrong uplink hides the real path (worse than the
 * current leak), so if the fallback is ambiguous (0 or >1 candidate) we return 0
 * and the caller keeps its safe behavior (GAA rename-only, empty candidate set).
 * Uses the REAL GAA (no recursion into our hook). */
static DWORD default_route_ifindex(void)
{
    if (!real_GetAdaptersAddresses) {
        /* Hooks not wired up yet — best-effort raw call. */
        DWORD idx = 0;
        if (GetBestInterface(inet_addr("8.8.8.8"), &idx) == NO_ERROR && idx)
            return idx;
        return 0;
    }

    ULONG size = 15 * 1024;
    IP_ADAPTER_ADDRESSES *buf = (IP_ADAPTER_ADDRESSES *)malloc(size);
    if (!buf) return 0;
    ULONG r = real_GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_GATEWAYS,
                                        NULL, buf, &size);
    if (r == ERROR_BUFFER_OVERFLOW) {
        IP_ADAPTER_ADDRESSES *nb = (IP_ADAPTER_ADDRESSES *)realloc(buf, size);
        if (!nb) { free(buf); return 0; }
        buf = nb;
        r = real_GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_GATEWAYS,
                                      NULL, buf, &size);
    }
    if (r != ERROR_SUCCESS) { free(buf); return 0; }

    /* 1. Fast path: GetBestInterface, confirmed against the enumeration. */
    DWORD best = 0;
    if (GetBestInterface(inet_addr("8.8.8.8"), &best) == NO_ERROR && best) {
        for (IP_ADAPTER_ADDRESSES *a = buf; a; a = a->Next) {
            if (a->IfIndex == best) {
                free(buf);
                dbg("uplink: GetBestInterface fast-path");
                return best;
            }
        }
    }

    /* 2. Fallback: unique UP adapter with a gateway + routable IPv4. */
    DWORD found = 0;
    int n = 0;
    for (IP_ADAPTER_ADDRESSES *a = buf; a; a = a->Next) {
        if (a->OperStatus != IfOperStatusUp) continue;
        if (!a->FirstGatewayAddress) continue;
        BOOL has_v4 = FALSE;
        for (PIP_ADAPTER_UNICAST_ADDRESS u = a->FirstUnicastAddress; u; u = u->Next) {
            if (u->Address.lpSockaddr &&
                u->Address.lpSockaddr->sa_family == AF_INET &&
                is_uplink_v4(((struct sockaddr_in *)
                              u->Address.lpSockaddr)->sin_addr.s_addr)) {
                has_v4 = TRUE;
                break;
            }
        }
        if (!has_v4) continue;
        n++;
        found = a->IfIndex;
    }
    free(buf);

    if (n == 1) {
        dbg("uplink: gateway fallback (GetBestInterface unusable)");
        return found;
    }
    dbg(n == 0 ? "uplink: unresolved (no gateway+routable adapter) -> 0"
               : "uplink: ambiguous (>1 gateway adapter) -> 0");
    return 0;
}

static ULONG WINAPI hook_GetAdaptersAddresses(
    ULONG Family, ULONG Flags, PVOID Rsvd,
    PIP_ADAPTER_ADDRESSES Addrs, PULONG Size)
{
    if (!real_GetAdaptersAddresses) return ERROR_NOT_SUPPORTED;

    ULONG ret = real_GetAdaptersAddresses(Family, Flags, Rsvd, Addrs, Size);
    if (ret != ERROR_SUCCESS || !Addrs) return ret;

    DWORD best = default_route_ifindex();
    BOOL  best_ok = FALSE;

    /* Pass 1: rename our TAP, learn its IfIndex, and confirm the default-route
     * interface is actually one of the enumerated (non-TAP) adapters. */
    for (PIP_ADAPTER_ADDRESSES cur = Addrs; cur; cur = cur->Next) {
        if (cur->Description && wcscmp(cur->Description, TAP_DESC) == 0) {
            /* Read-only string literals: the caller frees the whole buffer in one
             * shot and never touches these fields individually. */
            cur->Description  = (WCHAR *)RADMIN_DESC;
            cur->FriendlyName = (WCHAR *)RADMIN_FRIENDLY;
            g_tap_ifindex = cur->IfIndex;
            continue;
        }
        if (best && cur->IfIndex == best)
            best_ok = TRUE;
    }

    if (!best || !best_ok) {
        dbg("filter(GAA): no default-route adapter resolved -- rename only");
        return ret;
    }

    /* Pass 2: hide every adapter that is neither the TAP nor the default route. */
    int hidden = 0;
    for (PIP_ADAPTER_ADDRESSES cur = Addrs; cur; cur = cur->Next) {
        if (cur->IfIndex == best || cur->IfIndex == g_tap_ifindex)
            continue;
        cur->FirstUnicastAddress = NULL;
        hidden++;
    }
    {
        char buf[96];
        snprintf(buf, sizeof(buf),
            "filter(GAA): default-route if=%lu, TAP if=%lu, hid %d adapters",
            (unsigned long)best, (unsigned long)g_tap_ifindex, hidden);
        dbg(buf);
    }
    return ret;
}

static ULONG WINAPI hook_GetAdaptersInfo(PIP_ADAPTER_INFO Info, PULONG Size)
{
    if (!real_GetAdaptersInfo) return ERROR_NOT_SUPPORTED;

    ULONG ret = real_GetAdaptersInfo(Info, Size);
    if (ret != ERROR_SUCCESS || !Info) return ret;

    DWORD best = default_route_ifindex();
    BOOL  best_ok = FALSE;
    for (PIP_ADAPTER_INFO cur = Info; cur; cur = cur->Next)
        if (best && cur->Index == best) { best_ok = TRUE; break; }

    if (!best || !best_ok) {
        dbg("filter(GAI): no default-route adapter resolved -- skip");
        return ret;
    }

    int hidden = 0;
    for (PIP_ADAPTER_INFO cur = Info; cur; cur = cur->Next) {
        if (cur->Index == best || (g_tap_ifindex && cur->Index == g_tap_ifindex))
            continue;
        /* Blank the address chain -> contributes nothing (gatherer skips 0.0.0.0). */
        strcpy(cur->IpAddressList.IpAddress.String, "0.0.0.0");
        cur->IpAddressList.Next = NULL;
        hidden++;
    }
    {
        char buf[64];
        snprintf(buf, sizeof(buf), "filter(GAI): hid %d adapters", hidden);
        dbg(buf);
    }
    return ret;
}

/* ====== Candidate-source filtering: gethostbyname / getaddrinfo (issue #16) ======
 *
 * GAA/GAI are only TWO of the three local-address sources the ROL connector
 * feeds into its NAT-traversal candidate set. The third is
 * gethostbyname(gethostname()) (and, defensively, getaddrinfo of the local
 * name): on systemd hosts nss-myhostname resolves the local hostname to EVERY
 * locally-configured IP, so docker0/vmnet/tailscale/dummy addresses leak in
 * proportional to the interface count — which is why rc5 (GAA/GAI only) still
 * hung with docker+tailscale up. RvROLClient imports gethostbyname by ORDINAL
 * (WS2_32 #52), which is why the name-based IAT hook never reached it.
 *
 * Policy (rc7): a local-hostname lookup is ONLY ever the candidate gatherer
 * (RvROLClient FUN_1004b760 -- verified by RE; it is the sole leak, GAA is
 * OperStatus+FirstUnicastAddress gated and GAI's 0.0.0.0 blanking is honoured by
 * the insert skip-list). Its results become *advertised host candidates*, never a
 * path to any server -- so over-filtering here is harmless (relay/STUN are a
 * separate connect() to server IPs) while under-filtering is the actual bug. So
 * for a local-hostname hit we filter to {uplink, TAP} and, on ANY uncertainty,
 * EMPTY the result rather than pass the polluted set through. This is the opposite
 * of rc6's "bias to passthrough", which silently leaked docker0 & co (a DOWN,
 * route-less 172.17.0.1 resolved via nss-myhostname). Server lookups
 * (is_local_hostname false) are never touched. Every call is logged now, so a
 * single run shows exactly what the gatherer asked for and got. */

#define WS2_ORD_GETHOSTBYNAME 52          /* WS2_32.dll ordinal (verified) */
#define ALLOWED_MAX           32

static DWORD g_allowed_v4[ALLOWED_MAX];   /* in_addr.s_addr, network byte order */
static int   g_allowed_n     = 0;
static BOOL  g_allowed_valid = FALSE;

static struct hostent *(WINAPI *real_gethostbyname)(const char *) = NULL;
static int (WINAPI *real_getaddrinfo)(const char *, const char *,
    const struct addrinfo *, struct addrinfo **) = NULL;
static int (WSAAPI *real_getnameinfo)(const SOCKADDR *, socklen_t,
    PCHAR, DWORD, PCHAR, DWORD, INT) = NULL;

/* 100.64.0.0/10 — CGNAT range used by Tailscale et al. */
static BOOL is_cgnat(DWORD s_addr_net)
{
    return (ntohl(s_addr_net) & 0xFFC00000u) == 0x64400000u;
}

static BOOL in_allowed_v4(DWORD s_addr_net)
{
    for (int i = 0; i < g_allowed_n; i++)
        if (g_allowed_v4[i] == s_addr_net) return TRUE;
    return FALSE;
}

/* Rebuild g_allowed_v4 = IPv4 of {default-route iface, TAP}. Recomputed per hook
 * entry (cheap; keeps up with tailscale-up-mid-session). Any uncertainty leaves
 * g_allowed_valid = FALSE so every caller passes through untouched.
 * Bails: no real GAA yet, no default route, uplink not enumerated, uplink has no
 * IPv4, or the uplink's IPv4 is CGNAT (overlay hijacked the default route —
 * refuse to commit to an unreachable path). Uses the REAL GAA (no recursion). */
static void build_allowed_v4(void)
{
    g_allowed_valid = FALSE;
    g_allowed_n = 0;

    if (!real_GetAdaptersAddresses) return;
    DWORD uplink = default_route_ifindex();
    if (!uplink) return;

    ULONG size = 15 * 1024;
    IP_ADAPTER_ADDRESSES *buf = (IP_ADAPTER_ADDRESSES *)malloc(size);
    if (!buf) return;
    ULONG r = real_GetAdaptersAddresses(AF_INET, 0, NULL, buf, &size);
    if (r == ERROR_BUFFER_OVERFLOW) {
        IP_ADAPTER_ADDRESSES *nb = (IP_ADAPTER_ADDRESSES *)realloc(buf, size);
        if (!nb) { free(buf); return; }
        buf = nb;
        r = real_GetAdaptersAddresses(AF_INET, 0, NULL, buf, &size);
    }
    if (r != ERROR_SUCCESS) { free(buf); return; }

    BOOL uplink_has_v4 = FALSE;
    for (IP_ADAPTER_ADDRESSES *a = buf; a; a = a->Next) {
        if (a->IfIndex != uplink && a->IfIndex != g_tap_ifindex) continue;
        for (PIP_ADAPTER_UNICAST_ADDRESS u = a->FirstUnicastAddress; u; u = u->Next) {
            if (!u->Address.lpSockaddr ||
                u->Address.lpSockaddr->sa_family != AF_INET) continue;
            DWORD ip = ((struct sockaddr_in *)u->Address.lpSockaddr)->sin_addr.s_addr;
            if (a->IfIndex == uplink) {
                uplink_has_v4 = TRUE;
                if (is_cgnat(ip)) { free(buf); return; }   /* overlay-as-default */
            }
            if (g_allowed_n < ALLOWED_MAX) g_allowed_v4[g_allowed_n++] = ip;
        }
    }
    free(buf);
    if (!uplink_has_v4) return;
    g_allowed_valid = TRUE;
}

/* lowercase + strip trailing dots into a bounded buffer */
static void norm_host(char *dst, size_t dstsz, const char *src)
{
    size_t i = 0;
    for (; src[i] && i + 1 < dstsz; i++)
        dst[i] = (char)tolower((unsigned char)src[i]);
    while (i && dst[i - 1] == '.') i--;
    dst[i] = 0;
}

/* TRUE iff `name` refers to this host (so filtering it is safe). The gatherer
 * obtains the name from gethostname(), so we match that string (case-insensitive,
 * full and short forms). Server names (proxy.radminte.com, …) never match and
 * pass through untouched. gethostname() here is the real, unhooked ws2_32 one. */
static BOOL is_local_hostname(const char *name)
{
    if (!name || !*name) return FALSE;
    char host[256];
    if (gethostname(host, sizeof host) != 0) return FALSE;
    char a[256], b[256];
    norm_host(a, sizeof a, name);
    norm_host(b, sizeof b, host);
    if (_stricmp(a, b) == 0) return TRUE;
    char *da = strchr(a, '.'); if (da) *da = 0;    /* compare short forms too */
    char *db = strchr(b, '.'); if (db) *db = 0;
    return _stricmp(a, b) == 0;
}

/* Log a gethostbyname call verbatim: the queried name, whether we treat it as the
 * local host, and every A record returned. rc6 only logged on drop, so a silent
 * passthrough (name-gate miss, no allow-set, zero survivors) left us blind to what
 * the gatherer actually asked for -- the exact hole that hid the docker0 leak. */
static void log_ghbn(const char *name, BOOL local, struct hostent *h)
{
    char b[512];
    int n = snprintf(b, sizeof b, "gethostbyname('%s') local=%d ->",
                     name ? name : "(null)", local ? 1 : 0);
    if (h && h->h_addrtype == AF_INET && h->h_addr_list && h->h_addr_list[0]) {
        for (char **rd = h->h_addr_list; *rd && n < (int)sizeof b - 20; rd++) {
            struct in_addr a; a.s_addr = *(DWORD *)*rd;
            n += snprintf(b + n, sizeof b - n, " %s", inet_ntoa(a));
        }
    } else {
        snprintf(b + n, sizeof b - n, " (no A records)");
    }
    dbg(b);
}

static struct hostent *WINAPI hook_gethostbyname(const char *name)
{
    struct hostent *h = real_gethostbyname ? real_gethostbyname(name) : NULL;
    if (!h || h->h_addrtype != AF_INET || !h->h_addr_list) return h;

    BOOL local = is_local_hostname(name);
    log_ghbn(name, local, h);
    if (!local) return h;                       /* server/peer lookups: never touch */

    /* Local-hostname == candidate gathering (the only consumer). Filter hard to
     * {uplink, TAP}; on any uncertainty EMPTY the result rather than pass through.
     * The real caller (FUN_1004b760) checks h_addr_list[0] == NULL and skips, so an
     * empty list is safe; advertising zero host candidates just falls back to the
     * relay path, which is what we want. See the policy note above. */
    build_allowed_v4();
    if (!g_allowed_valid) {
        h->h_addr_list[0] = NULL;
        dbg("filter(gethostbyname): allow-set unavailable -> emptied local candidates");
        return h;
    }

    char **rd = h->h_addr_list, **wr = h->h_addr_list;
    int kept = 0, dropped = 0;
    for (; *rd; rd++) {
        if (in_allowed_v4(*(DWORD *)*rd)) { *wr++ = *rd; kept++; }
        else dropped++;
    }
    *wr = NULL;
    {
        char b[96];
        snprintf(b, sizeof b, "filter(gethostbyname): kept %d, dropped %d (allow-set=%d)",
                 kept, dropped, g_allowed_n);
        dbg(b);
    }
    return h;
}

static int WINAPI hook_getaddrinfo(const char *node, const char *service,
    const struct addrinfo *hints, struct addrinfo **res)
{
    int rc = real_getaddrinfo ? real_getaddrinfo(node, service, hints, res)
                              : EAI_FAIL;
    if (rc != 0 || !res || !*res) return rc;
    BOOL local = is_local_hostname(node);
    {
        char b[160];
        snprintf(b, sizeof b, "getaddrinfo('%s') local=%d", node ? node : "(null)", local ? 1 : 0);
        dbg(b);
    }
    if (!local) return rc;                          /* protects server lookups */
    build_allowed_v4();
    if (!g_allowed_valid) return rc;

    /* Count allowed AF_INET survivors; if none, pass through (never return
     * success with *res == NULL — the getaddrinfo contract callers rely on). */
    int keep = 0;
    for (struct addrinfo *c = *res; c; c = c->ai_next)
        if (c->ai_family == AF_INET && c->ai_addr &&
            in_allowed_v4(((struct sockaddr_in *)c->ai_addr)->sin_addr.s_addr))
            keep++;
    if (keep == 0) return rc;

    /* Unlink non-AF_INET (v6) and non-allowed v4. Dropped nodes are detached and
     * leaked — bounded (a few local-hostname lookups per session). CBA. */
    struct addrinfo *cur = *res, *prev = NULL;
    int dropped = 0;
    while (cur) {
        BOOL ok = (cur->ai_family == AF_INET && cur->ai_addr &&
                   in_allowed_v4(((struct sockaddr_in *)cur->ai_addr)->sin_addr.s_addr));
        struct addrinfo *next = cur->ai_next;
        if (ok) {
            prev = cur;
        } else {
            if (prev) prev->ai_next = next; else *res = next;
            cur->ai_next = NULL;                     /* detach (leaked) */
            dropped++;
        }
        cur = next;
    }
    if (dropped) {
        char b[96];
        snprintf(b, sizeof b, "filter(getaddrinfo): kept %d, dropped %d local addr(s)",
                 keep, dropped);
        dbg(b);
    }
    return rc;
}

/* ====== Reverse-DNS short-circuit: getnameinfo (issue #16, the real one) ======
 *
 * The candidate/peer path reverse-resolves local IPv4 via getnameinfo (imported
 * by name in both RvControlSvc.exe and RvROLClient.dll; gethostbyaddr is not
 * imported). On a host whose resolver black-holes RFC1918 PTR queries — e.g.
 * systemd-resolved with `hosts: ... resolve ... myhostname` forwarding upstream,
 * where no resolver answers the PTR for docker0's 172.17.0.1 — that call blocks
 * ~5s per attempt and retries for over two minutes, past Radmin's own deadline:
 * "registered but never ready". Diagnosed by ayozetr (A/B via /etc/hosts +
 * tcpdump; reproducible outside Wine with socket.gethostbyaddr('172.17.0.1')).
 *
 * These addresses have no useful PTR and Radmin only ever uses them numerically,
 * so we short-circuit the reverse lookup for private/link-local/CGNAT/loopback
 * IPv4 — return the numeric host (as NI_NUMERICHOST would) and the numeric port,
 * rc 0. Public addresses fall through to the real getnameinfo (they resolve fast
 * and a real PTR may matter). This runs regardless of interface count or our GAA
 * filter — it's an orthogonal, unhooked reverse path. */
static BOOL is_private_v4(DWORD s_addr_net)
{
    DWORD h = ntohl(s_addr_net);
    if ((h & 0xFF000000u) == 0x7F000000u) return TRUE;   /* 127.0.0.0/8  loopback */
    if ((h & 0xFF000000u) == 0x0A000000u) return TRUE;   /* 10.0.0.0/8            */
    if ((h & 0xFFF00000u) == 0xAC100000u) return TRUE;   /* 172.16.0.0/12         */
    if ((h & 0xFFFF0000u) == 0xC0A80000u) return TRUE;   /* 192.168.0.0/16        */
    if ((h & 0xFFFF0000u) == 0xA9FE0000u) return TRUE;   /* 169.254.0.0/16 APIPA  */
    if ((h & 0xFFC00000u) == 0x64400000u) return TRUE;   /* 100.64.0.0/10  CGNAT  */
    return FALSE;
}

static int WSAAPI hook_getnameinfo(const SOCKADDR *sa, socklen_t salen,
    PCHAR host, DWORD hostlen, PCHAR serv, DWORD servlen, INT flags)
{
    if (sa && sa->sa_family == AF_INET &&
        salen >= (socklen_t)sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *si = (const struct sockaddr_in *)sa;
        if (is_private_v4(si->sin_addr.s_addr)) {
            char ip[16];
            lstrcpynA(ip, inet_ntoa(si->sin_addr), sizeof ip);
            if (host && hostlen) lstrcpynA(host, ip, hostlen);
            if (serv && servlen) {
                char pb[8];
                snprintf(pb, sizeof pb, "%u", (unsigned)ntohs(si->sin_port));
                lstrcpynA(serv, pb, servlen);
            }
            { char b[64];
              snprintf(b, sizeof b, "getnameinfo: short-circuit PTR %s", ip);
              dbg(b); }
            return 0;
        }
    }
    return real_getnameinfo
        ? real_getnameinfo(sa, salen, host, hostlen, serv, servlen, flags)
        : EAI_FAIL;
}

/* ====== RegSetKeySecurity hook ======
 *
 * Radmin calls RegSetKeySecurity on the Registration subkey with a DACL
 * that only allows SYSTEM (S-1-5-18). Wine SCM doesn't give the service
 * the SYSTEM SID, so all subsequent RegOpenKeyExW calls get ACCESS_DENIED.
 * We no-op the call — the default permissive DACL is fine for Wine. */

static LONG (WINAPI *real_RegSetKeySecurity)(HKEY hKey, SECURITY_INFORMATION si,
    PSECURITY_DESCRIPTOR psd) = NULL;

static LONG WINAPI hook_RegSetKeySecurity(HKEY hKey, SECURITY_INFORMATION si,
    PSECURITY_DESCRIPTOR psd)
{
    (void)hKey; (void)si; (void)psd;
    dbg("RegSetKeySecurity: blocked (Wine SYSTEM SID workaround)");
    return ERROR_SUCCESS;
}

/* ====== IAT patching ====== */

/* Replace mod's IAT entry for dll!fn with newfn, saving the original into *saved.
 * Match by name when fn != NULL, else by ordinal `ord` (needed for functions a
 * module imports by ordinal — e.g. WS2_32 gethostbyname is ordinal 52, and the
 * name path can never see it). Returns TRUE if the import was found and patched. */
static BOOL hook_import(HMODULE mod, const char *dll, const char *fn, WORD ord,
                        void *newfn, void **saved)
{
    if (!mod) return FALSE;
    PIMAGE_DOS_HEADER dos = (PIMAGE_DOS_HEADER)mod;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return FALSE;
    PIMAGE_NT_HEADERS nt = (PIMAGE_NT_HEADERS)((BYTE *)mod + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return FALSE;
    DWORD rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if (!rva) return FALSE;

    for (PIMAGE_IMPORT_DESCRIPTOR imp =
            (PIMAGE_IMPORT_DESCRIPTOR)((BYTE *)mod + rva); imp->Name; imp++) {
        if (_stricmp((char *)mod + imp->Name, dll) != 0)
            continue;
        PIMAGE_THUNK_DATA orig  = (PIMAGE_THUNK_DATA)((BYTE *)mod + imp->OriginalFirstThunk);
        PIMAGE_THUNK_DATA thunk = (PIMAGE_THUNK_DATA)((BYTE *)mod + imp->FirstThunk);
        for (; orig->u1.AddressOfData; orig++, thunk++) {
            BOOL match;
            if (orig->u1.Ordinal & IMAGE_ORDINAL_FLAG) {
                /* imported by ordinal — only matchable when caller asked for one */
                match = (fn == NULL) &&
                        (IMAGE_ORDINAL(orig->u1.Ordinal) == ord);
            } else {
                if (fn == NULL) continue;
                PIMAGE_IMPORT_BY_NAME bn =
                    (PIMAGE_IMPORT_BY_NAME)((BYTE *)mod + orig->u1.AddressOfData);
                match = (strcmp(bn->Name, fn) == 0);
            }
            if (!match) continue;
            if (saved) *saved = (void *)thunk->u1.Function;
            DWORD old;
            if (!VirtualProtect(&thunk->u1.Function, sizeof(DWORD_PTR), PAGE_READWRITE, &old))
                return FALSE;
            thunk->u1.Function = (DWORD_PTR)newfn;
            VirtualProtect(&thunk->u1.Function, sizeof(DWORD_PTR), old, &old);
            return TRUE;
        }
    }
    return FALSE;
}

/* Hook both iphlpapi enumerators in a module (EXE or RvROLClient.dll). The real_*
 * globals are shared: both modules import the same iphlpapi export, so whichever
 * we patch first captures the genuine function pointer. */
static void hook_iphlpapi(HMODULE mod, const char *tag)
{
    char buf[64];
    if (hook_import(mod, "IPHLPAPI.DLL", "GetAdaptersAddresses", 0,
                    hook_GetAdaptersAddresses, (void **)&real_GetAdaptersAddresses)) {
        snprintf(buf, sizeof(buf), "hooked GetAdaptersAddresses (%s)", tag); dbg(buf);
    }
    if (hook_import(mod, "IPHLPAPI.DLL", "GetAdaptersInfo", 0,
                    hook_GetAdaptersInfo, (void **)&real_GetAdaptersInfo)) {
        snprintf(buf, sizeof(buf), "hooked GetAdaptersInfo (%s)", tag); dbg(buf);
    }
}

/* Hook the ws2_32 name/address sources in a module: gethostbyname (imported by
 * ORDINAL 52), getaddrinfo (forward, by name), and getnameinfo (reverse, by
 * name). Shared real_* globals, same as the iphlpapi pair. */
static void hook_ws2_32(HMODULE mod, const char *tag)
{
    char buf[64];
    if (hook_import(mod, "WS2_32.DLL", NULL, WS2_ORD_GETHOSTBYNAME,
                    hook_gethostbyname, (void **)&real_gethostbyname)) {
        snprintf(buf, sizeof(buf), "hooked gethostbyname (ord 52) (%s)", tag); dbg(buf);
    }
    if (hook_import(mod, "WS2_32.DLL", "getaddrinfo", 0,
                    hook_getaddrinfo, (void **)&real_getaddrinfo)) {
        snprintf(buf, sizeof(buf), "hooked getaddrinfo (%s)", tag); dbg(buf);
    }
    if (hook_import(mod, "WS2_32.DLL", "getnameinfo", 0,
                    hook_getnameinfo, (void **)&real_getnameinfo)) {
        snprintf(buf, sizeof(buf), "hooked getnameinfo (%s)", tag); dbg(buf);
    }
}

/* ---- Catch RvROLClient.dll (dynamically LoadLibrary'd) and hook its IAT ---- */

static volatile LONG g_rol_patched = 0;

static void try_patch_rol(void)
{
    if (g_rol_patched) return;
    HMODULE rol = GetModuleHandleW(L"RvROLClient.dll");
    if (!rol) return;
    if (InterlockedExchange(&g_rol_patched, 1) != 0) return;   /* patch once */
    hook_iphlpapi(rol, "RvROLClient.dll");
    hook_ws2_32(rol, "RvROLClient.dll");
    dbg("RvROLClient.dll IAT patched");
}

static HMODULE (WINAPI *real_LoadLibraryW)(LPCWSTR) = NULL;
static HMODULE (WINAPI *real_LoadLibraryA)(LPCSTR) = NULL;
static HMODULE (WINAPI *real_LoadLibraryExW)(LPCWSTR, HANDLE, DWORD) = NULL;

static HMODULE WINAPI hook_LoadLibraryW(LPCWSTR name)
{
    HMODULE h = real_LoadLibraryW ? real_LoadLibraryW(name) : NULL;
    try_patch_rol();
    return h;
}
static HMODULE WINAPI hook_LoadLibraryA(LPCSTR name)
{
    HMODULE h = real_LoadLibraryA ? real_LoadLibraryA(name) : NULL;
    try_patch_rol();
    return h;
}
static HMODULE WINAPI hook_LoadLibraryExW(LPCWSTR name, HANDLE file, DWORD flags)
{
    HMODULE h = real_LoadLibraryExW ? real_LoadLibraryExW(name, file, flags) : NULL;
    try_patch_rol();
    return h;
}

/* Backup for the LoadLibrary hooks: covers RvROLClient.dll being pulled in by a
 * module other than the EXE (so the EXE's LoadLibrary IAT hook never fires) or
 * being already resident. Connector init happens seconds in, so this wins the
 * race against the first candidate-gather.
 * CBA: 60s @ 100ms poll; if a run shows the DLL loading later, widen the window. */
static DWORD WINAPI rol_watch_thread(LPVOID unused)
{
    (void)unused;
    for (int i = 0; i < 600 && !g_rol_patched; i++) {
        try_patch_rol();
        Sleep(100);
    }
    return 0;
}

/* ====== Exports ====== */

__declspec(dllexport) int AdapterHookInit(void) { return 1; }

/* ====== Entry point ====== */

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)inst; (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        dbg("adapter_hook.dll loaded");

        /* Install crash capture first so a fault anywhere in the service
         * (incl. the packet path) gets dumped to C:\radmin_crash.log. */
        AddVectoredExceptionHandler(1, crash_handler);
        dbg("crash handler installed");

        /* Guard CSetupAdapter's dangling-INetwork release (join-with-many-
         * networks crash). Allocate the recovery TLS slot before arming the
         * detour. Safe no-op on a non-matching binary. */
        g_jmp_tls = TlsAlloc();
        install_release_guard();

        HMODULE exe = GetModuleHandle(NULL);
        if (!exe) {
            dbg("GetModuleHandle(NULL) returned NULL");
            return TRUE;
        }

        /* EXE: iphlpapi enumerators (rename + filter), RegSetKeySecurity no-op,
         * and LoadLibrary hooks to catch RvROLClient.dll's dynamic load. */
        hook_iphlpapi(exe, "RvControlSvc.exe");
        hook_ws2_32(exe, "RvControlSvc.exe");
        hook_import(exe, "ADVAPI32.DLL", "RegSetKeySecurity", 0,
                    hook_RegSetKeySecurity,  (void **)&real_RegSetKeySecurity);
        hook_import(exe, "KERNEL32.dll", "LoadLibraryW", 0,
                    hook_LoadLibraryW,       (void **)&real_LoadLibraryW);
        hook_import(exe, "KERNEL32.dll", "LoadLibraryA", 0,
                    hook_LoadLibraryA,       (void **)&real_LoadLibraryA);
        hook_import(exe, "KERNEL32.dll", "LoadLibraryExW", 0,
                    hook_LoadLibraryExW,     (void **)&real_LoadLibraryExW);

        /* RvROLClient.dll may already be resident; otherwise the LoadLibrary hooks
         * and the watcher thread will catch it once it loads. */
        try_patch_rol();
        { HANDLE t = CreateThread(NULL, 0, rol_watch_thread, NULL, 0, NULL);
          if (t) CloseHandle(t); }

        if (real_GetAdaptersAddresses && real_RegSetKeySecurity)
            dbg("core IAT hooks installed");
        else
            dbg("WARNING: some core IAT hooks failed");
    }
    return TRUE;
}
