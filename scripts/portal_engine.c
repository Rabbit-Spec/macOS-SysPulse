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
#include <sys/wait.h>
#include <net/bpf.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>

#define SYS_SUPPORT_DIR "/Library/Application Support/SysPulse"
#define PRIVILEGED_ENGINE_PREFIX "/Library/Application Support/SysPulse/"
#define PID_FILE "/Library/Application Support/SysPulse/syspulse_psportal.pid"
#define STATE_FILE "/Library/Application Support/SysPulse/syspulse_psportal_state.txt"
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
static int g_mode_oneway = 1;
static int g_spoof_active = 0;

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

static void configure_bpf_filter(int fd, uint32_t ps5_ip_net, uint32_t portal_ip_net) {
    if (ps5_ip_net == 0 || portal_ip_net == 0) return;

    uint32_t ps5_h = ntohl(ps5_ip_net);
    uint32_t portal_h = ntohl(portal_ip_net);

    /* 内核级 BPF 过滤：仅放行 ARP (0x0806) 与 PS5 <-> Portal 之间的全端口 IPv4 (0x0800) 帧 */
    struct bpf_insn insns[] = {
        /* 0: 读取 EtherType (offset 12, 2 bytes) */
        BPF_STMT(BPF_LD + BPF_H + BPF_ABS, 12),
        /* 1: ARP (0x0806) -> ACCEPT (idx 10) */
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, 0x0806, 8, 0),
        /* 2: IPv4 (0x0800) -> next (idx 3), else DROP (idx 11) */
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, 0x0800, 0, 8),
        /* 3: 读取 IPv4 源地址 (offset 26, 4 bytes) */
        BPF_STMT(BPF_LD + BPF_W + BPF_ABS, 26),
        /* 4: src == PS5 -> check dst==Portal (idx 6) */
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ps5_h, 1, 0),
        /* 5: src == Portal -> check dst==PS5 (idx 8), else DROP (idx 11) */
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, portal_h, 2, 5),
        /* 6: 读取 IPv4 目的地址 (offset 30, 4 bytes) */
        BPF_STMT(BPF_LD + BPF_W + BPF_ABS, 30),
        /* 7: dst == Portal -> ACCEPT (idx 10), else DROP (idx 11) */
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, portal_h, 2, 3),
        /* 8: 读取 IPv4 目的地址 (offset 30, 4 bytes) */
        BPF_STMT(BPF_LD + BPF_W + BPF_ABS, 30),
        /* 9: dst == PS5 -> ACCEPT (idx 10), else DROP (idx 11) */
        BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ps5_h, 0, 1),
        /* 10: ACCEPT */
        BPF_STMT(BPF_RET + BPF_K, (u_int)-1),
        /* 11: DROP */
        BPF_STMT(BPF_RET + BPF_K, 0)
    };

    struct bpf_program prog;
    prog.bf_len = (u_int)(sizeof(insns) / sizeof(insns[0]));
    prog.bf_insns = insns;
    ioctl(fd, BIOCSETF, &prog);
}

static int open_bpf_device(const char *ifname, uint32_t ps5_ip_net, uint32_t portal_ip_net) {
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
    int hdrcmplt = 1;
    ioctl(fd, BIOCSHDRCMPLT, &hdrcmplt);
    int seesent = 0;
    ioctl(fd, BIOCSSEESENT, &seesent);
    configure_bpf_filter(fd, ps5_ip_net, portal_ip_net);

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

static void format_mac_str(const uint8_t mac[6], char out[18]) {
    snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

static void format_ip_str(uint32_t ip_net, char out[16]) {
    struct in_addr addr;
    addr.s_addr = ip_net;
    const char *s = inet_ntoa(addr);
    snprintf(out, 16, "%s", s ? s : "0.0.0.0");
}

static int is_valid_unicast_ipv4(const char *s, uint32_t *out_net) {
    if (!s || !s[0]) return 0;
    struct in_addr addr;
    if (inet_pton(AF_INET, s, &addr) != 1) return 0;
    uint32_t h = ntohl(addr.s_addr);
    uint32_t first = (h >> 24) & 0xFFU;
    if (first == 0 || first == 127 || first >= 224) return 0;
    if ((h & 0xFFFF0000U) == 0xA9FE0000U) return 0; // 169.254.x.x
    if (out_net) *out_net = addr.s_addr;
    return 1;
}

static int is_safe_interface_name(const char *s) {
    if (!s || !s[0] || strlen(s) >= 32) return 0;
    for (size_t i = 0; s[i]; i++) {
        unsigned char c = (unsigned char)s[i];
        int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                 (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-';
        if (!ok) return 0;
    }
    return 1;
}

static void ensure_sys_support_dir(void) {
    mkdir(SYS_SUPPORT_DIR, 0755);
    chown(SYS_SUPPORT_DIR, 0, 0);
    chmod(SYS_SUPPORT_DIR, 0755);
}

static FILE *fopen_write_nofollow(const char *path, mode_t mode) {
    ensure_sys_support_dir();
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode);
    if (fd < 0) return NULL;
    FILE *f = fdopen(fd, "w");
    if (!f) {
        close(fd);
        return NULL;
    }
    return f;
}

static int run_argv_quiet(const char *path, char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > 2) close(devnull);
        }
        execv(path, argv);
        _exit(127);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static int run_argv_capture(const char *path, char *const argv[], char *out, size_t out_cap) {
    if (!out || out_cap == 0) return -1;
    out[0] = '\0';
    int pipefd[2];
    if (pipe(pipefd) != 0) return -1;

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }
    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > 2) close(devnull);
        }
        close(pipefd[1]);
        execv(path, argv);
        _exit(127);
    }
    close(pipefd[1]);
    size_t total = 0;
    while (total + 1 < out_cap) {
        ssize_t n = read(pipefd[0], out + total, out_cap - 1 - total);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (n == 0) break;
        total += (size_t)n;
    }
    out[total] = '\0';
    close(pipefd[0]);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static void ping_hosts_parallel(const char *ip1, const char *ip2) {
    const char *ips[2] = { ip1, ip2 };
    pid_t pids[2] = { -1, -1 };
    for (int i = 0; i < 2; i++) {
        if (!ips[i] || !ips[i][0]) continue;
        pid_t pid = fork();
        if (pid == 0) {
            int devnull = open("/dev/null", O_RDWR);
            if (devnull >= 0) {
                dup2(devnull, STDIN_FILENO);
                dup2(devnull, STDOUT_FILENO);
                dup2(devnull, STDERR_FILENO);
                if (devnull > 2) close(devnull);
            }
            char *const argv[] = { "/sbin/ping", "-c", "1", "-W", "200", (char *)ips[i], NULL };
            execv("/sbin/ping", argv);
            _exit(127);
        }
        pids[i] = pid;
    }
    for (int i = 0; i < 2; i++) {
        if (pids[i] > 0) {
            int status = 0;
            while (waitpid(pids[i], &status, 0) < 0 && errno == EINTR) {}
        }
    }
}

static void check_route_for_ip(const char *label, const char *ip_str, const char *expected_iface) {
    if (!ip_str || !ip_str[0]) return;
    char out[4096];
    char *const argv[] = { "/sbin/route", "-n", "get", (char *)ip_str, NULL };
    if (run_argv_capture("/sbin/route", argv, out, sizeof(out)) != 0 || !out[0]) return;

    char route_iface[64] = "";
    int has_gateway_flag = 0;
    char *saveptr = NULL;
    for (char *line = strtok_r(out, "\n", &saveptr); line != NULL; line = strtok_r(NULL, "\n", &saveptr)) {
        char *p = strstr(line, "interface:");
        if (p) {
            p += 10;
            while (*p == ' ' || *p == '\t') p++;
            sscanf(p, "%63s", route_iface);
        }
        if (strstr(line, "flags:") && strstr(line, "GATEWAY")) {
            has_gateway_flag = 1;
        }
    }

    if (has_gateway_flag || (route_iface[0] && strcmp(route_iface, expected_iface) != 0)) {
        printf("[诊断] ⚠️ %s (%s) 系统路由为 %s%s，与当前选择网卡 %s 不一致！\n",
               label,
               ip_str,
               route_iface[0] ? route_iface : "未知接口",
               has_gateway_flag ? " (经过网关/非直连子网)" : "",
               expected_iface);
        fflush(stdout);
    }
}

static int resolve_mac_via_arp(const char *ip_str, const char *expected_iface, uint8_t mac[6], int send_ping) {
    if (!ip_str || !ip_str[0]) return -1;
    if (send_ping) {
        char *const ping_argv[] = { "/sbin/ping", "-c", "1", "-W", "200", (char *)ip_str, NULL };
        run_argv_quiet("/sbin/ping", ping_argv);
    }

    char out[2048];
    char *const arp_argv[] = { "/usr/sbin/arp", "-n", (char *)ip_str, NULL };
    run_argv_capture("/usr/sbin/arp", arp_argv, out, sizeof(out));
    if (!out[0]) return -1;

    char on_iface_needle[48];
    snprintf(on_iface_needle, sizeof(on_iface_needle), " on %s", expected_iface);
    size_t needle_len = strlen(on_iface_needle);

    int ok = -1;
    char *saveptr = NULL;
    for (char *line = strtok_r(out, "\n", &saveptr); line != NULL; line = strtok_r(NULL, "\n", &saveptr)) {
        char *on_pos = strstr(line, on_iface_needle);
        if (on_pos) {
            char next_ch = on_pos[needle_len];
            if (next_ch != '\0' && next_ch != ' ' && next_ch != '\t' && next_ch != '\n' && next_ch != '\r') {
                continue;
            }
        } else if (strstr(line, " on ") != NULL) {
            continue;
        }

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
    return ok;
}

static int validate_distinct_macs(void) {
    if (!g_has_ps5_mac || !g_has_portal_mac) return 0;
    if (memcmp(g_own_mac, g_ps5_mac, 6) == 0 ||
        memcmp(g_own_mac, g_portal_mac, 6) == 0 ||
        memcmp(g_ps5_mac, g_portal_mac, 6) == 0) {
        return -1;
    }
    return 0;
}

static void save_restore_state(void) {
    FILE *f = fopen_write_nofollow(STATE_FILE, 0600);
    if (!f) return;
    fprintf(f, "%s %d %02x:%02x:%02x:%02x:%02x:%02x %u %02x:%02x:%02x:%02x:%02x:%02x %u %02x:%02x:%02x:%02x:%02x:%02x %d %d\n",
            g_iface, g_mode_oneway,
            g_own_mac[0], g_own_mac[1], g_own_mac[2], g_own_mac[3], g_own_mac[4], g_own_mac[5],
            (unsigned)ntohl(g_ps5_ip),
            g_ps5_mac[0], g_ps5_mac[1], g_ps5_mac[2], g_ps5_mac[3], g_ps5_mac[4], g_ps5_mac[5],
            (unsigned)ntohl(g_portal_ip),
            g_portal_mac[0], g_portal_mac[1], g_portal_mac[2], g_portal_mac[3], g_portal_mac[4], g_portal_mac[5],
            g_orig_redirect, g_orig_forwarding);
    fclose(f);
}

static int load_restore_state(void) {
    int fd = open(STATE_FILE, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != 0) {
        close(fd);
        return -1;
    }
    FILE *f = fdopen(fd, "r");
    if (!f) {
        close(fd);
        return -1;
    }
    char iface_buf[32] = "";
    int oneway = 1, redir = -1, fwd = -1;
    unsigned int own_m[6], ps5_m[6], port_m[6];
    unsigned int ps5_ip_h = 0, port_ip_h = 0;
    int n = fscanf(f, "%31s %d %x:%x:%x:%x:%x:%x %u %x:%x:%x:%x:%x:%x %u %x:%x:%x:%x:%x:%x %d %d",
                   iface_buf, &oneway,
                   &own_m[0], &own_m[1], &own_m[2], &own_m[3], &own_m[4], &own_m[5],
                   &ps5_ip_h,
                   &ps5_m[0], &ps5_m[1], &ps5_m[2], &ps5_m[3], &ps5_m[4], &ps5_m[5],
                   &port_ip_h,
                   &port_m[0], &port_m[1], &port_m[2], &port_m[3], &port_m[4], &port_m[5],
                   &redir, &fwd);
    fclose(f);
    if (n != 24) return -1;
    if (!is_safe_interface_name(iface_buf) || if_nametoindex(iface_buf) == 0) return -1;

    strncpy(g_iface, iface_buf, sizeof(g_iface) - 1);
    g_iface[sizeof(g_iface) - 1] = '\0';
    g_mode_oneway = oneway;
    for (int i = 0; i < 6; i++) {
        g_own_mac[i] = (uint8_t)own_m[i];
        g_ps5_mac[i] = (uint8_t)ps5_m[i];
        g_portal_mac[i] = (uint8_t)port_m[i];
    }
    g_ps5_ip = htonl((uint32_t)ps5_ip_h);
    g_portal_ip = htonl((uint32_t)port_ip_h);
    g_has_ps5_mac = 1;
    g_has_portal_mac = 1;
    g_orig_redirect = redir;
    g_orig_forwarding = fwd;
    return 0;
}

static void restore_network_state(int force_arp) {
    if (g_bpf_fd >= 0 && g_has_ps5_mac && g_has_portal_mac && g_ps5_ip && g_portal_ip && (g_spoof_active || force_arp)) {
        for (int i = 0; i < 5; i++) {
            send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_ps5_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
            if (!g_mode_oneway || force_arp) {
                send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_portal_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
            }
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
    unlink(STATE_FILE);
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

static int mutate_launchspec(uint8_t *data, size_t len, const char *profile_num, char *diag_buf, size_t diag_cap) {
    if (diag_buf && diag_cap > 0) diag_buf[0] = '\0';

    if (len < 32 || data[0] != 0 || data[13] != 0 || (data[14] != 0 && data[14] != 1)) {
        if (diag_buf && len >= 32) {
            snprintf(diag_buf, diag_cap, "hdr_flags len=%zu d0=0x%02x d13=0x%02x d14=0x%02x",
                     len, data[0], data[13], data[14]);
        }
        return 0;
    }
    if (memcmp(data + 5, "\0\0\0\0", 4) != 0 || memcmp(data + 21, "\0\0\0\0\0", 5) != 0 || memcmp(data + 26, "\x08\0\x12", 3) != 0) {
        if (diag_buf) {
            snprintf(diag_buf, diag_cap, "hdr_magic len=%zu d26=%02x%02x%02x d5=%02x%02x%02x%02x",
                     len, data[26], data[27], data[28], data[5], data[6], data[7], data[8]);
        }
        return 0;
    }
    size_t expected_len = ((size_t)data[15] << 8 | data[16]) + 13;
    if (len != expected_len) {
        if (diag_buf) {
            snprintf(diag_buf, diag_cap, "len_mismatch len=%zu expected=%zu d14=%u", len, expected_len, data[14]);
        }
        return 0;
    }

    size_t pos = 29;
    uint64_t dummy = 0, tag = 0, version = 0;
    if (read_varint(data, len, &pos, &dummy) != 0) {
        if (diag_buf) snprintf(diag_buf, diag_cap, "varint_dummy len=%zu", len);
        return 0;
    }
    if (read_varint(data, len, &pos, &tag) != 0 || read_varint(data, len, &pos, &version) != 0) {
        if (diag_buf) snprintf(diag_buf, diag_cap, "varint_ver len=%zu", len);
        return 0;
    }
    if (tag != 8 || version != 20) {
        if (diag_buf) {
            snprintf(diag_buf, diag_cap, "ver_tag len=%zu tag=%llu ver=%llu",
                     len, (unsigned long long)tag, (unsigned long long)version);
        }
        return 0;
    }

    while (pos < len) {
        if (read_varint(data, len, &pos, &tag) != 0) {
            if (diag_buf) snprintf(diag_buf, diag_cap, "pb_tag_eof len=%zu pos=%zu", len, pos);
            return 0;
        }
        if ((tag & 7) != 2) {
            if (diag_buf) {
                snprintf(diag_buf, diag_cap, "pb_wire len=%zu field=%llu wire=%llu",
                         len, (unsigned long long)(tag >> 3), (unsigned long long)(tag & 7));
            }
            return 0;
        }
        uint64_t size = 0;
        if (read_varint(data, len, &pos, &size) != 0) {
            if (diag_buf) {
                snprintf(diag_buf, diag_cap, "pb_size_eof len=%zu field=%llu rem=%zu",
                         len, (unsigned long long)(tag >> 3), len - pos);
            }
            return 0;
        }
        /* Takion 应用层会把 2296 字节的 field=3 分片到两个 1226B UDP 包中，目标偏移 556..564 位于首包内，故仅校验实际读写边界 */
        if ((tag >> 3) == 3) {
            if (size != 2296) {
                if (diag_buf) {
                    snprintf(diag_buf, diag_cap, "f3_size len=%zu f3_size=%llu (expected 2296)",
                             len, (unsigned long long)size);
                }
                return 0;
            }
            size_t lo = 333;
            size_t a = pos + (lo / 3 * 4);

            if (strcmp(profile_num, "65") == 0) {
                size_t b = pos + 448;
                if (b > len) return 0;
                uint8_t raw[3];
                if (b64_decode_4((char *)(data + a), raw) != 0) {
                    if (diag_buf) snprintf(diag_buf, diag_cap, "b64_65_err len=%zu", len);
                    return 0;
                }
                raw[1] ^= 0x04;
                b64_encode_4(raw, (char *)(data + a));
                return 1;
            } else if (strcmp(profile_num, "200") == 0) {
                size_t b = pos + 452;
                if (b > len) return 0;
                uint8_t raw[6];
                if (b64_decode_8((char *)(data + a), raw) != 0) {
                    if (diag_buf) snprintf(diag_buf, diag_cap, "b64_200_err len=%zu", len);
                    return 0;
                }
                uint8_t delta[5] = { 0x00, 0x50, 0x1b, 0x00, 0x05 };
                for (int i = 0; i < 5; i++) raw[1 + i] ^= delta[i];
                b64_encode_8(raw, (char *)(data + a));
                return 1;
            } else {
                size_t b = pos + 452;
                if (b > len) return 0;
                uint8_t raw[6];
                if (b64_decode_8((char *)(data + a), raw) != 0) {
                    if (diag_buf) snprintf(diag_buf, diag_cap, "b64_100_err len=%zu", len);
                    return 0;
                }
                uint8_t delta[5] = { 0x03, 0x50, 0x1b, 0x00, 0x05 };
                for (int i = 0; i < 5; i++) raw[1 + i] ^= delta[i];
                b64_encode_8(raw, (char *)(data + a));
                return 1;
            }
        }
        if (size > len - pos) {
            if (diag_buf) {
                snprintf(diag_buf, diag_cap, "pb_skip_oob len=%zu field=%llu size=%llu rem=%zu",
                         len, (unsigned long long)(tag >> 3), (unsigned long long)size, len - pos);
            }
            return 0;
        }
        pos += (size_t)size;
    }
    if (diag_buf) snprintf(diag_buf, diag_cap, "no_field3 len=%zu", len);
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
    if (strncmp(self_exe, PRIVILEGED_ENGINE_PREFIX, strlen(PRIVILEGED_ENGINE_PREFIX)) != 0) return 1;
    if (strstr(self_exe, "..") != NULL) return 1;

    struct stat dir_st;
    if (lstat(SYS_SUPPORT_DIR, &dir_st) != 0 ||
        !S_ISDIR(dir_st.st_mode) ||
        dir_st.st_uid != 0 ||
        (dir_st.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return 1;
    }

    struct stat exe_st;
    if (lstat(self_exe, &exe_st) != 0 ||
        !S_ISREG(exe_st.st_mode) ||
        exe_st.st_uid != 0 ||
        (exe_st.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
        (exe_st.st_mode & S_IXUSR) == 0) {
        return 1;
    }

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

    mkdir("/etc/sudoers.d", 0755);
    const char *tmp_path = "/etc/sudoers.d/.syspulse_portal.tmp";
    unlink(tmp_path);
    int fd = open(tmp_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return 1;

    FILE *f = fdopen(fd, "w");
    if (!f) {
        close(fd);
        unlink(tmp_path);
        return 1;
    }
    fprintf(f, "%%admin ALL=(root) NOPASSWD: %s *\n", escaped);
    fclose(f);

    char *const visudo_argv[] = { "/usr/sbin/visudo", "-cf", (char *)tmp_path, NULL };
    if (run_argv_quiet("/usr/sbin/visudo", visudo_argv) != 0) {
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
            g_iface[sizeof(g_iface) - 1] = '\0';
        } else if (strcmp(argv[i], "--ps5") == 0 && i + 1 < argc) {
            strncpy(ps5_ip_str, argv[++i], sizeof(ps5_ip_str) - 1);
            ps5_ip_str[sizeof(ps5_ip_str) - 1] = '\0';
        } else if (strcmp(argv[i], "--portal") == 0 && i + 1 < argc) {
            strncpy(portal_ip_str, argv[++i], sizeof(portal_ip_str) - 1);
            portal_ip_str[sizeof(portal_ip_str) - 1] = '\0';
        } else if (strcmp(argv[i], "--bitrate") == 0 && i + 1 < argc) {
            strncpy(bitrate_arg, argv[++i], sizeof(bitrate_arg) - 1);
            bitrate_arg[sizeof(bitrate_arg) - 1] = '\0';
        } else if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            const char *m = argv[++i];
            g_mode_oneway = (strcmp(m, "twoway") == 0) ? 0 : 1;
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
        long pid = 0;
        int pfd = open(PID_FILE, O_RDONLY | O_NOFOLLOW);
        if (pfd >= 0) {
            struct stat pst;
            if (fstat(pfd, &pst) == 0 && S_ISREG(pst.st_mode) && pst.st_uid == 0) {
                FILE *f = fdopen(pfd, "r");
                if (f) {
                    if (fscanf(f, "%ld", &pid) != 1 || pid <= 1) {
                        pid = 0;
                    }
                    fclose(f);
                } else {
                    close(pfd);
                }
            } else {
                close(pfd);
            }
        }
        if (pid > 1) {
            if (kill((pid_t)pid, SIGINT) == 0) {
                /* 等待引擎完成 300ms ARP 复原包发送并退出，避免中途打断 usleep */
                int exited = 0;
                for (int w = 0; w < 48; w++) {
                    if (kill((pid_t)pid, 0) != 0 && errno == ESRCH) {
                        exited = 1;
                        break;
                    }
                    usleep(25000);
                }
                if (!exited) {
                    kill((pid_t)pid, SIGTERM);
                    for (int w = 0; w < 12; w++) {
                        if (kill((pid_t)pid, 0) != 0 && errno == ESRCH) {
                            exited = 1;
                            break;
                        }
                        usleep(25000);
                    }
                }
                if (exited) {
                    unlink(PID_FILE);
                }
            } else if (errno == ESRCH) {
                unlink(PID_FILE);
            }
        } else {
            unlink(PID_FILE);
        }
        return 0;
    }

    if (geteuid() != 0) {
        printf("[错误] ❌ 需要管理员特权 (UID=0) 才能访问 /dev/bpf 与 ARP 注入。\n");
        fflush(stdout);
        return 1;
    }

    if (ps5_ip_str[0] && !is_valid_unicast_ipv4(ps5_ip_str, &g_ps5_ip)) {
        printf("[错误] ❌ 无效的 PS5 IPv4 地址: %s\n", ps5_ip_str);
        fflush(stdout);
        return 1;
    }
    if (portal_ip_str[0] && !is_valid_unicast_ipv4(portal_ip_str, &g_portal_ip)) {
        printf("[错误] ❌ 无效的 PS Portal IPv4 地址: %s\n", portal_ip_str);
        fflush(stdout);
        return 1;
    }

    if (restore_only) {
        if (load_restore_state() != 0) {
            if (!is_safe_interface_name(g_iface) || if_nametoindex(g_iface) == 0) {
                printf("[错误] ❌ 无效或不可用的网卡名称。\n");
                fflush(stdout);
                return 1;
            }
            uint8_t dummy_mac[6];
            uint32_t dummy_ip = 0;
            get_interface_mac_and_ip(g_iface, g_own_mac, &dummy_ip);
            if (ps5_ip_str[0] && resolve_mac_via_arp(ps5_ip_str, g_iface, dummy_mac, 1) == 0) {
                memcpy(g_ps5_mac, dummy_mac, 6);
                g_has_ps5_mac = 1;
            }
            if (portal_ip_str[0] && resolve_mac_via_arp(portal_ip_str, g_iface, dummy_mac, 1) == 0) {
                memcpy(g_portal_mac, dummy_mac, 6);
                g_has_portal_mac = 1;
            }
        }
        g_bpf_fd = open_bpf_device(g_iface, g_ps5_ip, g_portal_ip);
        restore_network_state(1);
        printf("[SysPulse] 网络直连路由已复原。\n");
        fflush(stdout);
        return 0;
    }

    if (!is_safe_interface_name(g_iface) || if_nametoindex(g_iface) == 0) {
        printf("[错误] ❌ 无效或不可用的网卡名称。\n");
        fflush(stdout);
        return 1;
    }
    if (!g_ps5_ip || !g_portal_ip || g_ps5_ip == g_portal_ip) {
        printf("[错误] ❌ 请提供两个不同的有效局域网单播 IPv4 地址。\n");
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

    FILE *pf = fopen_write_nofollow(PID_FILE, 0644);
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

    check_route_for_ip("PS5", ps5_ip_str, g_iface);
    check_route_for_ip("PS Portal", portal_ip_str, g_iface);

    ping_hosts_parallel(ps5_ip_str, portal_ip_str);
    if (ps5_ip_str[0] && resolve_mac_via_arp(ps5_ip_str, g_iface, g_ps5_mac, 0) == 0) {
        g_has_ps5_mac = 1;
    }
    if (portal_ip_str[0] && resolve_mac_via_arp(portal_ip_str, g_iface, g_portal_mac, 0) == 0) {
        g_has_portal_mac = 1;
    }

    char own_ip_buf[16], own_mac_buf[18], ps5_mac_buf[18], portal_mac_buf[18];
    format_ip_str(g_own_ip, own_ip_buf);
    format_mac_str(g_own_mac, own_mac_buf);
    if (g_has_ps5_mac) format_mac_str(g_ps5_mac, ps5_mac_buf);
    if (g_has_portal_mac) format_mac_str(g_portal_mac, portal_mac_buf);

    printf("[诊断] 网卡 %s (%s | MAC %s) | 模式: %s\n",
           g_iface, own_ip_buf, own_mac_buf,
           g_mode_oneway ? "单向视频直连 (oneway)" : "双向遥测验证 (twoway)");
    printf("[诊断] PS5 (%s): %s | Portal (%s): %s\n",
           ps5_ip_str[0] ? ps5_ip_str : "未配置",
           g_has_ps5_mac ? ps5_mac_buf : "待 ARP 探测",
           portal_ip_str[0] ? portal_ip_str : "未配置",
           g_has_portal_mac ? portal_mac_buf : "待 ARP 探测");
    if (validate_distinct_macs() != 0) {
        printf("[错误] ❌ 检测到设备 MAC 冲突（Mac / PS5 / Portal 存在相同 MAC，可能误填网关 IP 或路由器开启了 Proxy ARP），已中止中继以保护网络！\n");
        fflush(stdout);
        unlink(PID_FILE);
        return 1;
    }
    if (!g_has_ps5_mac || !g_has_portal_mac) {
        printf("[诊断] 🔍 尚有设备 MAC 未解析（可能处于待机），将持续广播 ARP 探测并在双方均就绪后启用%s。\n",
               g_mode_oneway ? "单向牵引" : "双向中继");
    }
    fflush(stdout);

    g_bpf_fd = open_bpf_device(g_iface, g_ps5_ip, g_portal_ip);
    if (g_bpf_fd < 0) {
        printf("[错误] ❌ 无法打开 /dev/bpf 设备，请确认管理员特权状态。\n");
        fflush(stdout);
        unlink(PID_FILE);
        return 1;
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
        restore_network_state(0);
        printf("[错误] ❌ 内存分配失败。\n");
        return 1;
    }

    double start_ts = monotonic_seconds();
    double ready_at = start_ts + 1.5;
    double end_ts = ready_at + 120.0;
    double next_arp = 0.0;
    double first_mutated_at = 0.0;
    double streaminfo_at = 0.0;
    int ready_announced = 0;
    int first_mutated_announced = 0;
    int first_out_seen = 0;
    int first_in_seen = 0;
    int spoof_started_announced = 0;
    int early_direct_handoff = 0;
    int mac_conflict_aborted = 0;
    int frag_warned = 0;

    uint64_t fwd_in = 0;
    uint64_t fwd_out = 0;
    uint64_t write_err_cnt = 0;
    uint64_t unmatched_9296_large_out = 0;
    char first_unmatched_diag[160] = "";
    int last_write_errno = 0;
    uint8_t seen_seqs[MAX_SEEN_SEQS][8];
    int unique_seqs = 0;

    static const uint8_t BROADCAST_MAC[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    static const uint8_t ZERO_MAC[6] = { 0, 0, 0, 0, 0, 0 };

    ConfirmationState conf;
    memset(&conf, 0, sizeof(conf));
    conf.confirm_threshold = confirm_target;

    while (g_running) {
        double now = monotonic_seconds();
        if (now >= end_ts) break;
        if (g_mode_oneway && first_mutated_announced && first_mutated_at > 0.0 && (now - first_mutated_at >= 3.0)) {
            break;
        }
        if (!g_mode_oneway && conf.accepted && conf.streaming && streaminfo_at > 0.0 && (now - streaminfo_at >= 5.0)) {
            early_direct_handoff = 1;
            break;
        }

        if (now >= next_arp) {
            if (!g_has_ps5_mac && g_ps5_ip) {
                send_arp_raw(g_bpf_fd, BROADCAST_MAC, g_own_mac, 1, g_own_mac, g_own_ip, ZERO_MAC, g_ps5_ip);
            }
            if (!g_has_portal_mac && g_portal_ip) {
                send_arp_raw(g_bpf_fd, BROADCAST_MAC, g_own_mac, 1, g_own_mac, g_own_ip, ZERO_MAC, g_portal_ip);
            }
            if (g_has_ps5_mac && g_has_portal_mac && g_ps5_ip && g_portal_ip) {
                if (validate_distinct_macs() != 0) {
                    printf("[错误] ❌ 检测到设备 MAC 冲突（Mac / PS5 / Portal 存在相同 MAC），已中止中继以保护网络！\n");
                    fflush(stdout);
                    mac_conflict_aborted = 1;
                    break;
                }
                if (!spoof_started_announced) {
                    spoof_started_announced = 1;
                    g_spoof_active = 1;
                    save_restore_state();
                    printf("[诊断] ✅ 双方 MAC 已就绪，已启动%s。\n",
                           g_mode_oneway ? "单向 ARP 牵引" : "双向 ARP 中继牵引");
                    fflush(stdout);
                }
                // 单向模式只对 Portal 发起牵引；双向模式对两端发起牵引
                send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_own_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
                if (!g_mode_oneway) {
                    send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_own_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
                }
            }
            next_arp = now + 1.0;
        }

        if (!ready_announced && now >= ready_at) {
            ready_announced = 1;
            printf("----------------------------------------------------------------------\n");
            printf("[准备] ⚡️ 网络协商就绪！请在 120 秒内在 Portal 上点击连接 PS5...\n");
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
                if (g_ps5_ip && arp->spa == g_ps5_ip && !g_has_ps5_mac && memcmp(arp->sha, g_own_mac, 6) != 0) {
                    memcpy(g_ps5_mac, arp->sha, 6);
                    g_has_ps5_mac = 1;
                    char mac_s[18];
                    format_mac_str(g_ps5_mac, mac_s);
                    printf("[诊断] 📡 捕获 PS5 MAC: %s\n", mac_s);
                    fflush(stdout);
                    if (g_has_portal_mac) next_arp = 0.0;
                }
                if (g_portal_ip && arp->spa == g_portal_ip && !g_has_portal_mac && memcmp(arp->sha, g_own_mac, 6) != 0) {
                    memcpy(g_portal_mac, arp->sha, 6);
                    g_has_portal_mac = 1;
                    char mac_s[18];
                    format_mac_str(g_portal_mac, mac_s);
                    printf("[诊断] 📡 捕获 Portal MAC: %s\n", mac_s);
                    fflush(stdout);
                    if (g_has_ps5_mac) next_arp = 0.0;
                }
                // 抢占应答目标设备的 ARP Who-Has 探测，防止真实对端回复覆盖欺骗条目
                if (g_has_ps5_mac && g_has_portal_mac && validate_distinct_macs() == 0 && ntohs(arp->op) == 1) {
                    if (arp->spa == g_portal_ip && arp->tpa == g_ps5_ip) {
                        send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_own_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
                        send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_own_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
                    } else if (!g_mode_oneway && arp->spa == g_ps5_ip && arp->tpa == g_portal_ip) {
                        send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_own_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
                        send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_own_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
                    }
                }
                continue;
            }

            if (ntohs(eth->ethertype) != 0x0800) continue;
            if (pkt_len < sizeof(struct eth_header) + sizeof(struct ip_header)) continue;

            struct ip_header *ip = (struct ip_header *)(pkt + sizeof(struct eth_header));
            if ((ip->ihl_ver >> 4) != 4) continue;
            size_t ip_hl = (ip->ihl_ver & 0x0F) * 4;
            size_t ip_tot = ntohs(ip->tot_len);
            if (ip_hl < 20 || ip_tot < ip_hl || pkt_len < sizeof(struct eth_header) + ip_tot) continue;

            // 从到达的 IPv4 包源 MAC 兜底学习未解析设备的 MAC（避免对方沿用旧 ARP 缓存不发广播）
            if (g_portal_ip && ip->saddr == g_portal_ip && ip->daddr == g_ps5_ip && !g_has_portal_mac) {
                if (!g_has_ps5_mac || memcmp(eth->src, g_ps5_mac, 6) != 0) {
                    memcpy(g_portal_mac, eth->src, 6);
                    g_has_portal_mac = 1;
                    char mac_s[18];
                    format_mac_str(g_portal_mac, mac_s);
                    printf("[诊断] 📡 从 IPv4 流量捕获 Portal MAC: %s\n", mac_s);
                    fflush(stdout);
                    if (g_has_ps5_mac) next_arp = 0.0;
                }
            }
            if (g_ps5_ip && ip->saddr == g_ps5_ip && ip->daddr == g_portal_ip && !g_has_ps5_mac) {
                if (!g_has_portal_mac || memcmp(eth->src, g_portal_mac, 6) != 0) {
                    memcpy(g_ps5_mac, eth->src, 6);
                    g_has_ps5_mac = 1;
                    char mac_s[18];
                    format_mac_str(g_ps5_mac, mac_s);
                    printf("[诊断] 📡 从 IPv4 流量捕获 PS5 MAC: %s\n", mac_s);
                    fflush(stdout);
                    if (g_has_portal_mac) next_arp = 0.0;
                }
            }

            if (memcmp(eth->dst, g_own_mac, 6) != 0) continue;

            int is_out = (g_portal_ip && g_ps5_ip && ip->saddr == g_portal_ip && ip->daddr == g_ps5_ip);
            int is_in  = (g_portal_ip && g_ps5_ip && ip->saddr == g_ps5_ip && ip->daddr == g_portal_ip);
            if (!is_out && !is_in) continue;

            if (ip->proto == IPPROTO_UDP && !frag_warned && (ntohs(ip->frag_off) & 0x1FFF) == 0 && (ntohs(ip->frag_off) & 0x2000) != 0 && ip_tot >= ip_hl + sizeof(struct udp_header)) {
                struct udp_header *frag_udp = (struct udp_header *)((uint8_t *)ip + ip_hl);
                if (is_out && ntohs(frag_udp->dest) == 9296) {
                    frag_warned = 1;
                    printf("[诊断] ⚠️ 检测到分片 UDP 9296 握手包（当前链路 MTU 发生 IP 分片，可能影响握手注入）。\n");
                    fflush(stdout);
                }
            }

            if (ip->proto == IPPROTO_UDP && (ntohs(ip->frag_off) & 0x3FFF) == 0 && ip_tot >= ip_hl + sizeof(struct udp_header)) {
                struct udp_header *udp = (struct udp_header *)((uint8_t *)ip + ip_hl);
                uint16_t sport = ntohs(udp->source);
                uint16_t dport = ntohs(udp->dest);
                size_t udp_len = ntohs(udp->len);
                if (udp_len >= sizeof(struct udp_header) && ip_hl + udp_len <= ip_tot) {
                    uint8_t *payload = (uint8_t *)udp + sizeof(struct udp_header);
                    size_t payload_len = udp_len - sizeof(struct udp_header);

                    if (is_out && dport == 9296 && payload_len >= 32) {
                        char diag_buf[160] = "";
                        if (mutate_launchspec(payload, payload_len, profile_num, payload_len >= 1000 ? diag_buf : NULL, sizeof(diag_buf))) {
                            udp->check = 0;
                            udp->check = htons(udp_checksum(ip, udp, udp_len));
                            ip->check = 0;
                            ip->check = htons(calc_checksum(ip, ip_hl));

                            uint8_t seq_key[8];
                            memcpy(seq_key, payload + 1, 4);
                            memcpy(seq_key + 4, payload + 17, 4);
                            int already_seen = 0;
                            for (int s = 0; s < unique_seqs; s++) {
                                if (memcmp(seen_seqs[s], seq_key, 8) == 0) {
                                    already_seen = 1;
                                    break;
                                }
                            }
                            if (!already_seen) {
                                if (unique_seqs < MAX_SEEN_SEQS) {
                                    memcpy(seen_seqs[unique_seqs], seq_key, 8);
                                }
                                unique_seqs++;
                                conf.armed = 1;
                                conf.accepted = 0;
                                conf.streaming = 0;
                                conf.samples = 0;
                                streaminfo_at = 0.0;
                            }
                            if (!first_mutated_announced) {
                                first_mutated_announced = 1;
                                first_mutated_at = monotonic_seconds();
                                printf("[注入] 🎯 截获并修改 LaunchSpec 握手参数为 %s Mbps！\n", profile_num);
                                fflush(stdout);
                            }
                        } else if (payload_len >= 1000) {
                            unmatched_9296_large_out++;
                            if (!first_unmatched_diag[0] && diag_buf[0]) {
                                snprintf(first_unmatched_diag, sizeof(first_unmatched_diag), "%s", diag_buf);
                            }
                        }
                    } else if (!g_mode_oneway && is_in && sport == 9296) {
                        int prev_streaming = conf.streaming;
                        observe_ps5_message(payload, payload_len, &conf);
                        if (!prev_streaming && conf.streaming) {
                            streaminfo_at = monotonic_seconds();
                        }
                    }
                }
            }

            if (is_out && g_has_ps5_mac) {
                memcpy(eth->dst, g_ps5_mac, 6);
                memcpy(eth->src, g_own_mac, 6);
                size_t frame_len = sizeof(struct eth_header) + ip_tot;
                ssize_t nw = write(g_bpf_fd, pkt, frame_len);
                if (nw > 0) {
                    fwd_out++;
                    if (!first_out_seen) {
                        first_out_seen = 1;
                        printf("[诊断] ⬆️ 已捕获并转发 Portal -> PS5 首包 (Proto %u, %zu 字节)\n", ip->proto, frame_len);
                        fflush(stdout);
                    }
                } else {
                    write_err_cnt++;
                    last_write_errno = errno;
                    if (write_err_cnt <= 3) {
                        printf("[诊断] ❌ BPF 转发写入失败 (方向: Portal->PS5, %zu 字节, errno=%d: %s)\n",
                               frame_len, last_write_errno, strerror(last_write_errno));
                        fflush(stdout);
                    }
                }
            } else if (!g_mode_oneway && is_in && g_has_portal_mac) {
                memcpy(eth->dst, g_portal_mac, 6);
                memcpy(eth->src, g_own_mac, 6);
                size_t frame_len = sizeof(struct eth_header) + ip_tot;
                ssize_t nw = write(g_bpf_fd, pkt, frame_len);
                if (nw > 0) {
                    fwd_in++;
                    if (!first_in_seen) {
                        first_in_seen = 1;
                        printf("[诊断] ⬇️ 已捕获并转发 PS5 -> Portal 首包 (Proto %u, %zu 字节)\n", ip->proto, frame_len);
                        fflush(stdout);
                    }
                } else {
                    write_err_cnt++;
                    last_write_errno = errno;
                    if (write_err_cnt <= 3) {
                        printf("[诊断] ❌ BPF 转发写入失败 (方向: PS5->Portal, %zu 字节, errno=%d: %s)\n",
                               frame_len, last_write_errno, strerror(last_write_errno));
                        fflush(stdout);
                    }
                }
            }

            if (conf.confirmed) break;
        }

        if (conf.confirmed) break;
    }

    free(bpf_buffer);
    restore_network_state(0);

    if (mac_conflict_aborted) {
        return 1;
    }

    double target_mbps = conf.last_target_raw > 0 ? ((double)conf.last_target_raw / 1000000.0) : 0.0;
    const char *status_line;
    char status_buf[256];
    char inject_buf[256];
    const char *quality_line;
    int exit_code = 0;

    if (g_mode_oneway && unique_seqs > 0) {
        printf("[成功] 🎉 已注入 %s Mbps LaunchSpec 并保持视频直连！\n", profile_num);
        printf("[路由] 🔄 下行视频流全程直连 PS Portal，不经过 Mac 中转；Portal 侧 ARP 已复原。\n");
        snprintf(status_buf, sizeof(status_buf), "✅ %s Mbps Profile (单向注入成功 · 视频流全程直连)", profile_num);
        snprintf(inject_buf, sizeof(inject_buf), "成功修改 %d 个序列启动包 (Offset %d · Hex %s)", unique_seqs, OFFSET, hex_bytes);
        status_line = status_buf;
        quality_line = "单向直连模式 (视频流不经过 Mac，无中继限速)";
        exit_code = 0;
    } else if (unique_seqs > 0 && conf.confirmed) {
        double shown_mbps = target_mbps > 0.0 ? target_mbps : (atof(profile_num) * 0.97);
        printf("[成功] 🎉 PS5 已确认并接受高码率协商！\n");
        printf("[路由] 🔄 局域网直连路由已平滑复原，进入纯 Wi-Fi 串流状态。\n");
        snprintf(status_buf, sizeof(status_buf), "✅ %s Mbps Profile (PS5 锁定上限: %.1f Mbps)", profile_num, shown_mbps);
        snprintf(inject_buf, sizeof(inject_buf), "成功修改 %d 个序列启动包 (Offset %d · Hex %s)", unique_seqs, OFFSET, hex_bytes);
        status_line = status_buf;
        quality_line = "连续捕获 3 次高码率质量回报 (Quality Confirmed)";
        exit_code = 0;
    } else if (unique_seqs > 0 && early_direct_handoff) {
        printf("[成功] 🎉 PS5 已确认接收握手并开播，已提前交还直连以防 Mac 中继限速！\n");
        printf("[路由] 🔄 局域网直连路由已平滑复原，进入全速直连串流状态。\n");
        if (target_mbps > 0.0) {
            snprintf(status_buf, sizeof(status_buf), "✅ %s Mbps Profile (握手已接受 · 中继期回报 %.1f Mbps · 已切直连)", profile_num, target_mbps);
        } else {
            snprintf(status_buf, sizeof(status_buf), "✅ %s Mbps Profile (握手已接受 · 已提前交还直连)", profile_num);
        }
        snprintf(inject_buf, sizeof(inject_buf), "成功修改 %d 个序列启动包 (Offset %d · Hex %s)", unique_seqs, OFFSET, hex_bytes);
        status_line = status_buf;
        quality_line = "已确认 Key Accepted & 开播，已提前释放直连";
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
        if (unmatched_9296_large_out > 0) {
            printf("[诊断] 💡 捕获到 %llu 个 Portal->PS5 UDP/9296 大载荷包但未命中 LaunchSpec 模板 (%s)。\n",
                   (unsigned long long)unmatched_9296_large_out,
                   first_unmatched_diag[0] ? first_unmatched_diag : "未知原因");
        }
        status_line = "❌ 未生效 (未捕获到握手启动包，请唤醒 Portal 并点击连接 PS5)";
        snprintf(inject_buf, sizeof(inject_buf), "未检测到 LaunchSpec 启动包 (修改 0 个)");
        quality_line = "未收到 PS5 质量回报";
        exit_code = 1;
    }

    printf("----------------------------------------------------------------------\n");
    printf("📊 【PS Portal 串流画质增强报告】\n");
    printf("├─ 协商状态: %s\n", status_line);
    if (g_mode_oneway) {
        printf("├─ 流量统计: 上行握手转发 %llu 包 (下行视频流全程直连不经 Mac)\n", (unsigned long long)fwd_out);
    } else {
        printf("├─ 流量统计: 下行转发 %llu 包 | 上行转发 %llu 包\n", (unsigned long long)fwd_in, (unsigned long long)fwd_out);
    }
    printf("├─ 启动注入: %s\n", inject_buf);
    printf("├─ 链路质量: %s\n", quality_line);
    if (write_err_cnt > 0) {
        printf("├─ 转发异常: BPF 写入失败 %llu 次 (最近 errno=%d: %s)\n",
               (unsigned long long)write_err_cnt, last_write_errno, strerror(last_write_errno));
    }
    printf("└─ 引擎模式: SysPulse Native C BPF Engine（%s）\n",
           g_mode_oneway ? "方案 A：单向视频直连" : "方案 B：双向遥测验证");
    printf("----------------------------------------------------------------------\n");
    if (exit_code != 0) {
        printf("%s\n", unique_seqs > 0 ? "UNCONFIRMED: mutation sent without 3 high-bitrate confirmations." : "NOT APPLIED: no matching fresh handshake.");
    }
    fflush(stdout);
    return exit_code;
}
