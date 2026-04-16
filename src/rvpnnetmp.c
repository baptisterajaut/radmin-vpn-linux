/*
 * rvpnnetmp.sys - Wine kernel driver shim for Radmin VPN
 *
 * Creates \Device\RVPNNETMP and \DosDevices\RVPNNETMP so that
 * RvControlSvc.exe can open \\.\RVPNNETMP and exchange ethernet
 * frames.  Relays frames to/from the Linux TAP device via two FIFOs
 * managed by the companion tap_bridge process.
 *
 * Frame format (mode >= 2, set by SETUP IOCTL):
 *   Service Read/Write: [u32 dest_mac_prefix][u32 frame_len][frame_data]...
 *   FIFO (bridge):      [u16 frame_len][frame_data]
 *
 * FIFOs:
 *   Z:\tmp\rvpn_b2d — bridge-to-driver: incoming frames (TAP → service)
 *   Z:\tmp\rvpn_d2b — driver-to-bridge: outgoing frames (service → TAP)
 *
 * Build (64-bit PE for Wine):
 *   x86_64-w64-mingw32-gcc -shared -o rvpnnetmp.sys rvpnnetmp.c \
 *       -I/usr/x86_64-w64-mingw32/include/ddk \
 *       -lntoskrnl -lhal -nostdlib \
 *       -Wl,--subsystem,native -Wl,--entry,DriverEntry
 */

#include <ntddk.h>

#define DEVICE_NAME     L"\\Device\\RVPNNETMP"
#define DOSDEVICE_NAME  L"\\DosDevices\\RVPNNETMP"

/* FIFO paths (Wine Z: drive maps to /) */
#define FIFO_B2D_PATH   L"\\??\\Z:\\tmp\\rvpn_b2d"
#define FIFO_D2B_PATH   L"\\??\\Z:\\tmp\\rvpn_d2b"

/* Adapter MAC — loaded from /tmp/rvpn_mac (6 raw bytes, written by run.sh).
 * Must match the TAP device MAC. Falls back to a default if file missing. */
#define MAC_FILE_PATH L"\\??\\Z:\\tmp\\rvpn_mac"
static UCHAR g_adapter_mac[6] = { 0x02, 0x50, 0xDE, 0xAD, 0xBE, 0xEF };
static BOOLEAN g_mac_loaded = FALSE;

/* Minimum ethernet frame size for TLV padding */
#define ETH_FRAME_MIN 60

typedef struct _DEVICE_EXTENSION {
    BOOLEAN Connected;
    UCHAR   MacAddress[6];
    LONG    IoctlCount;
    LONG    StatusCount;
    ULONG   SetupMode;   /* Set by SETUP IOCTL (0x22801c), controls TLV format */
    HANDLE  FifoB2D;     /* bridge→driver (read incoming frames) */
    HANDLE  FifoD2B;     /* driver→bridge (write outgoing frames) */
} DEVICE_EXTENSION, *PDEVICE_EXTENSION;

/* Forward decl — we need the device object in the RX thread for TLV encoding */
static PDEVICE_OBJECT g_DeviceObject = NULL;

/* ============ Logging ============ */

static void drv_log(const char *msg)
{
    UNICODE_STRING fileName;
    OBJECT_ATTRIBUTES oa;
    IO_STATUS_BLOCK iosb;
    HANDLE hFile;
    NTSTATUS st;

    RtlInitUnicodeString(&fileName, L"\\??\\C:\\radmin_driver.log");
    InitializeObjectAttributes(&oa, &fileName, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);

    st = ZwCreateFile(&hFile, FILE_APPEND_DATA | SYNCHRONIZE, &oa, &iosb,
                      NULL, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ | FILE_SHARE_WRITE,
                      FILE_OPEN_IF, FILE_SYNCHRONOUS_IO_NONALERT, NULL, 0);
    if (NT_SUCCESS(st)) {
        ULONG len = 0;
        const char *p = msg;
        while (*p++) len++;
        ZwWriteFile(hFile, NULL, NULL, NULL, &iosb, (PVOID)msg, len, NULL, NULL);
        ZwWriteFile(hFile, NULL, NULL, NULL, &iosb, (PVOID)"\r\n", 2, NULL, NULL);
        ZwClose(hFile);
    }
}

static void hex32(char *out, ULONG val)
{
    static const char hx[] = "0123456789abcdef";
    out[0] = hx[(val >> 28) & 0xf]; out[1] = hx[(val >> 24) & 0xf];
    out[2] = hx[(val >> 20) & 0xf]; out[3] = hx[(val >> 16) & 0xf];
    out[4] = hx[(val >> 12) & 0xf]; out[5] = hx[(val >>  8) & 0xf];
    out[6] = hx[(val >>  4) & 0xf]; out[7] = hx[(val      ) & 0xf];
    out[8] = 0;
}

static void drv_log_ioctl(ULONG code, ULONG inLen, ULONG outLen, const UCHAR *data, ULONG dataLen)
{
    char buf[256];
    char *p = buf;
    const char *prefix = "IOCTL 0x";
    while (*prefix) *p++ = *prefix++;
    hex32(p, code); p += 8;
    *p++ = ' '; *p++ = 'i'; *p++ = 'n'; *p++ = '=';
    hex32(p, inLen); p += 8;
    *p++ = ' '; *p++ = 'o'; *p++ = 'u'; *p++ = 't'; *p++ = '=';
    hex32(p, outLen); p += 8;
    if (data && dataLen > 0) {
        *p++ = ' '; *p++ = 'd'; *p++ = '=';
        ULONG i;
        for (i = 0; i < dataLen && i < 32 && (p - buf) < 240; i++) {
            static const char hx2[] = "0123456789abcdef";
            *p++ = hx2[(data[i] >> 4) & 0xf];
            *p++ = hx2[data[i] & 0xf];
        }
    }
    *p = 0;
    drv_log(buf);
}

/* ============ FIFO helpers ============ */

static HANDLE open_fifo(const WCHAR *path, ACCESS_MASK access)
{
    UNICODE_STRING uPath;
    OBJECT_ATTRIBUTES oa;
    IO_STATUS_BLOCK iosb;
    HANDLE h = NULL;
    NTSTATUS st;

    RtlInitUnicodeString(&uPath, path);
    InitializeObjectAttributes(&oa, &uPath, OBJ_CASE_INSENSITIVE, NULL, NULL);

    st = ZwCreateFile(&h, access | SYNCHRONIZE, &oa, &iosb,
                      NULL, FILE_ATTRIBUTE_NORMAL,
                      FILE_SHARE_READ | FILE_SHARE_WRITE,
                      FILE_OPEN, FILE_SYNCHRONOUS_IO_NONALERT, NULL, 0);
    if (!NT_SUCCESS(st)) {
        char buf[80] = "FIFO open failed: 0x";
        hex32(buf + 20, (ULONG)st);
        drv_log(buf);
        return NULL;
    }
    return h;
}

/* ============ ICMP detection helper ============
 * Returns 1 if the raw ethernet frame is IPv4 ICMP (ethertype 0x0800, proto 1).
 * frame must be at least 34 bytes (14 eth + 20 IP minimum). */
static int is_ipv4_icmp(const UCHAR *frame, USHORT len)
{
    if (len < 34) return 0;
    /* Ethertype at offset 12-13 (big-endian): 0x0800 = IPv4 */
    if (frame[12] != 0x08 || frame[13] != 0x00) return 0;
    /* IP protocol at offset 23: 1 = ICMP */
    return (frame[23] == 1);
}

static volatile LONG g_icmp_rx = 0;   /* TAP → service (outbound ICMP) */
static volatile LONG g_icmp_tx = 0;   /* service → TAP (inbound ICMP) */

/* ============ RX ring buffer + pending IRP ============ */

#define RX_RING_SIZE 64
#define RX_FRAME_MAX 1600

typedef struct _RX_RING {
    volatile LONG write_idx;
    volatile LONG read_idx;
    struct {
        USHORT len;
        UCHAR  data[RX_FRAME_MAX];
    } frames[RX_RING_SIZE];
} RX_RING;

static RX_RING g_rx_ring;

/* ============ IRP queue (replaces single pending IRP slot) ============
 * The service issues overlapped ReadFile calls. Each creates an IRP.
 * We queue them FIFO. When a frame arrives, the RX thread dequeues
 * the oldest IRP and completes it with TLV data. Wine delivers the
 * completion to the correct ReadFile caller. This is what the real
 * NDIS miniport driver does (confirmed from RE of NetMP60_1_1_64.sys). */

#define IRP_QUEUE_SIZE 256

static struct {
    KSPIN_LOCK Lock;
    PIRP       Irps[IRP_QUEUE_SIZE];
    LONG       Head;   /* dequeue from here (oldest) */
    LONG       Tail;   /* enqueue here (newest) */
    LONG       Count;
    PFILE_OBJECT FileObjs[IRP_QUEUE_SIZE]; /* parallel to Irps[] */
} g_irp_queue;

/* Per-handle peer MAC routing table.
 * IOCTL_RVPN_PEERMAC associates a MAC with the calling FILE_OBJECT.
 * The RX thread uses this to route frames to the right handle. */
#define MAX_PEER_ROUTES 1024
static struct {
    PFILE_OBJECT fo;
    UCHAR mac[6];
} g_peer_routes[MAX_PEER_ROUTES];
static volatile LONG g_peer_route_count = 0;

/* Diagnostic counters */
static volatile LONG g_ring_enqueued = 0;
static volatile LONG g_ring_consumed = 0;
static volatile LONG g_ring_dropped  = 0;
static volatile LONG g_irp_completed = 0;

/* ============ TLV encoding for Read path ============
 *
 * Mode 3: [u32 dest_mac_prefix][u32 frame_len][frame_data (min 60, zero-padded)]
 * The dest_mac_prefix is the first 4 bytes of the frame's destination MAC.
 *
 * Returns total bytes written to outBuf.
 */
static ULONG tlv_encode_frame(PUCHAR outBuf, ULONG bufRemain, const UCHAR *frame, USHORT frameLen, ULONG setupMode)
{
    ULONG paddedLen = (frameLen < ETH_FRAME_MIN) ? ETH_FRAME_MIN : (ULONG)frameLen;
    ULONG headerSize = (setupMode >= 2) ? 8 : 4;  /* mac_prefix(4) + len(4) or just len(4) */
    ULONG needed = headerSize + paddedLen;

    if (needed > bufRemain)
        return 0;  /* doesn't fit */

    ULONG pos = 0;

    /* Mode >= 2: prepend 4-byte dest MAC prefix in host byte order.
     * The real driver byte-swaps (ntohl) the first 4 bytes of the destination MAC.
     * The service compares this against registered peer MACs stored as host-order u32s.
     * Without the swap, unicast frames don't match any peer → silently dropped. */
    if (setupMode >= 2) {
        ULONG macPrefix = 0;
        if (frameLen >= 4) {
            ULONG raw;
            RtlCopyMemory(&raw, frame, 4);
            macPrefix = (raw << 24) | ((raw & 0xff00) << 8) |
                        ((raw >> 8) & 0xff00) | (raw >> 24);
        }
        RtlCopyMemory(outBuf + pos, &macPrefix, 4);
        /* Log first 3 READ mac_prefix values for comparison with WRITE */
        {
            static LONG rd_mac_log = 0;
            if (InterlockedIncrement(&rd_mac_log) <= 3) {
                char buf[80] = "RD mac=";
                static const char hx4[] = "0123456789abcdef";
                UCHAR *mb = (UCHAR *)&macPrefix;
                int j;
                for (j = 0; j < 4; j++) {
                    buf[7 + j*2] = hx4[(mb[j] >> 4) & 0xf];
                    buf[8 + j*2] = hx4[mb[j] & 0xf];
                }
                /* Also show raw dst MAC bytes */
                buf[15] = ' '; buf[16] = 'd'; buf[17] = 's'; buf[18] = 't'; buf[19] = '=';
                for (j = 0; j < 6 && j < frameLen; j++) {
                    buf[20 + j*2] = hx4[(frame[j] >> 4) & 0xf];
                    buf[21 + j*2] = hx4[frame[j] & 0xf];
                }
                buf[20 + (j < 6 ? j : 6)*2] = 0;
                drv_log(buf);
            }
        }
        pos += 4;
    }

    /* Frame length (u32 LE) */
    RtlCopyMemory(outBuf + pos, &paddedLen, 4);
    pos += 4;

    /* Frame data */
    RtlCopyMemory(outBuf + pos, frame, frameLen);
    pos += frameLen;

    /* Zero-pad to minimum 60 bytes */
    if (frameLen < ETH_FRAME_MIN) {
        RtlZeroMemory(outBuf + pos, ETH_FRAME_MIN - frameLen);
        pos += (ETH_FRAME_MIN - frameLen);
    }

    return pos;
}

/* Complete a Read IRP with one frame, TLV-encoded */
static void complete_read_irp(PIRP irp, const UCHAR *frame, USHORT frameLen)
{
    PUCHAR outBuf = NULL;
    if (irp->MdlAddress)
        outBuf = (PUCHAR)MmGetSystemAddressForMdlSafe(irp->MdlAddress, NormalPagePriority);

    if (!outBuf || frameLen == 0) {
        irp->IoStatus.Status = STATUS_SUCCESS;
        irp->IoStatus.Information = 0;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
        return;
    }

    PIO_STACK_LOCATION irpSp = IoGetCurrentIrpStackLocation(irp);
    ULONG bufLen = irpSp->Parameters.Read.Length;

    /* Get setup mode */
    ULONG mode = 0;
    if (g_DeviceObject) {
        PDEVICE_EXTENSION ext = (PDEVICE_EXTENSION)g_DeviceObject->DeviceExtension;
        mode = ext->SetupMode;
    }

    ULONG written = tlv_encode_frame(outBuf, bufLen, frame, frameLen, mode);

    irp->IoStatus.Status = STATUS_SUCCESS;
    irp->IoStatus.Information = written;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
}

/* ============ RX thread ============ */

static void __stdcall rx_thread_proc(PVOID context)
{
    HANDLE fifo = (HANDLE)context;
    IO_STATUS_BLOCK iosb;
    NTSTATUS st;
    LONG rx_count = 0;
    UCHAR frameBuf[RX_FRAME_MAX];

    drv_log("RX thread started");

    while (1) {
        USHORT frameLen = 0;

        st = ZwReadFile(fifo, NULL, NULL, NULL, &iosb,
                        &frameLen, sizeof(frameLen), NULL, NULL);
        if (!NT_SUCCESS(st) || iosb.Information != sizeof(frameLen)) {
            char buf[96] = "RX exit: st=0x";
            hex32(buf + 14, (ULONG)st);
            char *p = buf + 22;
            *p++ = ' '; *p++ = 'n'; *p++ = '=';
            hex32(p, (ULONG)rx_count);
            drv_log(buf);
            break;
        }

        if (frameLen == 0 || frameLen > RX_FRAME_MAX) {
            UCHAR drain[64];
            USHORT rem = frameLen;
            while (rem > 0) {
                USHORT chunk = rem > 64 ? 64 : rem;
                ZwReadFile(fifo, NULL, NULL, NULL, &iosb, drain, chunk, NULL, NULL);
                if (iosb.Information == 0) break;
                rem -= (USHORT)iosb.Information;
            }
            continue;
        }

        st = ZwReadFile(fifo, NULL, NULL, NULL, &iosb,
                        frameBuf, frameLen, NULL, NULL);
        if (!NT_SUCCESS(st) || iosb.Information != frameLen)
            break;

        rx_count++;

        /* Log every ICMP frame from TAP (outbound: Linux → peer) */
        if (is_ipv4_icmp(frameBuf, frameLen)) {
            LONG n = InterlockedIncrement(&g_icmp_rx);
            char buf[64] = "ICMP-OUT #";
            hex32(buf + 10, (ULONG)n);
            buf[18] = ' '; buf[19] = 'l'; buf[20] = '=';
            hex32(buf + 21, (ULONG)frameLen);
            buf[29] = 0;
            drv_log(buf);
        }

        /* Route frame to the correct handle based on dest MAC.
         * PEERMAC IOCTL registered which FILE_OBJECT handles which MAC.
         * Broadcast frames (FF:FF:FF:FF:FF:FF) go to one IRP per handle. */
        {
            KIRQL oldIrql;
            KeAcquireSpinLock(&g_irp_queue.Lock, &oldIrql);
            if (g_irp_queue.Count > 0) {
                UCHAR *dstMac = frameBuf;  /* first 6 bytes = ethernet dest MAC */
                int is_bcast = (frameLen >= 6 &&
                    dstMac[0] == 0xFF && dstMac[1] == 0xFF && dstMac[2] == 0xFF &&
                    dstMac[3] == 0xFF && dstMac[4] == 0xFF && dstMac[5] == 0xFF);

                /* Find the right FILE_OBJECT for unicast.
                 * Slots with fo == NULL were released by DispatchClose and
                 * will be reused by the next PEERMAC; skip them here. */
                PFILE_OBJECT target_fo = NULL;
                if (!is_bcast && frameLen >= 6) {
                    LONG rc = g_peer_route_count;
                    if (rc > MAX_PEER_ROUTES) rc = MAX_PEER_ROUTES;
                    for (LONG r = 0; r < rc; r++) {
                        if (g_peer_routes[r].fo != NULL &&
                            RtlCompareMemory(g_peer_routes[r].mac, dstMac, 6) == 6) {
                            target_fo = g_peer_routes[r].fo;
                            break;
                        }
                    }
                }

                if (is_bcast) {
                    /* Broadcast: deliver to one IRP per unique FILE_OBJECT.
                     * Sized to IRP_QUEUE_SIZE so the fanout can't silently
                     * truncate — with N peers each holding a pending read,
                     * the queue itself caps the number of distinct FOs.
                     * Static because only one RX thread ever enters this
                     * branch, and only while holding g_irp_queue.Lock —
                     * so no concurrent reuse, and we keep the kernel
                     * stack small (mingw inserts ___chkstk_ms for >4KB
                     * frames, which the kernel link doesn't resolve). */
                    static PIRP batch[IRP_QUEUE_SIZE];
                    static PFILE_OBJECT seen[IRP_QUEUE_SIZE];
                    LONG batch_n = 0;
                    LONG seen_n = 0;
                    LONG remaining = 0;

                    for (LONG i = 0; i < g_irp_queue.Count; i++) {
                        LONG idx = (g_irp_queue.Head + i) % IRP_QUEUE_SIZE;
                        PFILE_OBJECT fo = g_irp_queue.FileObjs[idx];
                        int already = 0;
                        for (LONG s = 0; s < seen_n; s++) {
                            if (seen[s] == fo) { already = 1; break; }
                        }
                        if (!already && seen_n < IRP_QUEUE_SIZE) {
                            seen[seen_n++] = fo;
                            batch[batch_n++] = g_irp_queue.Irps[idx];
                            /* Mark slot as consumed by shifting */
                        } else {
                            /* Keep this IRP in queue (compact later) */
                            g_irp_queue.Irps[remaining] = g_irp_queue.Irps[idx];
                            g_irp_queue.FileObjs[remaining] = g_irp_queue.FileObjs[idx];
                            remaining++;
                        }
                    }
                    g_irp_queue.Head = 0;
                    g_irp_queue.Tail = remaining;
                    g_irp_queue.Count = remaining;
                    KeReleaseSpinLock(&g_irp_queue.Lock, oldIrql);

                    for (LONG i = 0; i < batch_n; i++) {
                        complete_read_irp(batch[i], frameBuf, frameLen);
                        InterlockedIncrement(&g_irp_completed);
                    }
                } else if (target_fo) {
                    /* Unicast: find IRP from matching FILE_OBJECT */
                    PIRP found = NULL;
                    LONG remaining = 0;
                    for (LONG i = 0; i < g_irp_queue.Count; i++) {
                        LONG idx = (g_irp_queue.Head + i) % IRP_QUEUE_SIZE;
                        if (!found && g_irp_queue.FileObjs[idx] == target_fo) {
                            found = g_irp_queue.Irps[idx];
                        } else {
                            g_irp_queue.Irps[remaining] = g_irp_queue.Irps[idx];
                            g_irp_queue.FileObjs[remaining] = g_irp_queue.FileObjs[idx];
                            remaining++;
                        }
                    }
                    g_irp_queue.Head = 0;
                    g_irp_queue.Tail = remaining;
                    g_irp_queue.Count = remaining;
                    KeReleaseSpinLock(&g_irp_queue.Lock, oldIrql);

                    if (found) {
                        complete_read_irp(found, frameBuf, frameLen);
                        InterlockedIncrement(&g_irp_completed);
                    }
                } else {
                    /* No route — fallback: oldest IRP */
                    PIRP irp = g_irp_queue.Irps[g_irp_queue.Head];
                    g_irp_queue.Head = (g_irp_queue.Head + 1) % IRP_QUEUE_SIZE;
                    g_irp_queue.Count--;
                    KeReleaseSpinLock(&g_irp_queue.Lock, oldIrql);
                    complete_read_irp(irp, frameBuf, frameLen);
                    InterlockedIncrement(&g_irp_completed);
                }
                continue;
            }
            KeReleaseSpinLock(&g_irp_queue.Lock, oldIrql);
        }

        /* No pending IRP — fall back to ring buffer */
        LONG widx = g_rx_ring.write_idx;
        LONG ridx = g_rx_ring.read_idx;
        if (widx - ridx >= RX_RING_SIZE) {
            InterlockedIncrement(&g_ring_dropped);
            static LONG drops = 0;
            if (InterlockedIncrement(&drops) <= 3)
                drv_log("RX ring full, drop");
            continue;
        }

        LONG slot = widx % RX_RING_SIZE;
        RtlCopyMemory(g_rx_ring.frames[slot].data, frameBuf, frameLen);
        g_rx_ring.frames[slot].len = frameLen;
        InterlockedIncrement(&g_rx_ring.write_idx);
        InterlockedIncrement(&g_ring_enqueued);
    }

    /* Log diagnostic counters at exit */
    {
        char buf[160] = "RX stats: irp=";
        hex32(buf + 14, (ULONG)g_irp_completed);
        char *p = buf + 22;
        *p++ = ' '; *p++ = 'r'; *p++ = 'n'; *p++ = 'g'; *p++ = '=';
        hex32(p, (ULONG)g_ring_enqueued);
        p += 8;
        *p++ = ' '; *p++ = 'c'; *p++ = 'o'; *p++ = 'n'; *p++ = '=';
        hex32(p, (ULONG)g_ring_consumed);
        p += 8;
        *p++ = ' '; *p++ = 'd'; *p++ = 'r'; *p++ = 'p'; *p++ = '=';
        hex32(p, (ULONG)g_ring_dropped);
        p += 8;
        *p++ = ' '; *p++ = 'r'; *p++ = 'x'; *p++ = '=';
        hex32(p, (ULONG)rx_count);
        p += 8;
        *p++ = ' '; *p++ = 'I'; *p++ = 'o'; *p++ = '=';
        hex32(p, (ULONG)g_icmp_rx);
        p += 8;
        *p++ = ' '; *p++ = 'I'; *p++ = 'i'; *p++ = '=';
        hex32(p, (ULONG)g_icmp_tx);
        *p = 0;
        drv_log(buf);
    }

    PsTerminateSystemThread(STATUS_SUCCESS);
}

/* ============ Dispatch routines ============ */

static void load_adapter_mac(void)
{
    if (g_mac_loaded) return;
    UNICODE_STRING path;
    RtlInitUnicodeString(&path, MAC_FILE_PATH);
    OBJECT_ATTRIBUTES oa;
    InitializeObjectAttributes(&oa, &path, OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);
    IO_STATUS_BLOCK iosb;
    HANDLE hFile;
    NTSTATUS st = ZwOpenFile(&hFile, FILE_READ_DATA | SYNCHRONIZE, &oa, &iosb,
                              FILE_SHARE_READ, FILE_SYNCHRONOUS_IO_NONALERT);
    if (NT_SUCCESS(st)) {
        UCHAR buf[6];
        st = ZwReadFile(hFile, NULL, NULL, NULL, &iosb, buf, 6, NULL, NULL);
        if (NT_SUCCESS(st) && iosb.Information == 6) {
            RtlCopyMemory(g_adapter_mac, buf, 6);
            char msg[48] = "MAC loaded: ";
            for (int i = 0; i < 6; i++) {
                msg[12 + i*3] = "0123456789abcdef"[buf[i] >> 4];
                msg[13 + i*3] = "0123456789abcdef"[buf[i] & 0xf];
                msg[14 + i*3] = (i < 5) ? ':' : '\0';
            }
            drv_log(msg);
        }
        ZwClose(hFile);
    } else {
        drv_log("MAC file not found, using default");
    }
    g_mac_loaded = TRUE;
}

static NTSTATUS NTAPI DispatchCreate(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    PDEVICE_EXTENSION ext = (PDEVICE_EXTENSION)DeviceObject->DeviceExtension;
    ext->Connected = TRUE;

    load_adapter_mac();

    if (!ext->FifoB2D) {
        ext->FifoB2D = open_fifo(FIFO_B2D_PATH, FILE_READ_DATA);
        if (ext->FifoB2D) {
            drv_log("FIFO b2d opened");
            HANDLE hThread;
            OBJECT_ATTRIBUTES oa2;
            InitializeObjectAttributes(&oa2, NULL, OBJ_KERNEL_HANDLE, NULL, NULL);
            if (NT_SUCCESS(PsCreateSystemThread(&hThread, THREAD_ALL_ACCESS, &oa2,
                                                 NULL, NULL, rx_thread_proc, ext->FifoB2D))) {
                ZwClose(hThread);
                drv_log("RX thread created");
            }
        }
    }
    if (!ext->FifoD2B) {
        ext->FifoD2B = open_fifo(FIFO_D2B_PATH, FILE_WRITE_DATA);
        if (ext->FifoD2B) drv_log("FIFO d2b opened");
    }

    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

static NTSTATUS NTAPI DispatchClose(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    (void)DeviceObject;

    /* Release peer-route slots owned by the closing FILE_OBJECT.
     * Without this the table monotonically grew and would saturate even
     * with a modest peer count if clients reconnected. */
    PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
    PFILE_OBJECT fo = sp->FileObject;
    if (fo) {
        KIRQL oldIrql;
        LONG freed = 0;
        KeAcquireSpinLock(&g_irp_queue.Lock, &oldIrql);
        for (LONG i = 0; i < g_peer_route_count; i++) {
            if (g_peer_routes[i].fo == fo) {
                g_peer_routes[i].fo = NULL;
                RtlZeroMemory(g_peer_routes[i].mac, 6);
                freed++;
            }
        }
        while (g_peer_route_count > 0 &&
               g_peer_routes[g_peer_route_count - 1].fo == NULL)
            g_peer_route_count--;
        LONG wm = g_peer_route_count;
        KeReleaseSpinLock(&g_irp_queue.Lock, oldIrql);

        if (freed > 0) {
            char buf[48] = "CLOSE freed=";
            hex32(buf + 12, (ULONG)freed);
            buf[20] = ' '; buf[21] = 'w'; buf[22] = 'm'; buf[23] = '=';
            hex32(buf + 24, (ULONG)wm);
            buf[32] = 0;
            drv_log(buf);
        }
    }

    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

/* IOCTL codes */
#define IOCTL_RVPN_VERSION  0x0022c004
#define IOCTL_RVPN_STATUS   0x00224018
#define IOCTL_RVPN_SETUP    0x0022801c
#define IOCTL_RVPN_PEERMAC  0x00228014

static NTSTATUS NTAPI DispatchDeviceControl(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    PIO_STACK_LOCATION irpSp = IoGetCurrentIrpStackLocation(Irp);
    ULONG ioctl = irpSp->Parameters.DeviceIoControl.IoControlCode;
    ULONG inLen = irpSp->Parameters.DeviceIoControl.InputBufferLength;
    ULONG outLen = irpSp->Parameters.DeviceIoControl.OutputBufferLength;
    PVOID sysBuffer = Irp->AssociatedIrp.SystemBuffer;
    NTSTATUS status = STATUS_SUCCESS;
    ULONG info = 0;

    PDEVICE_EXTENSION dext = (PDEVICE_EXTENSION)DeviceObject->DeviceExtension;
    InterlockedIncrement(&dext->IoctlCount);

    if (ioctl == IOCTL_RVPN_STATUS) {
        LONG sc = InterlockedIncrement(&dext->StatusCount);
        if (sc <= 3 || (sc % 500) == 0)
            drv_log("IOCTL STATUS poll");
    } else {
        drv_log_ioctl(ioctl, inLen, outLen,
                      (const UCHAR *)sysBuffer, inLen < outLen ? outLen : inLen);
    }

    switch (ioctl) {
    case IOCTL_RVPN_VERSION:
        /* When service sends version=4: return [status=0][MAC 6 bytes][pad to 12]
           Otherwise: return [status=1] (version mismatch) */
        if (outLen >= 12 && sysBuffer) {
            ULONG *inData = (ULONG *)sysBuffer;
            UCHAR *out = (UCHAR *)sysBuffer;
            ULONG reqVer = (inLen >= 4) ? inData[0] : 0;

            if (reqVer == 4) {
                /* Version OK — return MAC address */
                ULONG st_val = 0;
                RtlCopyMemory(out, &st_val, 4);           /* status = 0 */
                RtlCopyMemory(out + 4, g_adapter_mac, 6); /* MAC address */
                RtlZeroMemory(out + 10, 2);                /* padding */
                info = 12;
                drv_log("VERSION: returned MAC");
            } else {
                ULONG st_val = 1;
                RtlCopyMemory(out, &st_val, 4);
                RtlZeroMemory(out + 4, 8);
                info = 12;
            }
        }
        break;

    case IOCTL_RVPN_STATUS:
        if (outLen >= 4 && sysBuffer) {
            *((ULONG *)sysBuffer) = 1;
            info = 4;
        }
        break;

    case IOCTL_RVPN_SETUP:
        if (inLen >= 4 && sysBuffer) {
            dext->SetupMode = *((ULONG *)sysBuffer);
            char buf[48] = "SETUP mode=";
            hex32(buf + 11, dext->SetupMode);
            drv_log(buf);
        }
        break;

    case IOCTL_RVPN_PEERMAC:
        if (inLen >= 6 && sysBuffer) {
            PIO_STACK_LOCATION sp2 = IoGetCurrentIrpStackLocation(Irp);
            PFILE_OBJECT fo = sp2->FileObject;
            KIRQL oldIrql;
            LONG assigned = -1;

            /* Share g_irp_queue.Lock with the RX thread: lookups there
             * already hold it, and slot reuse on DispatchClose needs it
             * too. One lock means no inversion. */
            KeAcquireSpinLock(&g_irp_queue.Lock, &oldIrql);
            for (LONG i = 0; i < g_peer_route_count; i++) {
                if (g_peer_routes[i].fo == NULL) { assigned = i; break; }
            }
            if (assigned < 0 && g_peer_route_count < MAX_PEER_ROUTES)
                assigned = g_peer_route_count++;
            if (assigned >= 0) {
                g_peer_routes[assigned].fo = fo;
                RtlCopyMemory(g_peer_routes[assigned].mac, sysBuffer, 6);
            }
            KeReleaseSpinLock(&g_irp_queue.Lock, oldIrql);

            char buf[64] = "PEERMAC fo=";
            hex32(buf + 11, (ULONG)(ULONG_PTR)fo);
            buf[19] = ' ';
            for (int k = 0; k < 6; k++) {
                UCHAR b = ((UCHAR*)sysBuffer)[k];
                buf[20 + k*3] = "0123456789abcdef"[b >> 4];
                buf[21 + k*3] = "0123456789abcdef"[b & 0xf];
                buf[22 + k*3] = (k < 5) ? ':' : '\0';
            }
            drv_log(buf);
            if (assigned < 0)
                drv_log("PEERMAC table full");
        }
        break;

    default:
        break;
    }

    Irp->IoStatus.Status = status;
    Irp->IoStatus.Information = info;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}

/*
 * DispatchRead — returns TLV-encoded frames to the service.
 *
 * If ring has frames, TLV-encode and return immediately (pack multiple).
 * If ring is empty, pend the IRP for the RX thread.
 */
static NTSTATUS NTAPI DispatchRead(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    PDEVICE_EXTENSION ext = (PDEVICE_EXTENSION)DeviceObject->DeviceExtension;

    if (!ext->FifoB2D) {
        Irp->IoStatus.Status = STATUS_DEVICE_NOT_CONNECTED;
        Irp->IoStatus.Information = 0;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return STATUS_DEVICE_NOT_CONNECTED;
    }

    LONG ridx = g_rx_ring.read_idx;

    if (ridx < g_rx_ring.write_idx) {
        /* Frames available — TLV-encode as many as fit in the buffer */
        PUCHAR outBuf = NULL;
        if (Irp->MdlAddress)
            outBuf = (PUCHAR)MmGetSystemAddressForMdlSafe(Irp->MdlAddress, NormalPagePriority);

        if (!outBuf) {
            Irp->IoStatus.Status = STATUS_SUCCESS;
            Irp->IoStatus.Information = 0;
            IoCompleteRequest(Irp, IO_NO_INCREMENT);
            return STATUS_SUCCESS;
        }

        PIO_STACK_LOCATION irpSp = IoGetCurrentIrpStackLocation(Irp);
        ULONG bufLen = irpSp->Parameters.Read.Length;
        ULONG totalWritten = 0;
        LONG framesReturned = 0;

        while (ridx < g_rx_ring.write_idx) {
            LONG slot = ridx % RX_RING_SIZE;
            USHORT frameLen = g_rx_ring.frames[slot].len;

            ULONG written = tlv_encode_frame(outBuf + totalWritten,
                                              bufLen - totalWritten,
                                              g_rx_ring.frames[slot].data,
                                              frameLen, ext->SetupMode);
            if (written == 0)
                break;  /* no more room */

            totalWritten += written;
            InterlockedIncrement(&g_rx_ring.read_idx);
            InterlockedIncrement(&g_ring_consumed);
            ridx++;
            framesReturned++;
        }

        static LONG read_ok = 0;
        LONG rc = InterlockedIncrement(&read_ok);
        if (rc <= 10 || (rc % 100) == 0) {
            char buf[80] = "READ ring frames=";
            hex32(buf + 17, (ULONG)framesReturned);
            char *p = buf + 25;
            *p++ = ' '; *p++ = 'b'; *p++ = '=';
            hex32(p, totalWritten);
            drv_log(buf);
        }

        Irp->IoStatus.Status = STATUS_SUCCESS;
        Irp->IoStatus.Information = totalWritten;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return STATUS_SUCCESS;
    }

    /* Ring empty — queue IRP for async completion by RX thread.
     * The service uses overlapped I/O, so ReadFile returns STATUS_PENDING
     * immediately. Wine's wineserver delivers the completion when we
     * call IoCompleteRequest later from the RX thread. */
    IoMarkIrpPending(Irp);

    {
        KIRQL oldIrql;
        KeAcquireSpinLock(&g_irp_queue.Lock, &oldIrql);
        if (g_irp_queue.Count >= IRP_QUEUE_SIZE) {
            /* Queue full — drop oldest IRP */
            PIRP oldIrp = g_irp_queue.Irps[g_irp_queue.Head];
            g_irp_queue.Head = (g_irp_queue.Head + 1) % IRP_QUEUE_SIZE;
            g_irp_queue.Count--;
            KeReleaseSpinLock(&g_irp_queue.Lock, oldIrql);
            oldIrp->IoStatus.Status = STATUS_CANCELLED;
            oldIrp->IoStatus.Information = 0;
            IoCompleteRequest(oldIrp, IO_NO_INCREMENT);
            KeAcquireSpinLock(&g_irp_queue.Lock, &oldIrql);
        }
        {
            PIO_STACK_LOCATION sp = IoGetCurrentIrpStackLocation(Irp);
            g_irp_queue.FileObjs[g_irp_queue.Tail] = sp->FileObject;
        }
        g_irp_queue.Irps[g_irp_queue.Tail] = Irp;
        g_irp_queue.Tail = (g_irp_queue.Tail + 1) % IRP_QUEUE_SIZE;
        g_irp_queue.Count++;
        KeReleaseSpinLock(&g_irp_queue.Lock, oldIrql);
    }

    static LONG pend_count = 0;
    LONG pc = InterlockedIncrement(&pend_count);
    if (pc <= 5 || (pc % 500) == 0) {
        char buf[48] = "READ pend #";
        hex32(buf + 11, (ULONG)pc);
        drv_log(buf);
    }

    return STATUS_PENDING;
}

/*
 * DispatchWrite — parses TLV-encoded frames from the service and relays
 * each individual ethernet frame to TAP via the FIFO.
 *
 * Mode 3 format: [u32 mac_prefix][u32 frame_len][frame_data]...
 * Mode < 2:      [u32 frame_len][frame_data]...
 */
static NTSTATUS NTAPI DispatchWrite(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    PDEVICE_EXTENSION ext = (PDEVICE_EXTENSION)DeviceObject->DeviceExtension;
    PIO_STACK_LOCATION irpSp = IoGetCurrentIrpStackLocation(Irp);
    ULONG length = irpSp->Parameters.Write.Length;
    IO_STATUS_BLOCK iosb;

    if (!ext->FifoD2B || length == 0) {
        Irp->IoStatus.Status = STATUS_SUCCESS;
        Irp->IoStatus.Information = length;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return STATUS_SUCCESS;
    }

    PUCHAR inBuf = NULL;
    if (Irp->MdlAddress)
        inBuf = (PUCHAR)MmGetSystemAddressForMdlSafe(Irp->MdlAddress, NormalPagePriority);

    if (!inBuf) {
        Irp->IoStatus.Status = STATUS_SUCCESS;
        Irp->IoStatus.Information = length;
        IoCompleteRequest(Irp, IO_NO_INCREMENT);
        return STATUS_SUCCESS;
    }

    /* Parse TLV and relay each frame to FIFO */
    ULONG offset = 0;
    ULONG mode = ext->SetupMode;
    LONG frameCount = 0;

    while (offset < length) {
        /* Mode >= 2: skip 4-byte mac prefix */
        if (mode >= 2) {
            if (offset + 4 > length) break;
            /* Log first 3 WRITE mac_prefix values for comparison with READ */
            if (frameCount < 3) {
                char buf[64] = "WR mac=";
                static const char hx3[] = "0123456789abcdef";
                int j;
                for (j = 0; j < 4; j++) {
                    buf[7 + j*2] = hx3[(inBuf[offset+j] >> 4) & 0xf];
                    buf[8 + j*2] = hx3[inBuf[offset+j] & 0xf];
                }
                buf[15] = 0;
                drv_log(buf);
            }
            offset += 4;
        }

        /* Read 4-byte frame length */
        if (offset + 4 > length) break;
        ULONG frameLen = *((ULONG *)(inBuf + offset));
        offset += 4;

        /* Sanity check */
        if (frameLen == 0 || frameLen > RX_FRAME_MAX || offset + frameLen > length)
            break;

        /* Log every inbound ICMP (peer → Linux) */
        if (is_ipv4_icmp(inBuf + offset, (USHORT)frameLen)) {
            LONG n = InterlockedIncrement(&g_icmp_tx);
            char buf[64] = "ICMP-IN  #";
            hex32(buf + 10, (ULONG)n);
            buf[18] = ' '; buf[19] = 'l'; buf[20] = '=';
            hex32(buf + 21, (ULONG)frameLen);
            buf[29] = 0;
            drv_log(buf);
        }

        /* Write [u16 len][frame] to FIFO for tap_bridge */
        USHORT fifoLen = (USHORT)frameLen;
        ZwWriteFile(ext->FifoD2B, NULL, NULL, NULL, &iosb,
                    &fifoLen, sizeof(fifoLen), NULL, NULL);
        ZwWriteFile(ext->FifoD2B, NULL, NULL, NULL, &iosb,
                    inBuf + offset, frameLen, NULL, NULL);

        offset += frameLen;
        frameCount++;
    }

    static LONG write_ok = 0;
    LONG wc = InterlockedIncrement(&write_ok);
    if (wc <= 10 || (wc % 100) == 0) {
        char buf[80] = "WRITE tlv frames=";
        hex32(buf + 17, (ULONG)frameCount);
        char *p = buf + 25;
        *p++ = ' '; *p++ = 'r'; *p++ = 'a'; *p++ = 'w'; *p++ = '=';
        hex32(p, length);
        drv_log(buf);
    }

    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = length;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

/* ============ Driver lifecycle ============ */

static VOID NTAPI Unload(PDRIVER_OBJECT DriverObject)
{
    UNICODE_STRING dosDeviceName;
    RtlInitUnicodeString(&dosDeviceName, DOSDEVICE_NAME);
    IoDeleteSymbolicLink(&dosDeviceName);

    /* Drain IRP queue — cancel all pending IRPs */
    {
        KIRQL oldIrql;
        KeAcquireSpinLock(&g_irp_queue.Lock, &oldIrql);
        while (g_irp_queue.Count > 0) {
            PIRP irp = g_irp_queue.Irps[g_irp_queue.Head];
            g_irp_queue.Head = (g_irp_queue.Head + 1) % IRP_QUEUE_SIZE;
            g_irp_queue.Count--;
            KeReleaseSpinLock(&g_irp_queue.Lock, oldIrql);
            irp->IoStatus.Status = STATUS_CANCELLED;
            irp->IoStatus.Information = 0;
            IoCompleteRequest(irp, IO_NO_INCREMENT);
            KeAcquireSpinLock(&g_irp_queue.Lock, &oldIrql);
        }
        KeReleaseSpinLock(&g_irp_queue.Lock, oldIrql);
    }

    if (DriverObject->DeviceObject) {
        PDEVICE_EXTENSION ext = (PDEVICE_EXTENSION)DriverObject->DeviceObject->DeviceExtension;
        if (ext->FifoB2D) ZwClose(ext->FifoB2D);
        if (ext->FifoD2B) ZwClose(ext->FifoD2B);
        IoDeleteDevice(DriverObject->DeviceObject);
    }
}

NTSTATUS NTAPI DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    NTSTATUS status;
    PDEVICE_OBJECT deviceObject = NULL;
    UNICODE_STRING deviceName, dosDeviceName;

    (void)RegistryPath;

    RtlInitUnicodeString(&deviceName, DEVICE_NAME);
    RtlInitUnicodeString(&dosDeviceName, DOSDEVICE_NAME);

    status = IoCreateDevice(
        DriverObject, sizeof(DEVICE_EXTENSION), &deviceName,
        FILE_DEVICE_UNKNOWN, 0, FALSE, &deviceObject);

    if (!NT_SUCCESS(status)) return status;

    status = IoCreateSymbolicLink(&dosDeviceName, &deviceName);
    if (!NT_SUCCESS(status)) {
        IoDeleteDevice(deviceObject);
        return status;
    }

    deviceObject->Flags |= DO_DIRECT_IO;
    deviceObject->Flags &= ~DO_DEVICE_INITIALIZING;

    RtlZeroMemory(deviceObject->DeviceExtension, sizeof(DEVICE_EXTENSION));
    g_DeviceObject = deviceObject;
    KeInitializeSpinLock(&g_irp_queue.Lock);

    DriverObject->MajorFunction[IRP_MJ_CREATE]         = DispatchCreate;
    DriverObject->MajorFunction[IRP_MJ_CLOSE]          = DispatchClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = DispatchDeviceControl;
    DriverObject->MajorFunction[IRP_MJ_READ]            = DispatchRead;
    DriverObject->MajorFunction[IRP_MJ_WRITE]           = DispatchWrite;
    DriverObject->DriverUnload = Unload;

    drv_log("Driver loaded");
    return STATUS_SUCCESS;
}
