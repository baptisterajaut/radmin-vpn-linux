/*
 * rvpn_launcher.exe - Loads adapter_hook.dll then becomes RvControlSvc.exe
 * Usage: wine rvpn_launcher.exe /run
 */
#include <windows.h>
#include <stdio.h>

int main(int argc, char *argv[])
{
    char exe_dir[MAX_PATH];
    char cmdline[1024];
    char dll_path_buf[MAX_PATH];
    int i;
    STARTUPINFOA si = {sizeof(si)};
    PROCESS_INFORMATION pi = {0};

    /* Resolve directory of this exe */
    GetModuleFileNameA(NULL, exe_dir, MAX_PATH);
    { char *p = strrchr(exe_dir, '\\'); if (p) *p = '\0'; }

    snprintf(cmdline, sizeof(cmdline), "%s\\RvControlSvc.exe", exe_dir);

    /* Build command line with original args */
    for (i = 1; i < argc; i++) {
        strcat(cmdline, " ");
        strcat(cmdline, argv[i]);
    }

    /* Create the service process suspended */
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, FALSE,
                        CREATE_SUSPENDED, NULL, exe_dir, &si, &pi)) {
        printf("CreateProcess failed: %lu\n", GetLastError());
        return 1;
    }

    /* Write a LoadLibrary shellcode into the target process */
    {
        snprintf(dll_path_buf, sizeof(dll_path_buf), "%s\\adapter_hook.dll", exe_dir);
        const char *dll_path = dll_path_buf;
        SIZE_T path_len = strlen(dll_path) + 1;
        LPVOID remote_str;
        HANDLE remote_thread;
        FARPROC loadlib;

        /* Allocate memory in target for DLL path string */
        remote_str = VirtualAllocEx(pi.hProcess, NULL, path_len,
                                     MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (!remote_str) goto skip_inject;

        /* Write DLL path */
        WriteProcessMemory(pi.hProcess, remote_str, dll_path, path_len, NULL);

        /* Get LoadLibraryA address (same in all processes) */
        loadlib = GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryA");
        if (!loadlib) goto skip_inject;

        /* Create remote thread to call LoadLibraryA(dll_path) */
        remote_thread = CreateRemoteThread(pi.hProcess, NULL, 0,
                                           (LPTHREAD_START_ROUTINE)loadlib,
                                           remote_str, 0, NULL);
        if (remote_thread) {
            WaitForSingleObject(remote_thread, 5000);
            CloseHandle(remote_thread);
        }

        /* Reclaim the path buffer in the target — LoadLibraryA has copied
         * the string into its own state by now, and this allocation would
         * otherwise live for the whole lifetime of the service. */
        VirtualFreeEx(pi.hProcess, remote_str, 0, MEM_RELEASE);
    }
skip_inject:

    /* Resume the main thread */
    ResumeThread(pi.hThread);

    /* Wait for the service to exit */
    WaitForSingleObject(pi.hProcess, INFINITE);

    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 0;
}
