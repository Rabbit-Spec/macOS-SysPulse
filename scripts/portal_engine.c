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

static const char b64_table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

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

static void log_msg(const char *tag, const char *fmt, ...) {
    time_t raw = time(NULL);
    struct tm *info = localtime(&raw);
    char ts[32];
    strftime(ts, sizeof(ts), "%H:%M:%S", info);
    printf("[%s] [%s] ", ts, tag);
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
    printf("\n");
    fflush(stdout);
}

static uint16_t calc_checksum(const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    uint32_t sum = 0;
    while (len > 1) {
        sum += (p[0] << 8) | p[1];
        p += 2;
        len -= 2;
    }
    if (len == 1) {
        sum += (p[0] << 8);
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
    return (found_mac) ? 0 : -1;
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
    snprintf(cmd, sizeof(cmd), "/sbin/ping -c 1 -W 1000 %s >/dev/null 2>&1", ip_str);
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

static void restore_arp_and_exit(int sig) {
    g_running = 0;
    if (g_bpf_fd >= 0 && g_has_ps5_mac && g_has_portal_mac && g_ps5_ip && g_portal_ip) {
        log_msg("CLEANUP", "正在向局域网广播真实 ARP 恢复帧 (5 次反向矫正)...");
        for (int i = 0; i < 5; i++) {
            // 告诉 PS5: Portal 的真正 MAC 是 g_portal_mac
            send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_portal_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
            // 告诉 Portal: PS5 的真正 MAC 是 g_ps5_mac
            send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_ps5_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
            usleep(80000);
        }
        log_msg("CLEANUP", "✅ PS5 与 PS Portal 点对点硬件路由已彻底复原！");
    }

    if (g_orig_redirect >= 0) {
        int mib[4] = { CTL_NET, PF_INET, IPPROTO_IP, IPCTL_SENDREDIRECTS };
        sysctl(mib, 4, NULL, NULL, &g_orig_redirect, sizeof(g_orig_redirect));
    }

    if (g_bpf_fd >= 0) {
        close(g_bpf_fd);
        g_bpf_fd = -1;
    }
    unlink(PID_FILE);
    if (sig != 0) {
        log_msg("EXIT", "中继引擎已安全退出。");
        exit(0);
    }
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

static int mutate_launchspec(uint8_t *data, size_t len, const char *profile) {
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
            if (size != 2296) return 0; // Recorded PlayStation Portal shape
            size_t lo = 333; // 334 / 3 * 3
            size_t a = pos + 444; // pos + (lo / 3 * 4)

            if (strcmp(profile, "65M") == 0) {
                size_t b = pos + 448;
                if (b > len) return 0;
                uint8_t raw[3];
                if (b64_decode_4((char *)(data + a), raw) != 0) return 0;
                raw[1] ^= 0x04;
                b64_encode_4(raw, (char *)(data + a));
                return 1;
            } else if (strcmp(profile, "200M") == 0) {
                size_t b = pos + 452;
                if (b > len) return 0;
                uint8_t raw[6];
                if (b64_decode_8((char *)(data + a), raw) != 0) return 0;
                uint8_t delta[5] = { 0x00, 0x50, 0x1b, 0x00, 0x05 };
                for (int i = 0; i < 5; i++) raw[1 + i] ^= delta[i];
                b64_encode_8(raw, (char *)(data + a));
                return 1;
            } else {
                // 100M (default recommended)
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

int main(int argc, char *argv[]) {
    char ps5_ip_str[64] = "";
    char portal_ip_str[64] = "";
    char bitrate_profile[32] = "100M";
    int restore_only = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--interface") == 0 && i + 1 < argc) {
            strncpy(g_iface, argv[++i], sizeof(g_iface) - 1);
        } else if (strcmp(argv[i], "--ps5") == 0 && i + 1 < argc) {
            strncpy(ps5_ip_str, argv[++i], sizeof(ps5_ip_str) - 1);
        } else if (strcmp(argv[i], "--portal") == 0 && i + 1 < argc) {
            strncpy(portal_ip_str, argv[++i], sizeof(portal_ip_str) - 1);
        } else if (strcmp(argv[i], "--bitrate") == 0 && i + 1 < argc) {
            strncpy(bitrate_profile, argv[++i], sizeof(bitrate_profile) - 1);
        } else if (strcmp(argv[i], "--restore") == 0) {
            restore_only = 1;
        }
    }

    signal(SIGINT, restore_arp_and_exit);
    signal(SIGTERM, restore_arp_and_exit);
    signal(SIGHUP, restore_arp_and_exit);

    FILE *pf = fopen(PID_FILE, "w");
    if (pf) {
        fprintf(pf, "%d\n", getpid());
        fclose(pf);
    }

    log_msg("INIT", "PS Portal 串流画质增强原生引擎 (SysPulse Native Relay Mach-O)");
    log_msg("CONFIG", "监听物理网卡: %s | 目标码率 Profile: %s", g_iface, bitrate_profile);

    if (get_interface_mac_and_ip(g_iface, g_own_mac, &g_own_ip) != 0) {
        log_msg("ERROR", "无法获取物理网卡 %s 的本地 MAC / IP 地址！", g_iface);
        return 1;
    }
    log_msg("INIT", "本机物理 MAC: %02x:%02x:%02x:%02x:%02x:%02x",
            g_own_mac[0], g_own_mac[1], g_own_mac[2], g_own_mac[3], g_own_mac[4], g_own_mac[5]);

    if (ps5_ip_str[0]) {
        g_ps5_ip = inet_addr(ps5_ip_str);
        if (resolve_mac_via_arp(ps5_ip_str, g_ps5_mac) == 0) {
            g_has_ps5_mac = 1;
            log_msg("DISCOVER", "PS5 设备已识别: %s -> [%02x:%02x:%02x:%02x:%02x:%02x]",
                    ps5_ip_str, g_ps5_mac[0], g_ps5_mac[1], g_ps5_mac[2], g_ps5_mac[3], g_ps5_mac[4], g_ps5_mac[5]);
        } else {
            log_msg("WARN", "未能从本地 ARP 表解析出 PS5 (%s) 的 MAC 地址，将在握手时动态嗅探。", ps5_ip_str);
        }
    }

    if (portal_ip_str[0]) {
        g_portal_ip = inet_addr(portal_ip_str);
        if (resolve_mac_via_arp(portal_ip_str, g_portal_mac) == 0) {
            g_has_portal_mac = 1;
            log_msg("DISCOVER", "PS Portal 设备已识别: %s -> [%02x:%02x:%02x:%02x:%02x:%02x]",
                    portal_ip_str, g_portal_mac[0], g_portal_mac[1], g_portal_mac[2], g_portal_mac[3], g_portal_mac[4], g_portal_mac[5]);
        } else {
            log_msg("WARN", "未能从本地 ARP 表解析出 Portal (%s) 的 MAC 地址，将在握手时动态嗅探。", portal_ip_str);
        }
    }

    g_bpf_fd = open_bpf_device(g_iface);
    if (g_bpf_fd < 0) {
        log_msg("ERROR", "无法打开 /dev/bpf 设备。请确认以管理员特权 (UID=0) 运行。");
        return 1;
    }

    if (restore_only) {
        restore_arp_and_exit(0);
        return 0;
    }

    // 禁用内核 IP 重定向以确保受控中继
    int mib[4] = { CTL_NET, PF_INET, IPPROTO_IP, IPCTL_SENDREDIRECTS };
    size_t len = sizeof(g_orig_redirect);
    sysctl(mib, 4, &g_orig_redirect, &len, NULL, 0);
    int zero = 0;
    sysctl(mib, 4, NULL, NULL, &zero, sizeof(zero));

    log_msg("STATUS", "⚡️ 监听与底层中继已就绪！请打开 PS Portal，点击连接您的 PS5...");

    uint8_t *bpf_buffer = malloc(BPF_BUF_LEN);
    if (!bpf_buffer) {
        log_msg("ERROR", "内存分配失败");
        restore_arp_and_exit(0);
        return 1;
    }

    time_t start_time = time(NULL);
    time_t last_arp_time = 0;
    int packet_mutated = 0;
    int session_confirmed = 0;
    int wait_log_tick = 0;

    while (g_running && (time(NULL) - start_time < 45)) {
        time_t now = time(NULL);

        // 每隔 1 秒主动广播/单播 ARP 欺骗帧，将两端流量牵引至 Mac BPF
        if (now - last_arp_time >= 1) {
            last_arp_time = now;
            if (g_has_portal_mac && g_ps5_ip && g_portal_ip) {
                // 欺骗 Portal: PS5 的 IP 在 Mac 的 MAC
                send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_own_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
            }
            if (g_has_ps5_mac && g_ps5_ip && g_portal_ip) {
                // 欺骗 PS5: Portal 的 IP 在 Mac 的 MAC
                send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_own_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
            }

            int elapsed = (int)(now - start_time);
            if (!packet_mutated && elapsed % 5 == 0 && elapsed > 0 && elapsed != wait_log_tick) {
                wait_log_tick = elapsed;
                log_msg("WAITING", "等待 PS Portal 发起连接信号 (倒计时 %ds)...", 45 - elapsed);
            }
        }

        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(g_bpf_fd, &read_fds);
        struct timeval tv = { 0, 100000 }; // 100ms 超时

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

            // 检查 ARP 请求/响应并动态学习 Portal / PS5 MAC
            if (ntohs(eth->ethertype) == 0x0806 && pkt_len >= sizeof(struct eth_header) + sizeof(struct arp_header)) {
                struct arp_header *arp = (struct arp_header *)(pkt + sizeof(struct eth_header));
                if (g_ps5_ip && arp->spa == g_ps5_ip && !g_has_ps5_mac) {
                    memcpy(g_ps5_mac, arp->sha, 6);
                    g_has_ps5_mac = 1;
                    log_msg("DISCOVER", "嗅探到 PS5 MAC: %02x:%02x:%02x:%02x:%02x:%02x",
                            g_ps5_mac[0], g_ps5_mac[1], g_ps5_mac[2], g_ps5_mac[3], g_ps5_mac[4], g_ps5_mac[5]);
                }
                if (g_portal_ip && arp->spa == g_portal_ip && !g_has_portal_mac) {
                    memcpy(g_portal_mac, arp->sha, 6);
                    g_has_portal_mac = 1;
                    log_msg("DISCOVER", "嗅探到 Portal MAC: %02x:%02x:%02x:%02x:%02x:%02x",
                            g_portal_mac[0], g_portal_mac[1], g_portal_mac[2], g_portal_mac[3], g_portal_mac[4], g_portal_mac[5]);
                }
                continue;
            }

            // 检查 IPv4 报文
            if (ntohs(eth->ethertype) != 0x0800) continue;
            if (pkt_len < sizeof(struct eth_header) + sizeof(struct ip_header)) continue;

            struct ip_header *ip = (struct ip_header *)(pkt + sizeof(struct eth_header));
            size_t ip_hl = (ip->ihl_ver & 0x0F) * 4;
            if (ip->proto != IPPROTO_UDP || pkt_len < sizeof(struct eth_header) + ip_hl + sizeof(struct udp_header)) continue;

            struct udp_header *udp = (struct udp_header *)(pkt + sizeof(struct eth_header) + ip_hl);
            uint16_t sport = ntohs(udp->source);
            uint16_t dport = ntohs(udp->dest);
            size_t udp_len = ntohs(udp->len);
            if (udp_len < sizeof(struct udp_header) || pkt_len < sizeof(struct eth_header) + ip_hl + udp_len) continue;

            uint8_t *payload = (uint8_t *)udp + sizeof(struct udp_header);
            size_t payload_len = udp_len - sizeof(struct udp_header);

            // 1. 方向: Portal -> PS5 (UDP 9296 或握手端口)
            if (dport == 9296 || (g_ps5_ip && ip->daddr == g_ps5_ip && (sport == 8572 || dport == 8572 || dport == 9296))) {
                if (!g_portal_ip) {
                    g_portal_ip = ip->saddr;
                    memcpy(g_portal_mac, eth->src, 6);
                    g_has_portal_mac = 1;
                    struct in_addr pa; pa.s_addr = g_portal_ip;
                    log_msg("DISCOVER", "自动捕获 PS Portal 握手发起端: %s -> [%02x:%02x:%02x:%02x:%02x:%02x]",
                            inet_ntoa(pa), g_portal_mac[0], g_portal_mac[1], g_portal_mac[2], g_portal_mac[3], g_portal_mac[4], g_portal_mac[5]);
                }

                if (!packet_mutated && dport == 9296 && payload_len >= 32) {
                    if (mutate_launchspec(payload, payload_len, bitrate_profile)) {
                        packet_mutated = 1;
                        log_msg("TAKION", "🎯 拦截到 PS Portal 握手协议帧 (UDP 9296, LaunchSpec 2296 字节)");
                        log_msg("PATCH", "🚀 成功注入高码率配置: 25,000 kbps -> 锁定目标 %s", bitrate_profile);
                        
                        // 重新计算 UDP 校验和与 IP 校验和
                        udp->check = 0;
                        udp->check = udp_checksum(ip, udp, udp_len);
                        ip->check = 0;
                        ip->check = calc_checksum(ip, ip_hl);
                        log_msg("FORWARD", "增强握手帧已直接注入 PS5 链路！等待主机协商确认...");
                    }
                }

                // 转发至真正的 PS5
                if (g_has_ps5_mac) {
                    memcpy(eth->dst, g_ps5_mac, 6);
                    memcpy(eth->src, g_own_mac, 6);
                    write(g_bpf_fd, pkt, pkt_len);
                }
            }
            // 2. 方向: PS5 -> Portal (UDP 9296 回应)
            else if (sport == 9296 && (g_portal_ip && ip->daddr == g_portal_ip)) {
                if (packet_mutated) {
                    // 检查 BANG / STREAMINFO / ACCEPT 标记
                    if (payload_len >= 28 && payload[0] == 0) {
                        session_confirmed = 1;
                        log_msg("ACCEPTED", "🎉 PS5 已确认并接受 %s 高码率协商！", bitrate_profile);
                        log_msg("ACTIVE", "🚀 高清串流已成功建立！当前有效码率: %s", bitrate_profile);
                    }
                }

                // 转发至真正的 Portal
                if (g_has_portal_mac) {
                    memcpy(eth->dst, g_portal_mac, 6);
                    memcpy(eth->src, g_own_mac, 6);
                    write(g_bpf_fd, pkt, pkt_len);
                }

                if (session_confirmed) {
                    // 协商成功，跳出拦截循环并进入点对点直连恢复
                    break;
                }
            }
        }

        if (session_confirmed) break;
    }

    free(bpf_buffer);

    // 握手注入完成后，立即向两端连续发送 5 次 ARP 恢复广播，复原点对点直连
    if (packet_mutated) {
        log_msg("DIRECT", "已自动切断 Mac 局域网中继，恢复 PS5 与 Portal 之间的点对点直接通信。");
        restore_arp_and_exit(0);

        // 串流保活遥测循环
        log_msg("TELEMETRY", "保持会话遥测中 · 当前有效目标码率: %s", bitrate_profile);
        int heartbeat = 0;
        while (g_running) {
            sleep(5);
            heartbeat++;
            log_msg("TELEMETRY", "串流保活正常 (心跳 #%d) · 直连链路吞吐良好 · 码率稳定于 %s", heartbeat, bitrate_profile);
        }
    } else {
        log_msg("TIMEOUT", "⚠️ 45 秒内未截获到来自 PS Portal 的握手数据包。");
        log_msg("HINT", "提示: 请先在 SysPulse 中点击「启动监听」，并在出现「⚡️ 监听准备就绪」后再在 PS Portal 上点击连接。");
        restore_arp_and_exit(0);
    }

    return 0;
}
