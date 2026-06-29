/*
 * adapter_hook.dll — Wine compatibility hooks for Radmin VPN
 *
 * Injected into RvControlSvc.exe by rvpn_launcher.exe.
 * IAT hooks:
 *   - GetAdaptersAddresses: renames Linux TAP to Radmin adapter name
 *   - RegSetKeySecurity: no-op (Wine SCM lacks SYSTEM SID)
 *
 * Build:
 *   i686-w64-mingw32-gcc -shared -o adapter_hook.dll adapter_hook.c \
 *       -liphlpapi -lws2_32 -Wl,--enable-stdcall-fixup
 */

#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>

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

/* ====== GetAdaptersAddresses hook ====== */

static ULONG (WINAPI *real_GetAdaptersAddresses)(
    ULONG, ULONG, PVOID, PIP_ADAPTER_ADDRESSES, PULONG) = NULL;

static ULONG WINAPI hook_GetAdaptersAddresses(
    ULONG Family, ULONG Flags, PVOID Rsvd,
    PIP_ADAPTER_ADDRESSES Addrs, PULONG Size)
{
    if (!real_GetAdaptersAddresses) return ERROR_NOT_SUPPORTED;

    ULONG ret = real_GetAdaptersAddresses(Family, Flags, Rsvd, Addrs, Size);
    if (ret != ERROR_SUCCESS || !Addrs) return ret;

    for (PIP_ADAPTER_ADDRESSES cur = Addrs; cur; cur = cur->Next) {
        if (!cur->Description || wcscmp(cur->Description, TAP_DESC) != 0)
            continue;

        /* Point at read-only string literals: caller frees the whole adapter
         * info buffer in one shot and never touches these fields individually,
         * so we avoid a per-call HeapAlloc that was never freed. */
        cur->Description  = (WCHAR *)RADMIN_DESC;
        cur->FriendlyName = (WCHAR *)RADMIN_FRIENDLY;

        dbg("hook: renamed radminvpn0 -> Famatech Radmin VPN Ethernet Adapter");
    }
    return ret;
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

static void patch_iat(HMODULE mod)
{
    if (!mod) return;

    PIMAGE_DOS_HEADER dos = (PIMAGE_DOS_HEADER)mod;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;

    PIMAGE_NT_HEADERS nt = (PIMAGE_NT_HEADERS)((BYTE *)mod + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return;

    DWORD rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if (!rva) return;

    PIMAGE_IMPORT_DESCRIPTOR imp = (PIMAGE_IMPORT_DESCRIPTOR)((BYTE *)mod + rva);

    for (; imp->Name; imp++) {
        char *dll = (char *)mod + imp->Name;
        PIMAGE_THUNK_DATA orig  = (PIMAGE_THUNK_DATA)((BYTE *)mod + imp->OriginalFirstThunk);
        PIMAGE_THUNK_DATA thunk = (PIMAGE_THUNK_DATA)((BYTE *)mod + imp->FirstThunk);

        if (_stricmp(dll, "IPHLPAPI.DLL") == 0) {
            for (; orig->u1.AddressOfData; orig++, thunk++) {
                if (orig->u1.Ordinal & IMAGE_ORDINAL_FLAG) continue;
                PIMAGE_IMPORT_BY_NAME by_name =
                    (PIMAGE_IMPORT_BY_NAME)((BYTE *)mod + orig->u1.AddressOfData);
                if (strcmp(by_name->Name, "GetAdaptersAddresses") == 0) {
                    real_GetAdaptersAddresses = (void *)thunk->u1.Function;
                    DWORD old;
                    if (!VirtualProtect(&thunk->u1.Function, sizeof(DWORD_PTR), PAGE_READWRITE, &old)) {
                        dbg("VirtualProtect failed for GetAdaptersAddresses");
                        continue;
                    }
                    thunk->u1.Function = (DWORD_PTR)hook_GetAdaptersAddresses;
                    if (!VirtualProtect(&thunk->u1.Function, sizeof(DWORD_PTR), old, &old)) {
                        dbg("VirtualProtect restore failed for GetAdaptersAddresses");
                    }
                    dbg("hooked GetAdaptersAddresses");
                }
            }
        }

        if (_stricmp(dll, "ADVAPI32.DLL") == 0) {
            orig  = (PIMAGE_THUNK_DATA)((BYTE *)mod + imp->OriginalFirstThunk);
            thunk = (PIMAGE_THUNK_DATA)((BYTE *)mod + imp->FirstThunk);
            for (; orig->u1.AddressOfData; orig++, thunk++) {
                if (orig->u1.Ordinal & IMAGE_ORDINAL_FLAG) continue;
                PIMAGE_IMPORT_BY_NAME by_name =
                    (PIMAGE_IMPORT_BY_NAME)((BYTE *)mod + orig->u1.AddressOfData);
                if (strcmp(by_name->Name, "RegSetKeySecurity") == 0) {
                    real_RegSetKeySecurity = (void *)thunk->u1.Function;
                    DWORD old;
                    if (!VirtualProtect(&thunk->u1.Function, sizeof(DWORD_PTR), PAGE_READWRITE, &old)) {
                        dbg("VirtualProtect failed for RegSetKeySecurity");
                        continue;
                    }
                    thunk->u1.Function = (DWORD_PTR)hook_RegSetKeySecurity;
                    if (!VirtualProtect(&thunk->u1.Function, sizeof(DWORD_PTR), old, &old)) {
                        dbg("VirtualProtect restore failed for RegSetKeySecurity");
                    }
                    dbg("hooked RegSetKeySecurity");
                }
            }
        }
    }
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

        patch_iat(exe);

        if (real_GetAdaptersAddresses && real_RegSetKeySecurity)
            dbg("all IAT hooks installed");
        else if (real_GetAdaptersAddresses)
            dbg("WARNING: RegSetKeySecurity hook failed");
        else if (real_RegSetKeySecurity)
            dbg("WARNING: GetAdaptersAddresses hook failed");
        else
            dbg("WARNING: all IAT hooks failed");
    }
    return TRUE;
}
