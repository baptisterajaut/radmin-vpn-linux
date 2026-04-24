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

#define TAP_DESC     L"radminvpn0"
#define RADMIN_DESC  L"Famatech Radmin VPN Ethernet Adapter"
#define RADMIN_FRIENDLY L"Radmin VPN"

/* ====== Logging ====== */

static void dbg(const char *msg)
{
    HANDLE f = CreateFileA("C:\\radmin_hook_debug.log",
        FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE) {
        DWORD w;
        WriteFile(f, msg, strlen(msg), &w, NULL);
        WriteFile(f, "\r\n", 2, &w, NULL);
        CloseHandle(f);
    }
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
                    VirtualProtect(&thunk->u1.Function, sizeof(DWORD_PTR), PAGE_READWRITE, &old);
                    thunk->u1.Function = (DWORD_PTR)hook_GetAdaptersAddresses;
                    VirtualProtect(&thunk->u1.Function, sizeof(DWORD_PTR), old, &old);
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
                    VirtualProtect(&thunk->u1.Function, sizeof(DWORD_PTR), PAGE_READWRITE, &old);
                    thunk->u1.Function = (DWORD_PTR)hook_RegSetKeySecurity;
                    VirtualProtect(&thunk->u1.Function, sizeof(DWORD_PTR), old, &old);
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
