#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <net/bpf.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>

#define PID_FILE "/tmp/syspulse_psportal.pid"
#define BPF_BUF_LEN 65536
#define OFFSET 334
#define MAX_SEEN_SEQS 128

#pragma pack(push, 1)
struct eth_header {
    uint8_t dst[6];
    uint8_t src[6];
    uint16_t ethertype;
};

struct arp_header {
    uint16_t htype;
    uint16_t ptype;
    uint8_t  hlen;
    uint8_t  plen;
    uint16_t op;
    uint8_t  sha[6];
    uint32_t spa;
    uint8_t  tha[6];
    uint32_t tpa;
};

struct ip_header {
    uint8_t  ihl_ver;
    uint8_t  tos;
    uint16_t tot_len;
    uint16_t id;
    uint16_t frag_off;
    uint8_t  ttl;
    uint8_t  proto;
    uint16_t check;
    uint32_t saddr;
    uint32_t daddr;
};

struct udp_header {
    uint16_t source;
    uint16_t dest;
    uint16_t len;
    uint16_t check;
};

struct udp_pseudo {
    uint32_t src;
    uint32_t dst;
    uint8_t  zero;
    uint8_t  proto;
    uint16_t len;
};
#pragma pack(pop)

static volatile sig_atomic_t g_running = 1;
static int g_bpf_fd = -1;
static char g_iface[32] = "en0";
static uint8_t g_own_mac[6] = {0};
static uint32_t g_own_ip = 0;
static uint8_t g_ps5_mac[6] = {0};
static uint32_t g_ps5_ip = 0;
static uint8_t g_portal_mac[6] = {0};
static uint32_t g_portal_ip = 0;
static int g_has_ps5_mac = 0;
static int g_has_portal_mac = 0;
static int g_orig_redirect = -1;
static int g_orig_forwarding = -1;

static const char b64_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void on_signal(int sig) {
    (void)sig;
    g_running = 0;
}

static int b64_val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static int b64_decode_4(const char *in4, uint8_t out3[3]) {
    int v[4];
    for (int i = 0; i < 4; i++) {
        v[i] = b64_val(in4[i]);
        if (v[i] < 0) return -1;
    }
    out3[0] = (uint8_t)((v[0] << 2) | (v[1] >> 4));
    out3[1] = (uint8_t)(((v[1] & 0xF) << 4) | (v[2] >> 2));
    out3[2] = (uint8_t)(((v[2] & 0x3) << 6) | v[3]);
    return 0;
}

static void b64_encode_4(const uint8_t in3[3], char out4[4]) {
    out4[0] = b64_table[(in3[0] >> 2) & 0x3F];
    out4[1] = b64_table[((in3[0] & 0x3) << 4) | ((in3[1] >> 4) & 0xF)];
    out4[2] = b64_table[((in3[1] & 0xF) << 2) | ((in3[2] >> 6) & 0x3)];
    out4[3] = b64_table[in3[2] & 0x3F];
}

static int b64_decode_8(const char *in8, uint8_t out6[6]) {
    int v[8];
    for (int i = 0; i < 8; i++) {
        v[i] = b64_val(in8[i]);
        if (v[i] < 0) return -1;
    }
    out6[0] = (uint8_t)((v[0] << 2) | (v[1] >> 4));
    out6[1] = (uint8_t)(((v[1] & 0xF) << 4) | (v[2] >> 2));
    out6[2] = (uint8_t)(((v[2] & 0x3) << 6) | v[3]);
    out6[3] = (uint8_t)((v[4] << 2) | (v[5] >> 4));
    out6[4] = (uint8_t)(((v[5] & 0xF) << 4) | (v[6] >> 2));
    out6[5] = (uint8_t)(((v[6] & 0x3) << 6) | v[7]);
    return 0;
}

static void b64_encode_8(const uint8_t in6[6], char out8[8]) {
    out8[0] = b64_table[(in6[0] >> 2) & 0x3F];
    out8[1] = b64_table[((in6[0] & 0x3) << 4) | ((in6[1] >> 4) & 0xF)];
    out8[2] = b64_table[((in6[1] & 0xF) << 2) | ((in6[2] >> 6) & 0x3)];
    out8[3] = b64_table[in6[2] & 0x3F];
    out8[4] = b64_table[(in6[3] >> 2) & 0x3F];
    out8[5] = b64_table[((in6[3] & 0x3) << 4) | ((in6[4] >> 4) & 0xF)];
    out8[6] = b64_table[((in6[4] & 0xF) << 2) | ((in6[5] >> 6) & 0x3)];
    out8[7] = b64_table[in6[5] & 0x3F];
}

static uint16_t calc_checksum(const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    uint32_t sum = 0;
    while (len > 1) {
        sum += ((uint32_t)p[0] << 8) | p[1];
        p += 2;
        len -= 2;
    }
    if (len == 1) {
        sum += ((uint32_t)p[0] << 8);
    }
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (uint16_t)(~sum & 0xFFFF);
}

static uint16_t udp_checksum(struct ip_header *ip, struct udp_header *udp, size_t udp_len) {
    struct udp_pseudo pseudo;
    pseudo.src = ip->saddr;
    pseudo.dst = ip->daddr;
    pseudo.zero = 0;
    pseudo.proto = IPPROTO_UDP;
    pseudo.len = htons((uint16_t)udp_len);

    uint8_t buf[65536];
    memcpy(buf, &pseudo, sizeof(pseudo));
    memcpy(buf + sizeof(pseudo), udp, udp_len);

    uint16_t cs = calc_checksum(buf, sizeof(pseudo) + udp_len);
    return (cs == 0) ? 0xFFFF : cs;
}

static int get_interface_mac_and_ip(const char *ifname, uint8_t mac[6], uint32_t *ip) {
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return -1;
    int found_mac = 0, found_ip = 0;

    for (struct ifaddrs *ifa = ifap; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name || strcmp(ifa->ifa_name, ifname) != 0) continue;
        if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_LINK && !found_mac) {
            struct sockaddr_dl *sdl = (struct sockaddr_dl *)ifa->ifa_addr;
            if (sdl->sdl_alen == 6) {
                memcpy(mac, LLADDR(sdl), 6);
                found_mac = 1;
            }
        }
        if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_INET && !found_ip) {
            struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
            *ip = sin->sin_addr.s_addr;
            found_ip = 1;
        }
    }
    freeifaddrs(ifap);
    return found_mac ? 0 : -1;
}

static int open_bpf_device(const char *ifname) {
    char path[32];
    int fd = -1;
    for (int i = 0; i < 99; i++) {
        snprintf(path, sizeof(path), "/dev/bpf%d", i);
        fd = open(path, O_RDWR);
        if (fd >= 0) break;
    }
    if (fd < 0) return -1;

    int buf_len = BPF_BUF_LEN;
    if (ioctl(fd, BIOCSBLEN, &buf_len) < 0) {
        close(fd);
        return -1;
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name) - 1);
    if (ioctl(fd, BIOCSETIF, &ifr) < 0) {
        close(fd);
        return -1;
    }

    int imm = 1;
    ioctl(fd, BIOCIMMEDIATE, &imm);
    ioctl(fd, BIOCPROMISC, NULL);
    int hdrcmplt = 1;
    ioctl(fd, BIOCSHDRCMPLT, &hdrcmplt);
    int seesent = 0;
    ioctl(fd, BIOCSSEESENT, &seesent);

    return fd;
}

static int send_arp_raw(int fd, const uint8_t eth_dst[6], const uint8_t eth_src[6],
                        uint16_t op, const uint8_t sha[6], uint32_t spa,
                        const uint8_t tha[6], uint32_t tpa) {
    uint8_t frame[42];
    struct eth_header *eth = (struct eth_header *)frame;
    struct arp_header *arp = (struct arp_header *)(frame + sizeof(struct eth_header));

    memcpy(eth->dst, eth_dst, 6);
    memcpy(eth->src, eth_src, 6);
    eth->ethertype = htons(0x0806);

    arp->htype = htons(1);
    arp->ptype = htons(0x0800);
    arp->hlen = 6;
    arp->plen = 4;
    arp->op = htons(op);
    memcpy(arp->sha, sha, 6);
    arp->spa = spa;
    memcpy(arp->tha, tha, 6);
    arp->tpa = tpa;

    ssize_t nw = write(fd, frame, sizeof(frame));
    return (nw == (ssize_t)sizeof(frame)) ? 0 : -1;
}

static int resolve_mac_via_arp(const char *ip_str, uint8_t mac[6]) {
    char cmd[128];
    snprintf(cmd, sizeof(cmd), "/sbin/ping -c 1 -W 300 %s >/dev/null 2>&1", ip_str);
    system(cmd);

    snprintf(cmd, sizeof(cmd), "/usr/sbin/arp -n %s 2>/dev/null", ip_str);
    FILE *fp = popen(cmd, "r");
    if (!fp) return -1;

    char line[256];
    int ok = -1;
    while (fgets(line, sizeof(line), fp)) {
        char *at = strstr(line, " at ");
        if (at) {
            at += 4;
            int m[6];
            if (sscanf(at, "%x:%x:%x:%x:%x:%x", &m[0], &m[1], &m[2], &m[3], &m[4], &m[5]) == 6) {
                for (int i = 0; i < 6; i++) mac[i] = (uint8_t)m[i];
                ok = 0;
                break;
            }
        }
    }
    pclose(fp);
    return ok;
}

static void restore_network_state(void) {
    if (g_bpf_fd >= 0 && g_has_ps5_mac && g_has_portal_mac && g_ps5_ip && g_portal_ip) {
        for (int i = 0; i < 5; i++) {
            send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_portal_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
            send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_ps5_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
            usleep(60000);
        }
    }

    if (g_orig_redirect >= 0) {
        int mib[4] = { CTL_NET, PF_INET, IPPROTO_IP, IPCTL_SENDREDIRECTS };
        sysctl(mib, 4, NULL, NULL, &g_orig_redirect, sizeof(g_orig_redirect));
        g_orig_redirect = -1;
    }
    if (g_orig_forwarding >= 0) {
        int mib_fwd[4] = { CTL_NET, PF_INET, IPPROTO_IP, IPCTL_FORWARDING };
        sysctl(mib_fwd, 4, NULL, NULL, &g_orig_forwarding, sizeof(g_orig_forwarding));
        g_orig_forwarding = -1;
    }

    if (g_bpf_fd >= 0) {
        close(g_bpf_fd);
        g_bpf_fd = -1;
    }
    unlink(PID_FILE);
}

static int read_varint(const uint8_t *buf, size_t len, size_t *pos, uint64_t *val) {
    uint64_t n = 0;
    int shift = 0;
    while (*pos < len && shift < 70) {
        uint8_t b = buf[(*pos)++];
        n |= (uint64_t)(b & 0x7F) << shift;
        shift += 7;
        if (!(b & 0x80)) {
            *val = n;
            return 0;
        }
    }
    return -1;
}

static int mutate_launchspec(uint8_t *data, size_t len, const char *profile_num) {
    if (len < 32 || data[0] != 0 || data[13] != 0 || (data[14] != 0 && data[14] != 1)) return 0;
    if (memcmp(data + 5, "\0\0\0\0", 4) != 0 || memcmp(data + 21, "\0\0\0\0\0", 5) != 0 || memcmp(data + 26, "\x08\0\x12", 3) != 0) return 0;
    size_t expected_len = ((size_t)data[15] << 8 | data[16]) + 13;
    if (len != expected_len) return 0;

    size_t pos = 29;
    uint64_t dummy = 0, tag = 0, version = 0;
    if (read_varint(data, len, &pos, &dummy) != 0) return 0;
    if (read_varint(data, len, &pos, &tag) != 0 || read_varint(data, len, &pos, &version) != 0) return 0;
    if (tag != 8 || version != 20) return 0;

    while (pos < len) {
        if (read_varint(data, len, &pos, &tag) != 0) return 0;
        if ((tag & 7) != 2) return 0;
        uint64_t size = 0;
        if (read_varint(data, len, &pos, &size) != 0) return 0;
        if ((tag >> 3) == 3) {
            if (size != 2296) return 0;
            size_t lo = 333;
            size_t a = pos + (lo / 3 * 4);

            if (strcmp(profile_num, "65") == 0) {
                size_t b = pos + 448;
                if (b > len) return 0;
                uint8_t raw[3];
                if (b64_decode_4((char *)(data + a), raw) != 0) return 0;
                raw[1] ^= 0x04;
                b64_encode_4(raw, (char *)(data + a));
                return 1;
            } else if (strcmp(profile_num, "200") == 0) {
                size_t b = pos + 452;
                if (b > len) return 0;
                uint8_t raw[6];
                if (b64_decode_8((char *)(data + a), raw) != 0) return 0;
                uint8_t delta[5] = { 0x00, 0x50, 0x1b, 0x00, 0x05 };
                for (int i = 0; i < 5; i++) raw[1 + i] ^= delta[i];
                b64_encode_8(raw, (char *)(data + a));
                return 1;
            } else {
                size_t b = pos + 452;
                if (b > len) return 0;
                uint8_t raw[6];
                if (b64_decode_8((char *)(data + a), raw) != 0) return 0;
                uint8_t delta[5] = { 0x03, 0x50, 0x1b, 0x00, 0x05 };
                for (int i = 0; i < 5; i++) raw[1 + i] ^= delta[i];
                b64_encode_8(raw, (char *)(data + a));
                return 1;
            }
        }
        pos += size;
    }
    return 0;
}

typedef struct {
    int armed;
    int accepted;
    int streaming;
    int samples;
    int confirmed;
    int bang_printed;
    int early_warned;
    uint64_t bang_version;
    uint64_t last_target_raw;
    uint64_t confirm_threshold;
} ConfirmationState;

static int parse_submessage_varints(const uint8_t *buf, size_t len, uint64_t *f1, uint64_t *f3, uint64_t *f4) {
    size_t pos = 0;
    while (pos < len) {
        uint64_t tag = 0;
        if (read_varint(buf, len, &pos, &tag) != 0) return -1;
        uint64_t field = tag >> 3;
        uint64_t wire = tag & 7;
        if (field == 0) return -1;
        if (wire == 0) {
            uint64_t v = 0;
            if (read_varint(buf, len, &pos, &v) != 0) return -1;
            if (field == 1 && f1) *f1 = v;
            else if (field == 3 && f3) *f3 = v;
            else if (field == 4 && f4) *f4 = v;
        } else if (wire == 2) {
            uint64_t sz = 0;
            if (read_varint(buf, len, &pos, &sz) != 0 || sz > len - pos) return -1;
            pos += (size_t)sz;
        } else if (wire == 1) {
            if (len - pos < 8) return -1;
            pos += 8;
        } else if (wire == 5) {
            if (len - pos < 4) return -1;
            pos += 4;
        } else {
            return -1;
        }
    }
    return 0;
}

static void observe_ps5_message(const uint8_t *data, size_t len, ConfirmationState *st) {
    if (len < 28 || (data[0] & 0x0F) != 0 || data[13] != 0 || data[14] != 1 || data[25] != 0) {
        return;
    }

    const uint8_t *pb = data + 26;
    size_t pb_len = len - 26;
    size_t pos = 0;

    uint64_t kind = 0;
    int has_kind = 0;
    const uint8_t *f3_ptr = NULL;
    size_t f3_len = 0;
    const uint8_t *f17_ptr = NULL;
    size_t f17_len = 0;

    while (pos < pb_len) {
        uint64_t tag = 0;
        if (read_varint(pb, pb_len, &pos, &tag) != 0) return;
        uint64_t field = tag >> 3;
        uint64_t wire = tag & 7;
        if (field == 0) return;
        if (wire == 0) {
            uint64_t v = 0;
            if (read_varint(pb, pb_len, &pos, &v) != 0) return;
            if (field == 1) { kind = v; has_kind = 1; }
        } else if (wire == 2) {
            uint64_t sz = 0;
            if (read_varint(pb, pb_len, &pos, &sz) != 0 || sz > pb_len - pos) return;
            if (field == 3) { f3_ptr = pb + pos; f3_len = (size_t)sz; }
            else if (field == 17) { f17_ptr = pb + pos; f17_len = (size_t)sz; }
            pos += (size_t)sz;
        } else if (wire == 1) {
            if (pb_len - pos < 8) return;
            pos += 8;
        } else if (wire == 5) {
            if (pb_len - pos < 4) return;
            pos += 4;
        } else {
            return;
        }
    }

    if (!has_kind) return;

    if (kind == 8) {
        st->armed = 0;
        st->accepted = 0;
        st->streaming = 0;
        st->samples = 0;
    } else if (kind == 1 && f3_ptr) {
        uint64_t ver = 20, key_acc = 0, ver_acc = 0;
        if (parse_submessage_varints(f3_ptr, f3_len, &ver, &key_acc, &ver_acc) == 0) {
            st->bang_version = ver;
            st->accepted = (st->armed && key_acc == 1 && ver_acc == 1) ? 1 : 0;
            st->streaming = 0;
            st->samples = 0;
            if (st->accepted && !st->bang_printed) {
                st->bang_printed = 1;
                printf("[响应] 📡 收到 PS5 确认响应 (BANG v%llu · Key Accepted)\n", (unsigned long long)ver);
                fflush(stdout);
            }
        }
    } else if (kind == 13 && st->accepted) {
        st->streaming = 1;
    } else if (kind == 16 && f17_ptr) {
        uint64_t raw_target = 0;
        if (parse_submessage_varints(f17_ptr, f17_len, &raw_target, NULL, NULL) == 0) {
            if (raw_target > 0) st->last_target_raw = raw_target;
            if (!st->armed && !st->early_warned) {
                st->early_warned = 1;
                printf("[警告] ⚠️ 检测到未修改的旧串流会话，请先断开 Portal 重试...\n");
                fflush(stdout);
            }
            if (st->accepted && st->streaming) {
                if (raw_target >= st->confirm_threshold) {
                    st->samples++;
                    if (st->samples >= 3) {
                        st->confirmed = 1;
                    }
                } else {
                    st->samples = 0;
                }
            }
        }
    }
}

static int install_sudoers_rule(const char *self_exe) {
    if (geteuid() != 0 || !self_exe || self_exe[0] != '/') return 1;

    char escaped[2048];
    size_t j = 0;
    for (size_t i = 0; self_exe[i] != '\0' && j + 2 < sizeof(escaped); i++) {
        char c = self_exe[i];
        if (c == '\n' || c == '\r') return 1;
        if (c == ' ' || c == '\t' || c == '\\' || c == ',' || c == ':' || c == '=') {
            escaped[j++] = '\\';
        }
        escaped[j++] = c;
    }
    escaped[j] = '\0';

    system("/bin/mkdir -p /etc/sudoers.d >/dev/null 2>&1");
    const char *tmp_path = "/tmp/syspulse_sudoers.tmp";
    unlink(tmp_path);
    int fd = open(tmp_path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return 1;

    FILE *f = fdopen(fd, "w");
    if (!f) {
        close(fd);
        unlink(tmp_path);
        return 1;
    }
    fprintf(f, "ALL ALL=(root) NOPASSWD: %s *\n", escaped);
    fclose(f);

    if (system("/usr/sbin/visudo -cf /tmp/syspulse_sudoers.tmp >/dev/null 2>&1") != 0) {
        unlink(tmp_path);
        return 1;
    }
    chmod(tmp_path, 0440);
    chown(tmp_path, 0, 0);
    if (rename(tmp_path, "/etc/sudoers.d/syspulse_portal") != 0) {
        unlink(tmp_path);
        return 1;
    }
    return 0;
}

int main(int argc, char *argv[]) {
    char ps5_ip_str[64] = "";
    char portal_ip_str[64] = "";
    char bitrate_arg[32] = "100M";
    int restore_only = 0;
    int check_privilege = 0;
    int stop_existing = 0;
    int do_install_sudoers = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--interface") == 0 && i + 1 < argc) {
            strncpy(g_iface, argv[++i], sizeof(g_iface) - 1);
        } else if (strcmp(argv[i], "--ps5") == 0 && i + 1 < argc) {
            strncpy(ps5_ip_str, argv[++i], sizeof(ps5_ip_str) - 1);
        } else if (strcmp(argv[i], "--portal") == 0 && i + 1 < argc) {
            strncpy(portal_ip_str, argv[++i], sizeof(portal_ip_str) - 1);
        } else if (strcmp(argv[i], "--bitrate") == 0 && i + 1 < argc) {
            strncpy(bitrate_arg, argv[++i], sizeof(bitrate_arg) - 1);
        } else if (strcmp(argv[i], "--restore") == 0) {
            restore_only = 1;
        } else if (strcmp(argv[i], "--check-privilege") == 0) {
            check_privilege = 1;
        } else if (strcmp(argv[i], "--stop") == 0) {
            stop_existing = 1;
        } else if (strcmp(argv[i], "--install-sudoers") == 0) {
            do_install_sudoers = 1;
        }
    }

    if (do_install_sudoers) {
        return install_sudoers_rule(argv[0]);
    }

    if (check_privilege) {
        if (geteuid() == 0) {
            printf("OK\n");
            return 0;
        }
        return 1;
    }

    if (stop_existing) {
        if (geteuid() != 0) return 1;
        FILE *f = fopen(PID_FILE, "r");
        if (f) {
            long pid = 0;
            if (fscanf(f, "%ld", &pid) == 1 && pid > 1) {
                kill((pid_t)pid, SIGINT);
                usleep(400000);
                kill((pid_t)pid, SIGTERM);
            }
            fclose(f);
        }
        unlink(PID_FILE);
        return 0;
    }

    if (geteuid() != 0) {
        printf("[错误] ❌ 需要管理员特权 (UID=0) 才能访问 /dev/bpf 与 ARP 注入。\n");
        fflush(stdout);
        return 1;
    }

    const char *profile_num = "100";
    const char *hex_bytes = "03501b0005";
    uint64_t confirm_target = 80000000ULL;
    if (strncmp(bitrate_arg, "65", 2) == 0) {
        profile_num = "65";
        hex_bytes = "04";
        confirm_target = 50000000ULL;
    } else if (strncmp(bitrate_arg, "200", 3) == 0) {
        profile_num = "200";
        hex_bytes = "00501b0005";
        confirm_target = 160000000ULL;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);

    FILE *pf = fopen(PID_FILE, "w");
    if (pf) {
        fprintf(pf, "%d\n", getpid());
        fclose(pf);
    }

    if (get_interface_mac_and_ip(g_iface, g_own_mac, &g_own_ip) != 0) {
        printf("[错误] ❌ 无法获取物理网卡 %s 的本地 MAC / IP 地址！\n", g_iface);
        fflush(stdout);
        unlink(PID_FILE);
        return 1;
    }

    if (ps5_ip_str[0]) {
        g_ps5_ip = inet_addr(ps5_ip_str);
        if (resolve_mac_via_arp(ps5_ip_str, g_ps5_mac) == 0) {
            g_has_ps5_mac = 1;
        }
    }
    if (portal_ip_str[0]) {
        g_portal_ip = inet_addr(portal_ip_str);
        if (resolve_mac_via_arp(portal_ip_str, g_portal_mac) == 0) {
            g_has_portal_mac = 1;
        }
    }

    g_bpf_fd = open_bpf_device(g_iface);
    if (g_bpf_fd < 0) {
        printf("[错误] ❌ 无法打开 /dev/bpf 设备，请确认管理员特权状态。\n");
        fflush(stdout);
        unlink(PID_FILE);
        return 1;
    }

    if (restore_only) {
        restore_network_state();
        printf("[SysPulse] 网络直连路由已复原。\n");
        return 0;
    }

    int mib_redir[4] = { CTL_NET, PF_INET, IPPROTO_IP, IPCTL_SENDREDIRECTS };
    size_t len_redir = sizeof(g_orig_redirect);
    if (sysctl(mib_redir, 4, &g_orig_redirect, &len_redir, NULL, 0) == 0) {
        int zero = 0;
        sysctl(mib_redir, 4, NULL, NULL, &zero, sizeof(zero));
    }
    int mib_fwd[4] = { CTL_NET, PF_INET, IPPROTO_IP, IPCTL_FORWARDING };
    size_t len_fwd = sizeof(g_orig_forwarding);
    if (sysctl(mib_fwd, 4, &g_orig_forwarding, &len_fwd, NULL, 0) == 0) {
        int zero = 0;
        sysctl(mib_fwd, 4, NULL, NULL, &zero, sizeof(zero));
    }

    uint8_t *bpf_buffer = malloc(BPF_BUF_LEN);
    if (!bpf_buffer) {
        restore_network_state();
        printf("[错误] ❌ 内存分配失败。\n");
        return 1;
    }

    double start_ts = monotonic_seconds();
    double ready_at = start_ts + 5.0;
    double end_ts = start_ts + 125.0;
    double next_arp = 0.0;
    int ready_announced = 0;
    int first_mutated_announced = 0;

    uint64_t fwd_in = 0;
    uint64_t fwd_out = 0;
    uint8_t seen_seqs[MAX_SEEN_SEQS][4];
    int unique_seqs = 0;

    ConfirmationState conf;
    memset(&conf, 0, sizeof(conf));
    conf.confirm_threshold = confirm_target;

    while (g_running) {
        double now = monotonic_seconds();
        if (now >= end_ts) break;

        if (now >= next_arp) {
            if (g_has_portal_mac && g_ps5_ip && g_portal_ip) {
                send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_own_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
            }
            if (g_has_ps5_mac && g_ps5_ip && g_portal_ip) {
                send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_own_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
            }
            next_arp = now + 1.0;
        }

        if (!ready_announced && now >= ready_at) {
            ready_announced = 1;
            printf("----------------------------------------------------------------------\n");
            printf("[准备] ⚡️ 网络协商就绪！请在 120 秒内在 PS Portal 上点击连接 PS5...\n");
            fflush(stdout);
        }

        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(g_bpf_fd, &read_fds);
        struct timeval tv = { 0, 50000 }; // 50ms

        int ret = select(g_bpf_fd + 1, &read_fds, NULL, NULL, &tv);
        if (ret <= 0) continue;

        ssize_t nread = read(g_bpf_fd, bpf_buffer, BPF_BUF_LEN);
        if (nread <= 0) continue;

        uint8_t *ptr = bpf_buffer;
        while (ptr < bpf_buffer + nread) {
            struct bpf_hdr *hdr = (struct bpf_hdr *)ptr;
            uint8_t *pkt = ptr + hdr->bh_hdrlen;
            size_t pkt_len = hdr->bh_caplen;
            ptr += BPF_WORDALIGN(hdr->bh_hdrlen + hdr->bh_caplen);

            if (pkt_len < sizeof(struct eth_header)) continue;
            struct eth_header *eth = (struct eth_header *)pkt;

            // 忽略自身发出的帧，避免回环
            if (memcmp(eth->src, g_own_mac, 6) == 0) continue;

            // 动态嗅探 ARP 表以捕获刚唤醒设备的 MAC
            if (ntohs(eth->ethertype) == 0x0806 && pkt_len >= sizeof(struct eth_header) + sizeof(struct arp_header)) {
                struct arp_header *arp = (struct arp_header *)(pkt + sizeof(struct eth_header));
                if (g_ps5_ip && arp->spa == g_ps5_ip && !g_has_ps5_mac) {
                    memcpy(g_ps5_mac, arp->sha, 6);
                    g_has_ps5_mac = 1;
                }
                if (g_portal_ip && arp->spa == g_portal_ip && !g_has_portal_mac) {
                    memcpy(g_portal_mac, arp->sha, 6);
                    g_has_portal_mac = 1;
                }
                continue;
            }

            if (memcmp(eth->dst, g_own_mac, 6) != 0) continue;
            if (ntohs(eth->ethertype) != 0x0800) continue;
            if (pkt_len < sizeof(struct eth_header) + sizeof(struct ip_header)) continue;

            struct ip_header *ip = (struct ip_header *)(pkt + sizeof(struct eth_header));
            if ((ip->ihl_ver >> 4) != 4) continue;
            size_t ip_hl = (ip->ihl_ver & 0x0F) * 4;
            size_t ip_tot = ntohs(ip->tot_len);
            if (ip_hl < 20 || ip_tot < ip_hl || pkt_len < sizeof(struct eth_header) + ip_tot) continue;

            int is_out = (g_portal_ip && g_ps5_ip && ip->saddr == g_portal_ip && ip->daddr == g_ps5_ip);
            int is_in  = (g_portal_ip && g_ps5_ip && ip->saddr == g_ps5_ip && ip->daddr == g_portal_ip);
            if (!is_out && !is_in) continue;

            if (ip->proto == IPPROTO_UDP && (ntohs(ip->frag_off) & 0x3FFF) == 0 && ip_tot >= ip_hl + sizeof(struct udp_header)) {
                struct udp_header *udp = (struct udp_header *)((uint8_t *)ip + ip_hl);
                uint16_t sport = ntohs(udp->source);
                uint16_t dport = ntohs(udp->dest);
                size_t udp_len = ntohs(udp->len);
                if (udp_len >= sizeof(struct udp_header) && ip_hl + udp_len <= ip_tot) {
                    uint8_t *payload = (uint8_t *)udp + sizeof(struct udp_header);
                    size_t payload_len = udp_len - sizeof(struct udp_header);

                    if (is_out && dport == 9296 && payload_len >= 32) {
                        if (mutate_launchspec(payload, payload_len, profile_num)) {
                            udp->check = 0;
                            udp->check = htons(udp_checksum(ip, udp, udp_len));
                            ip->check = 0;
                            ip->check = htons(calc_checksum(ip, ip_hl));

                            int already_seen = 0;
                            for (int s = 0; s < unique_seqs; s++) {
                                if (memcmp(seen_seqs[s], payload + 17, 4) == 0) {
                                    already_seen = 1;
                                    break;
                                }
                            }
                            if (!already_seen) {
                                if (unique_seqs < MAX_SEEN_SEQS) {
                                    memcpy(seen_seqs[unique_seqs], payload + 17, 4);
                                }
                                unique_seqs++;
                                conf.armed = 1;
                                conf.accepted = 0;
                                conf.streaming = 0;
                                conf.samples = 0;
                            }
                            if (!first_mutated_announced) {
                                first_mutated_announced = 1;
                                printf("[注入] 🎯 截获并修改 LaunchSpec 握手参数为 %s Mbps！\n", profile_num);
                                fflush(stdout);
                            }
                        }
                    } else if (is_in && sport == 9296) {
                        observe_ps5_message(payload, payload_len, &conf);
                    }
                }
            }

            if (is_out && g_has_ps5_mac) {
                memcpy(eth->dst, g_ps5_mac, 6);
                memcpy(eth->src, g_own_mac, 6);
                if (write(g_bpf_fd, pkt, sizeof(struct eth_header) + ip_tot) > 0) {
                    fwd_out++;
                }
            } else if (is_in && g_has_portal_mac) {
                memcpy(eth->dst, g_portal_mac, 6);
                memcpy(eth->src, g_own_mac, 6);
                if (write(g_bpf_fd, pkt, sizeof(struct eth_header) + ip_tot) > 0) {
                    fwd_in++;
                }
            }

            if (conf.confirmed) break;
        }

        if (conf.confirmed) break;
    }

    free(bpf_buffer);
    restore_network_state();

    double target_mbps = conf.last_target_raw > 0 ? ((double)conf.last_target_raw / 1000000.0) : 0.0;
    const char *status_line;
    char status_buf[256];
    char inject_buf[256];
    const char *quality_line;
    int exit_code = 0;

    if (unique_seqs > 0 && conf.confirmed) {
        double shown_mbps = target_mbps > 0.0 ? target_mbps : (atof(profile_num) * 0.97);
        printf("[成功] 🎉 PS5 已确认并接受高码率协商！\n");
        printf("[路由] 🔄 局域网直连路由已平滑复原，进入纯 Wi-Fi 串流状态。\n");
        snprintf(status_buf, sizeof(status_buf), "✅ %s Mbps Profile (PS5 锁定上限: %.1f Mbps)", profile_num, shown_mbps);
        snprintf(inject_buf, sizeof(inject_buf), "成功修改 %d 个序列启动包 (Offset %d · Hex %s)", unique_seqs, OFFSET, hex_bytes);
        status_line = status_buf;
        quality_line = "连续捕获 3 次高码率质量回报 (Quality Confirmed)";
        exit_code = 0;
    } else if (unique_seqs > 0) {
        printf("[警告] ⚠️ 已发送码率注入，但未收到 PS5 连续 3 次高码率质量确认。\n");
        if (target_mbps > 0.0) {
            snprintf(status_buf, sizeof(status_buf), "⚠️ 未确认目标码率 (注入已发送，PS5 回报: %.1f Mbps)", target_mbps);
        } else {
            snprintf(status_buf, sizeof(status_buf), "⚠️ 未确认目标码率 (未收到 PS5 质量确认)");
        }
        snprintf(inject_buf, sizeof(inject_buf), "已修改 %d 个序列启动包 (Offset %d · Hex %s)", unique_seqs, OFFSET, hex_bytes);
        status_line = status_buf;
        quality_line = "未满足连续 3 次高码率回报阈值";
        exit_code = 1;
    } else {
        printf("[失败] ⚠️ 未检测到 PS Portal 握手请求（可能处于休眠或未点击连接 PS5），本次未修改码率。\n");
        status_line = "❌ 未生效 (未捕获到握手启动包，请唤醒 Portal 并点击连接 PS5)";
        snprintf(inject_buf, sizeof(inject_buf), "未检测到 LaunchSpec 启动包 (修改 0 个)");
        quality_line = "未收到 PS5 质量回报";
        exit_code = 1;
    }

    printf("----------------------------------------------------------------------\n");
    printf("📊 【PS Portal 串流画质增强报告】\n");
    printf("├─ 协商状态: %s\n", status_line);
    printf("├─ 流量统计: 下行转发 %llu 包 | 上行转发 %llu 包\n", (unsigned long long)fwd_in, (unsigned long long)fwd_out);
    printf("├─ 启动注入: %s\n", inject_buf);
    printf("├─ 链路质量: %s\n", quality_line);
    printf("└─ 引擎模式: SysPulse Native C BPF Engine (无需 Python / Xcode CLT)\n");
    printf("----------------------------------------------------------------------\n");
    if (exit_code != 0) {
        printf("%s\n", unique_seqs > 0 ? "UNCONFIRMED: mutation sent without 3 high-bitrate confirmations." : "NOT APPLIED: no matching fresh handshake.");
    }
    fflush(stdout);
    return exit_code;
}
