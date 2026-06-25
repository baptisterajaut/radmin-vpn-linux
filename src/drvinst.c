/*
 * drvinst.exe — no-op replacement for Radmin's bundled NDIS driver installer.
 *
 * RvControlSvc.exe launches "drvinst.exe install ... Driver.1.1/NetMP60.inf" at
 * runtime to (re)install the real NDIS miniport NetMP60_1_1_64.sys. That driver
 * calls ndis.sys!NdisInitializeReadWriteLock unconditionally in DriverEntry,
 * which Wine 11.x stubs with abort() — so the instant the real driver loads, the
 * service crash-loops (GitHub issue #12). The whole project replaces that
 * adapter with rvpnnetmp.sys, so the real NDIS driver must NEVER load.
 *
 * run.sh overwrites the Radmin-bundled drvinst.exe in the program dir with this
 * stub after install. RvControlSvc invokes it by bare name from its own working
 * directory, so the local copy wins — no WINEDLLOVERRIDES needed. We return 0
 * so the service logs "Virtual adapter driver installed" and proceeds down the
 * working rvpnnetmp IOCTL path instead of trying to load the real miniport.
 */
int main(void) { return 0; }
