#include "smc.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    char major, minor, build, reserved[1];
    uint16_t release;
} SMCVers;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

static io_connect_t conn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

static int call(SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCParam), out, &outSize);
    if (kr != KERN_SUCCESS) return (int)kr;
    return out->result != 0 ? 1 : 0;
}

int smc_open(void) {
    if (conn) return 0;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) { conn = 0; return (int)kr; }
    return 0;
}

void smc_close(void) {
    if (conn) IOServiceClose(conn);
    conn = 0;
}

static int key_info(const char *key, SMCKeyInfo *info) {
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    int rc = call(&in, &out);
    if (rc) return rc;
    *info = out.keyInfo;
    return 0;
}

int smc_read(const char *key, uint8_t *outBytes, uint32_t *size, char *type) {
    if (smc_open()) return 1;
    SMCKeyInfo info;
    int rc = key_info(key, &info);
    if (rc) return rc;
    if (info.dataSize == 0 || info.dataSize > 32) return 2;

    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    rc = call(&in, &out);
    if (rc) return rc;

    memcpy(outBytes, out.bytes, info.dataSize);
    *size = info.dataSize;
    if (type) {
        type[0] = (char)(info.dataType >> 24);
        type[1] = (char)(info.dataType >> 16);
        type[2] = (char)(info.dataType >> 8);
        type[3] = (char)info.dataType;
        type[4] = 0;
    }
    return 0;
}

int smc_write(const char *key, const uint8_t *data, uint32_t size) {
    if (smc_open()) return 1;
    SMCKeyInfo info;
    int rc = key_info(key, &info);
    if (rc) return rc;
    if (info.dataSize != size) return 3;

    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, data, size);
    return call(&in, &out);
}
