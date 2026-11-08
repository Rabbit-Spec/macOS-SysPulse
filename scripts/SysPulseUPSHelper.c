#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/wait.h>

extern IOReturn IOPMSetUPSShutdownLevels(CFTypeRef whichUPS, CFDictionaryRef UPSDict);

// MARK: - AppleSMC Kernel Interface Definitions

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_KEYINFO  9

typedef struct {
    char     major;
    char     minor;
    char     build;
    char     reserved[1];
    uint16_t release;
} SMCKeyData_vers_t;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    uint32_t                key;
    SMCKeyData_vers_t       vers;
    SMCKeyData_pLimitData_t  pLimitData;
    SMCKeyData_keyInfo_t    keyInfo;
    uint8_t                 result;
    uint8_t                 status;
    uint8_t                 data8;
    uint32_t                data32;
    uint8_t                 bytes[32];
} SMCKeyData_t;

static uint32_t smcFourCC(const char *str) {
    return ((uint32_t)(uint8_t)str[0] << 24) |
           ((uint32_t)(uint8_t)str[1] << 16) |
           ((uint32_t)(uint8_t)str[2] << 8)  |
           ((uint32_t)(uint8_t)str[3]);
}

static kern_return_t smcCall(io_connect_t conn, SMCKeyData_t *input, SMCKeyData_t *output) {
    size_t outSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, input, sizeof(SMCKeyData_t), output, &outSize);
}

static kern_return_t smcReadKey(io_connect_t conn, const char *keyStr, SMCKeyData_t *outVal) {
    SMCKeyData_t inData;
    SMCKeyData_t outData;
    memset(&inData, 0, sizeof(inData));
    memset(&outData, 0, sizeof(outData));

    inData.key = smcFourCC(keyStr);
    inData.data8 = SMC_CMD_READ_KEYINFO;

    kern_return_t kr = smcCall(conn, &inData, &outData);
    if (kr != kIOReturnSuccess || outData.result != 0) {
        return kIOReturnError;
    }

    inData.keyInfo.dataSize = outData.keyInfo.dataSize;
    inData.data8 = SMC_CMD_READ_BYTES;

    kr = smcCall(conn, &inData, outVal);
    if (kr != kIOReturnSuccess || outVal->result != 0) {
        return kIOReturnError;
    }
    outVal->keyInfo = outData.keyInfo;
    return kIOReturnSuccess;
}

static kern_return_t smcWriteKey(io_connect_t conn, const char *keyStr, const void *bytes, uint32_t dataSize) {
    SMCKeyData_t inData;
    SMCKeyData_t outData;
    memset(&inData, 0, sizeof(inData));
    memset(&outData, 0, sizeof(outData));

    inData.key = smcFourCC(keyStr);
    inData.data8 = SMC_CMD_READ_KEYINFO;

    kern_return_t kr = smcCall(conn, &inData, &outData);
    if (kr != kIOReturnSuccess || outData.result != 0) {
        return kIOReturnError;
    }

    inData.keyInfo = outData.keyInfo;
    inData.data8 = SMC_CMD_WRITE_BYTES;
    if (dataSize > 32) dataSize = 32;
    memcpy(inData.bytes, bytes, dataSize);

    kr = smcCall(conn, &inData, &outData);
    if (kr != kIOReturnSuccess || outData.result != 0) {
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

static double smcDecodeRPM(const SMCKeyData_t *val) {
    uint32_t type = val->keyInfo.dataType;
    if (type == smcFourCC("flt ") && val->keyInfo.dataSize == 4) {
        float f = 0.0f;
        memcpy(&f, val->bytes, 4);
        return (double)f;
    } else if (type == smcFourCC("fpe2") && val->keyInfo.dataSize == 2) {
        uint16_t raw = ((uint16_t)val->bytes[0] << 8) | (uint16_t)val->bytes[1];
        return (double)(raw >> 2);
    }
    return 0.0;
}

static int applySMCFanControl(int percent) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) {
        return 1;
    }

    io_connect_t conn = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess || conn == IO_OBJECT_NULL) {
        return 2;
    }

    SMCKeyData_t val;
    int fanCount = 1;
    if (smcReadKey(conn, "FNum", &val) == kIOReturnSuccess && val.keyInfo.dataSize >= 1) {
        fanCount = (int)val.bytes[0];
    }
    if (fanCount <= 0) {
        IOServiceClose(conn);
        return 0; // Fanless Mac (e.g. MacBook Air)
    }
    if (fanCount > 4) fanCount = 4;

    // Unlock software fan control on Apple Silicon if Ftst key exists
    if (percent <= 0) {
        uint8_t unlockZero = 0;
        smcWriteKey(conn, "Ftst", &unlockZero, 1);
    } else {
        uint8_t unlockOne = 1;
        smcWriteKey(conn, "Ftst", &unlockOne, 1);
    }

    for (int i = 0; i < fanCount; i++) {
        char mdKey[5], tgKey[5], mnKey[5], mxKey[5];
        snprintf(mdKey, sizeof(mdKey), "F%dMd", i);
        snprintf(tgKey, sizeof(tgKey), "F%dTg", i);
        snprintf(mnKey, sizeof(mnKey), "F%dMn", i);
        snprintf(mxKey, sizeof(mxKey), "F%dMx", i);

        if (percent <= 0) {
            uint8_t autoMode = 0;
            smcWriteKey(conn, mdKey, &autoMode, 1);
        } else {
            double minRPM = 1000.0;
            double maxRPM = 3500.0;
            if (smcReadKey(conn, mnKey, &val) == kIOReturnSuccess) {
                double m = smcDecodeRPM(&val);
                if (m >= 300.0 && m <= 4000.0) minRPM = m;
            }
            if (smcReadKey(conn, mxKey, &val) == kIOReturnSuccess) {
                double m = smcDecodeRPM(&val);
                if (m >= 1500.0 && m <= 9000.0) maxRPM = m;
            }

            double clampedPct = (percent < 10) ? 10.0 : ((percent > 100) ? 100.0 : (double)percent);
            double targetRPM = minRPM + (maxRPM - minRPM) * (clampedPct / 100.0);

            uint8_t manualMode = 1;
            smcWriteKey(conn, mdKey, &manualMode, 1);

            // Check target key dataType (flt vs fpe2)
            SMCKeyData_t tgInfo;
            if (smcReadKey(conn, tgKey, &tgInfo) == kIOReturnSuccess) {
                if (tgInfo.keyInfo.dataType == smcFourCC("flt ")) {
                    float fTarget = (float)targetRPM;
                    smcWriteKey(conn, tgKey, &fTarget, 4);
                } else if (tgInfo.keyInfo.dataType == smcFourCC("fpe2")) {
                    uint16_t fpeTarget = (uint16_t)((int)targetRPM << 2);
                    uint8_t buf[2] = { (uint8_t)(fpeTarget >> 8), (uint8_t)(fpeTarget & 0xFF) };
                    smcWriteKey(conn, tgKey, buf, 2);
                }
            }
        }
    }

    // Legacy Intel FS! bitmask fallback
    if (percent <= 0) {
        uint8_t fsAuto[2] = { 0x00, 0x00 };
        smcWriteKey(conn, "FS! ", fsAuto, 2);
    }

    IOServiceClose(conn);
    return 0;
}

static int applyAWDLState(const char *mode) {
    const char *stateArg = (strcmp(mode, "down") == 0) ? "down" : "up";
    pid_t pid = fork();
    if (pid == 0) {
        char *const args[] = { "/sbin/ifconfig", "awdl0", (char *)stateArg, NULL };
        execv("/sbin/ifconfig", args);
        _exit(127);
    } else if (pid > 0) {
        int status = 0;
        waitpid(pid, &status, 0);
        return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    }
    return 1;
}

static CFDictionaryRef createThresholdEntry(int enabled, int value) {
    CFStringRef keys[2] = { CFSTR("Enabled"), CFSTR("Value") };
    CFNumberRef numVal = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
    CFTypeRef vals[2] = {
        enabled ? kCFBooleanTrue : kCFBooleanFalse,
        numVal
    };
    CFDictionaryRef dict = CFDictionaryCreate(
        kCFAllocatorDefault,
        (const void **)keys,
        (const void **)vals,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFRelease(numVal);
    return dict;
}

int main(int argc, char *argv[]) {
    // Elevate to root if setuid bit is set
    setuid(0);
    seteuid(0);

    if (argc >= 3 && strcmp(argv[1], "--fan") == 0) {
        int percent = atoi(argv[2]);
        return applySMCFanControl(percent);
    }

    if (argc >= 3 && strcmp(argv[1], "--awdl") == 0) {
        return applyAWDLState(argv[2]);
    }

    if (argc < 7) {
        return 1;
    }

    int afterEn   = atoi(argv[1]);
    int afterVal  = atoi(argv[2]);
    int remainEn  = atoi(argv[3]);
    int remainVal = atoi(argv[4]);
    int levelEn   = atoi(argv[5]);
    int levelVal  = atoi(argv[6]);

    CFDictionaryRef afterDict  = createThresholdEntry(afterEn, afterVal);
    CFDictionaryRef remainDict = createThresholdEntry(remainEn, remainVal);
    CFDictionaryRef levelDict  = createThresholdEntry(levelEn, levelVal);

    CFStringRef topKeys[3] = {
        CFSTR("UPSShutdownAfterMinutes"),
        CFSTR("UPSShutdownAtMinutesLeft"),
        CFSTR("UPSShutdownAtLevel")
    };
    CFTypeRef topVals[3] = { afterDict, remainDict, levelDict };

    CFDictionaryRef upsDict = CFDictionaryCreate(
        kCFAllocatorDefault,
        (const void **)topKeys,
        (const void **)topVals,
        3,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );

    IOReturn ret = IOPMSetUPSShutdownLevels(CFSTR("UPSDefaultThresholds"), upsDict);

    CFRelease(afterDict);
    CFRelease(remainDict);
    CFRelease(levelDict);
    CFRelease(upsDict);

    return (ret == kIOReturnSuccess) ? 0 : 2;
}
