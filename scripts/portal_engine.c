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
#include <libproc.h>
#include <ctype.h>

#define SYS_SUPPORT_DIR "/Library/Application Support/SysPulse"
#define PRIVILEGED_ENGINE_PREFIX "/Library/Application Support/SysPulse/"
#define PID_FILE "/Library/Application Support/SysPulse/syspulse_psportal.pid"
#define STATE_FILE "/Library/Application Support/SysPulse/syspulse_psportal_state.txt"
#define CLAMSHELL_STATE_FILE "/Library/Application Support/SysPulse/syspulse_psportal_clamshell.state"
#define BPF_BUF_LEN 65536
#define OFFSET 334
#define MAX_SEEN_SEQS 128
#define FRAG_SLOTS 8
#define MAX_FRAGS_PER_PKT 8
#define FRAG_MAX_FRAME_LEN 2048
#define FRAG_ASSEMBLE_CAP 4096
#define FRAG_TIMEOUT_SEC 0.35

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
static int g_watch_mode = 0;
static int g_debug_mode = 0;
static double g_engine_t0 = 0.0;
static pid_t g_parent_pid = 0;

static void emit_event(const char *fmt, ...) {
    va_list ap;
    printf("[EVENT] ");
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    fflush(stdout);
}

static double monotonic_seconds(void);

static void debug_log(const char *fmt, ...) {
    if (!g_debug_mode) return;
    double elapsed = (g_engine_t0 > 0.0) ? (monotonic_seconds() - g_engine_t0) : 0.0;
    printf("[DEBUG +%.3fs] ", elapsed);
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    printf("\n");
    fflush(stdout);
}

static void debug_hex_prefix(const uint8_t *buf, size_t len, char *out, size_t out_cap) {
    size_t n = len < 32 ? len : 32;
    size_t pos = 0;
    if (out_cap == 0) return;
    out[0] = '\0';
    for (size_t i = 0; i < n && pos + 3 < out_cap; i++) {
        pos += (size_t)snprintf(out + pos, out_cap - pos, "%s%02x", (i > 0 && (i % 4 == 0)) ? " " : "", buf[i]);
    }
}

typedef struct {
    int in_use;
    uint32_t saddr;
    uint32_t daddr;
    uint16_t ip_id;
    uint8_t proto;
    double created_at;
    int is_udp_9296;
    int non_9296;
    int has_last;
    size_t expected_ip_payload_len;
    int frag_count;
    struct {
        uint8_t frame[FRAG_MAX_FRAME_LEN];
        size_t frame_len;
        size_t ip_hl;
        size_t frag_off_bytes;
        size_t payload_len;
        int more_frags;
    } frags[MAX_FRAGS_PER_PKT];
} FragReassemblySlot;

static FragReassemblySlot g_frag_slots[FRAG_SLOTS];

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

static void configure_bpf_filter_ex(int fd, uint32_t ps5_ip_net, uint32_t portal_ip_net, int include_discovery, int no_flush) {
    if (ps5_ip_net == 0 || portal_ip_net == 0) return;

    uint32_t ps5_h = ntohl(ps5_ip_net);
    uint32_t portal_h = ntohl(portal_ip_net);
    unsigned long cmd = no_flush ? BIOCSETFNR : BIOCSETF;

    if (include_discovery) {
        /* 哨兵模式统一过滤：放行 ARP (0x0806)、PS5 <-> Portal IPv4、以及任意源广播/单播 UDP 9302/67 (0x0800) */
        struct bpf_insn insns[] = {
            /* 0: 读取 EtherType (offset 12, 2 bytes) */
            BPF_STMT(BPF_LD + BPF_H + BPF_ABS, 12),
            /* 1: ARP (0x0806) -> ACCEPT (idx 18) */
            BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, 0x0806, 16, 0),
            /* 2: IPv4 (0x0800) -> next (idx 3), else DROP (idx 19) */
            BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, 0x0800, 0, 16),
            /* 3: 读取 IPv4 源地址 (offset 26) */
            BPF_STMT(BPF_LD + BPF_W + BPF_ABS, 26),
            /* 4: src == PS5 -> 5, else 7 */
            BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ps5_h, 0, 2),
            /* 5: dst */
            BPF_STMT(BPF_LD + BPF_W + BPF_ABS, 30),
            /* 6: dst == Portal -> ACCEPT (18), else 10 */
            BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, portal_h, 11, 3),
            /* 7: src == Portal -> 8, else 10 */
            BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, portal_h, 0, 2),
            /* 8: dst */
            BPF_STMT(BPF_LD + BPF_W + BPF_ABS, 30),
            /* 9: dst == PS5 -> ACCEPT (18), else 10 */
            BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, ps5_h, 8, 0),
            /* 10: ip.proto (offset 23) */
            BPF_STMT(BPF_LD + BPF_B + BPF_ABS, 23),
            /* 11: UDP (17) -> 12, else DROP (19) */
            BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, 17, 0, 7),
            /* 12: ip.frag_off (offset 20) */
            BPF_STMT(BPF_LD + BPF_H + BPF_ABS, 20),
            /* 13: frag_off & 0x1FFF != 0 -> DROP (19), else 14 */
            BPF_JUMP(BPF_JMP + BPF_JSET + BPF_K, 0x1FFF, 5, 0),
            /* 14: X = IP header length */
            BPF_STMT(BPF_LDX + BPF_B + BPF_MSH, 14),
            /* 15: A = UDP dport (14 + X + 2) */
            BPF_STMT(BPF_LD + BPF_H + BPF_IND, 16),
            /* 16: dport == 9302 -> ACCEPT (18), else 17 */
            BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, 9302, 1, 0),
            /* 17: dport == 67 -> ACCEPT (18), else DROP (19) */
            BPF_JUMP(BPF_JMP + BPF_JEQ + BPF_K, 67, 0, 1),
            /* 18: ACCEPT */
            BPF_STMT(BPF_RET + BPF_K, (u_int)-1),
            /* 19: DROP */
            BPF_STMT(BPF_RET + BPF_K, 0)
        };
        struct bpf_program prog;
        prog.bf_len = (u_int)(sizeof(insns) / sizeof(insns[0]));
        prog.bf_insns = insns;
        ioctl(fd, cmd, &prog);
        return;
    }

    /* 手动模式窄过滤：仅放行 ARP (0x0806) 与 PS5 <-> Portal 之间的全端口 IPv4 (0x0800) 帧 */
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
    ioctl(fd, cmd, &prog);
}

static void configure_bpf_filter(int fd, uint32_t ps5_ip_net, uint32_t portal_ip_net) {
    configure_bpf_filter_ex(fd, ps5_ip_net, portal_ip_net, g_watch_mode, 0);
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
            char *const argv[] = { "/sbin/ping", "-c", "1", "-W", "1000", (char *)ips[i], NULL };
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

static int check_route_for_ip(const char *label, const char *ip_str, const char *expected_iface, char *actual_iface_out, size_t actual_cap, int *has_gw_out) {
    if (actual_iface_out && actual_cap > 0) actual_iface_out[0] = '\0';
    if (has_gw_out) *has_gw_out = 0;
    if (!ip_str || !ip_str[0]) return 0;
    char out[4096];
    char *const argv[] = { "/sbin/route", "-n", "get", (char *)ip_str, NULL };
    if (run_argv_capture("/sbin/route", argv, out, sizeof(out)) != 0 || !out[0]) return 0;

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

    if (actual_iface_out && actual_cap > 0 && route_iface[0]) {
        snprintf(actual_iface_out, actual_cap, "%s", route_iface);
    }
    if (has_gw_out) *has_gw_out = has_gateway_flag;

    if (has_gateway_flag || (route_iface[0] && strcmp(route_iface, expected_iface) != 0)) {
        printf("[诊断] ⚠️ %s (%s) 系统路由为 %s%s，与当前选择网卡 %s 不一致！\n",
               label,
               ip_str,
               route_iface[0] ? route_iface : "未知接口",
               has_gateway_flag ? " (经过网关/非直连子网)" : "",
               expected_iface);
        fflush(stdout);
        emit_event("{\"type\":\"route_mismatch\",\"target\":\"%s\",\"ip\":\"%s\",\"actual_iface\":\"%s\",\"gateway\":%d}",
                   label, ip_str, route_iface[0] ? route_iface : "", has_gateway_flag);
        return -1;
    }
    return 0;
}

static int resolve_mac_via_arp(const char *ip_str, const char *expected_iface, uint8_t mac[6], int send_ping) {
    if (!ip_str || !ip_str[0]) return -1;
    if (send_ping) {
        char *const ping_argv[] = { "/sbin/ping", "-c", "1", "-W", "1000", (char *)ip_str, NULL };
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

static int set_clamshell_keepawake(int enable) {
    if (geteuid() != 0) return -1;
    if (enable) {
        FILE *f = fopen_write_nofollow(CLAMSHELL_STATE_FILE, 0600);
        if (f) {
            fprintf(f, "1\n");
            fclose(f);
        }
        char *const argv[] = { "/usr/bin/pmset", "-a", "disablesleep", "1", NULL };
        if (run_argv_quiet("/usr/bin/pmset", argv) != 0) {
            unlink(CLAMSHELL_STATE_FILE);
            return -1;
        }
        return 0;
    } else {
        char *const argv[] = { "/usr/bin/pmset", "-a", "disablesleep", "0", NULL };
        int rc = run_argv_quiet("/usr/bin/pmset", argv);
        unlink(CLAMSHELL_STATE_FILE);
        return (rc == 0) ? 0 : -1;
    }
}

static void restore_clamshell_keepawake_if_marked(void) {
    struct stat st;
    if (lstat(CLAMSHELL_STATE_FILE, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == 0) {
        set_clamshell_keepawake(0);
        printf("[守望] 💤 已自动还原系统休眠设置 (SleepDisabled=0)。\n");
        fflush(stdout);
    }
}

static void restore_arp_to_direct(int force_arp);

static void restore_network_state(int force_arp) {
    restore_arp_to_direct(force_arp);
    restore_clamshell_keepawake_if_marked();

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

static int mutate_launchspec_adaptive(uint8_t *f3_b64, size_t avail_len, uint64_t f3_size, const char *profile_num, char *diag_buf, size_t diag_cap) {
    size_t scan_b64 = f3_size < avail_len ? (size_t)f3_size : avail_len;
    if (scan_b64 > 3072) scan_b64 = 3072;
    scan_b64 = (scan_b64 / 4) * 4;
    if (scan_b64 < 64) {
        if (diag_buf && !diag_buf[0]) snprintf(diag_buf, diag_cap, "adaptive_short=%zu", scan_b64);
        return 0;
    }

    uint8_t dec[2304];
    size_t dec_len = 0;
    for (size_t i = 0; i + 4 <= scan_b64 && dec_len + 3 <= sizeof(dec); i += 4) {
        if (f3_b64[i + 2] == '=' || f3_b64[i + 3] == '=') break;
        if (b64_decode_4((const char *)(f3_b64 + i), dec + dec_len) != 0) break;
        dec_len += 3;
    }
    if (dec_len < 32) {
        if (diag_buf && !diag_buf[0]) snprintf(diag_buf, diag_cap, "adaptive_b64_err dec=%zu", dec_len);
        return 0;
    }

    const char *needle = "\"bwKbpsSent\":";
    size_t needle_len = strlen(needle);
    size_t found_pos = SIZE_MAX;
    for (size_t i = 0; i + needle_len < dec_len; i++) {
        if (memcmp(dec + i, needle, needle_len) == 0) {
            found_pos = i + needle_len;
            break;
        }
    }
    if (found_pos == SIZE_MAX) {
        if (diag_buf && !diag_buf[0]) snprintf(diag_buf, diag_cap, "adaptive_no_bwkey dec=%zu", dec_len);
        return 0;
    }

    while (found_pos < dec_len && (dec[found_pos] == ' ' || dec[found_pos] == '\t')) found_pos++;
    size_t tok_end = found_pos;
    while (tok_end < dec_len) {
        uint8_t ch = dec[tok_end];
        if ((ch >= '0' && ch <= '9') || ch == 'e' || ch == 'E' || ch == '+' || ch == '-' || ch == '.') {
            tok_end++;
        } else {
            break;
        }
    }
    size_t tok_len = tok_end - found_pos;
    if (tok_len < 4) {
        if (diag_buf && !diag_buf[0]) snprintf(diag_buf, diag_cap, "adaptive_tok_short=%zu", tok_len);
        return 0;
    }

    char orig_tok[24] = "";
    size_t copy_len = tok_len < sizeof(orig_tok) - 1 ? tok_len : sizeof(orig_tok) - 1;
    memcpy(orig_tok, dec + found_pos, copy_len);
    orig_tok[copy_len] = '\0';

    char replacement[16];
    memset(replacement, ' ', sizeof(replacement));
    if (tok_len == 4) {
        if (strcmp(profile_num, "65") == 0) memcpy(replacement, "65e3", 4);
        else if (strcmp(profile_num, "200") == 0) memcpy(replacement, "2e+5", 4);
        else memcpy(replacement, "1e+5", 4);
    } else if (tok_len == 5) {
        if (strcmp(profile_num, "65") == 0) memcpy(replacement, "65000", 5);
        else if (strcmp(profile_num, "200") == 0) memcpy(replacement, "2e+05", 5);
        else memcpy(replacement, "1e+05", 5);
    } else {
        const char *num = (strcmp(profile_num, "65") == 0) ? "65000"
                        : ((strcmp(profile_num, "200") == 0) ? "200000" : "100000");
        size_t nlen = strlen(num);
        if (nlen > tok_len) return 0;
        memcpy(replacement, num, nlen);
    }
    memcpy(dec + found_pos, replacement, tok_len);
    debug_log("adaptive LaunchSpec: pos=%zu orig_bw=%s -> new_len=%zu (profile=%s)",
              found_pos, orig_tok, tok_len, profile_num);

    size_t lo = (found_pos / 3) * 3;
    size_t hi = ((tok_end + 2) / 3) * 3;
    size_t b64_start = (lo / 3) * 4;
    size_t b64_end = (hi / 3) * 4;
    if (hi > dec_len || b64_end > scan_b64) return 0;

    for (size_t i = lo, j = b64_start; i < hi; i += 3, j += 4) {
        b64_encode_4(dec + i, (char *)(f3_b64 + j));
    }
    return 1;
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
    if (tag != 8 || version < 18 || version > 32) {
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
            if (version == 20 && size == 2296) {
                size_t lo = 333;
                size_t a = pos + (lo / 3 * 4);

                if (strcmp(profile_num, "65") == 0) {
                    size_t b = pos + 448;
                    if (b <= len) {
                        uint8_t raw[3];
                        if (b64_decode_4((char *)(data + a), raw) == 0) {
                            raw[1] ^= 0x04;
                            b64_encode_4(raw, (char *)(data + a));
                            return 1;
                        }
                    }
                } else if (strcmp(profile_num, "200") == 0) {
                    size_t b = pos + 452;
                    if (b <= len) {
                        uint8_t raw[6];
                        if (b64_decode_8((char *)(data + a), raw) == 0) {
                            uint8_t delta[5] = { 0x00, 0x50, 0x1b, 0x00, 0x05 };
                            for (int i = 0; i < 5; i++) raw[1 + i] ^= delta[i];
                            b64_encode_8(raw, (char *)(data + a));
                            return 1;
                        }
                    }
                } else {
                    size_t b = pos + 452;
                    if (b <= len) {
                        uint8_t raw[6];
                        if (b64_decode_8((char *)(data + a), raw) == 0) {
                            uint8_t delta[5] = { 0x03, 0x50, 0x1b, 0x00, 0x05 };
                            for (int i = 0; i < 5; i++) raw[1 + i] ^= delta[i];
                            b64_encode_8(raw, (char *)(data + a));
                            return 1;
                        }
                    }
                }
            }
            /* 自适应 JSON 等长定位回退路径（兼容固件版本或偏移微调） */
            if (mutate_launchspec_adaptive(data + pos, len - pos, size, profile_num, diag_buf, diag_cap)) {
                return 1;
            }
            if (diag_buf && !diag_buf[0]) {
                snprintf(diag_buf, diag_cap, "f3_adaptive_miss len=%zu ver=%llu f3_size=%llu",
                         len, (unsigned long long)version, (unsigned long long)size);
            }
            return 0;
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
            debug_log("PS5<-BANG ver=%llu key_acc=%llu ver_acc=%llu armed=%d accepted=%d",
                      (unsigned long long)ver, (unsigned long long)key_acc,
                      (unsigned long long)ver_acc, st->armed, st->accepted);
            if (st->accepted && !st->bang_printed) {
                st->bang_printed = 1;
                printf("[响应] 📡 收到 PS5 确认响应 (BANG v%llu · Key Accepted)\n", (unsigned long long)ver);
                fflush(stdout);
            }
        }
    } else if (kind == 13 && st->accepted) {
        st->streaming = 1;
        debug_log("PS5<-STREAMINFO accepted=1 streaming=1");
    } else if (kind == 16 && f17_ptr) {
        uint64_t raw_target = 0;
        if (parse_submessage_varints(f17_ptr, f17_len, &raw_target, NULL, NULL) == 0) {
            if (raw_target > 0) st->last_target_raw = raw_target;
            debug_log("PS5<-CONNECTIONQUALITY target_raw=%llu samples=%d armed=%d accepted=%d streaming=%d",
                      (unsigned long long)raw_target, st->samples, st->armed, st->accepted, st->streaming);
            if (!st->armed && !st->early_warned) {
                st->early_warned = 1;
                printf("[警告] ⚠️ 检测到未修改的旧串流会话，请先断开 Portal 重试...\n");
                fflush(stdout);
                emit_event("{\"type\":\"already_streaming\",\"source\":\"ps5_telemetry\"}");
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

static void disable_kernel_ip_bypass(void) {
    int mib_redir[4] = { CTL_NET, PF_INET, IPPROTO_IP, IPCTL_SENDREDIRECTS };
    size_t len_redir = sizeof(g_orig_redirect);
    if (g_orig_redirect < 0 && sysctl(mib_redir, 4, &g_orig_redirect, &len_redir, NULL, 0) == 0) {
        if (g_orig_redirect != 0) {
            int zero = 0;
            sysctl(mib_redir, 4, NULL, NULL, &zero, sizeof(zero));
        } else {
            g_orig_redirect = -1;
        }
    }
    int mib_fwd[4] = { CTL_NET, PF_INET, IPPROTO_IP, IPCTL_FORWARDING };
    size_t len_fwd = sizeof(g_orig_forwarding);
    if (g_orig_forwarding < 0 && sysctl(mib_fwd, 4, &g_orig_forwarding, &len_fwd, NULL, 0) == 0) {
        if (g_orig_forwarding != 0) {
            int zero = 0;
            sysctl(mib_fwd, 4, NULL, NULL, &zero, sizeof(zero));
        } else {
            g_orig_forwarding = -1;
        }
    }
}

static void restore_arp_to_direct(int force_arp) {
    if (g_bpf_fd >= 0 && g_has_ps5_mac && g_has_portal_mac && g_ps5_ip && g_portal_ip && (g_spoof_active || force_arp)) {
        for (int i = 0; i < 5; i++) {
            send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_ps5_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
            if (!g_mode_oneway || force_arp) {
                send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_portal_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
            }
            usleep(60000);
        }
    }
    g_spoof_active = 0;
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
    unlink(STATE_FILE);
}

static uint16_t udp_checksum_raw(uint32_t saddr, uint32_t daddr, const uint8_t *udp_bytes, size_t udp_len) {
    struct udp_pseudo pseudo;
    pseudo.src = saddr;
    pseudo.dst = daddr;
    pseudo.zero = 0;
    pseudo.proto = IPPROTO_UDP;
    pseudo.len = htons((uint16_t)udp_len);

    uint8_t buf[sizeof(pseudo) + FRAG_ASSEMBLE_CAP];
    if (udp_len > FRAG_ASSEMBLE_CAP) return 0;
    memcpy(buf, &pseudo, sizeof(pseudo));
    memcpy(buf + sizeof(pseudo), udp_bytes, udp_len);
    uint16_t cs = calc_checksum(buf, sizeof(pseudo) + udp_len);
    return (cs == 0) ? 0xFFFF : cs;
}

static void forward_out_frame(uint8_t *frame, size_t frame_len, uint64_t *fwd_out,
                              uint64_t *write_err_cnt, int *last_write_errno) {
    if (!g_has_ps5_mac || frame_len < sizeof(struct eth_header)) return;
    struct eth_header *eth = (struct eth_header *)frame;
    memcpy(eth->dst, g_ps5_mac, 6);
    memcpy(eth->src, g_own_mac, 6);
    ssize_t nw = write(g_bpf_fd, frame, frame_len);
    if (nw > 0) {
        if (fwd_out) (*fwd_out)++;
    } else {
        if (write_err_cnt) (*write_err_cnt)++;
        if (last_write_errno) *last_write_errno = errno;
    }
}

static void flush_frag_slot_raw(FragReassemblySlot *slot, uint64_t *fwd_out,
                                uint64_t *write_err_cnt, int *last_write_errno) {
    if (!slot || !slot->in_use) return;
    for (int i = 0; i < slot->frag_count; i++) {
        forward_out_frame(slot->frags[i].frame, slot->frags[i].frame_len, fwd_out, write_err_cnt, last_write_errno);
    }
    slot->in_use = 0;
}

static void expire_frag_slots(double now, uint64_t *fwd_out, uint64_t *write_err_cnt, int *last_write_errno) {
    for (int i = 0; i < FRAG_SLOTS; i++) {
        if (g_frag_slots[i].in_use && (now - g_frag_slots[i].created_at >= FRAG_TIMEOUT_SEC)) {
            flush_frag_slot_raw(&g_frag_slots[i], fwd_out, write_err_cnt, last_write_errno);
        }
    }
}

static void reset_frag_slots(void) {
    memset(g_frag_slots, 0, sizeof(g_frag_slots));
}

/* 处理分片 UDP 9296 LaunchSpec：集齐分片后在连续区改写并按原分片边界回填，失败则原样转发以免断流 */
static void handle_fragmented_udp_out(
    uint8_t *pkt, size_t frame_len, struct ip_header *ip, size_t ip_hl, size_t ip_tot,
    double now, const char *profile_num,
    uint8_t seen_seqs[MAX_SEEN_SEQS][8], int *unique_seqs,
    int *first_mutated_announced, double *first_mutated_at,
    ConfirmationState *conf, double *streaminfo_at,
    uint64_t *unmatched_9296_large_out, char *first_unmatched_diag, size_t diag_cap,
    uint64_t *fwd_out, uint64_t *write_err_cnt, int *last_write_errno
) {
    uint16_t frag_raw = ntohs(ip->frag_off);
    size_t frag_off_bytes = (size_t)(frag_raw & 0x1FFF) * 8;
    int more_frags = (frag_raw & 0x2000) ? 1 : 0;
    size_t payload_len = ip_tot - ip_hl;

    if (frame_len > FRAG_MAX_FRAME_LEN || frag_off_bytes + payload_len > FRAG_ASSEMBLE_CAP) {
        forward_out_frame(pkt, frame_len, fwd_out, write_err_cnt, last_write_errno);
        return;
    }

    FragReassemblySlot *slot = NULL;
    int free_idx = -1;
    int oldest_idx = 0;
    for (int i = 0; i < FRAG_SLOTS; i++) {
        if (g_frag_slots[i].in_use) {
            if (g_frag_slots[i].saddr == ip->saddr &&
                g_frag_slots[i].daddr == ip->daddr &&
                g_frag_slots[i].ip_id == ip->id &&
                g_frag_slots[i].proto == ip->proto) {
                slot = &g_frag_slots[i];
                break;
            }
            if (g_frag_slots[i].created_at < g_frag_slots[oldest_idx].created_at) {
                oldest_idx = i;
            }
        } else if (free_idx < 0) {
            free_idx = i;
        }
    }

    if (!slot) {
        int idx = (free_idx >= 0) ? free_idx : oldest_idx;
        if (g_frag_slots[idx].in_use) {
            flush_frag_slot_raw(&g_frag_slots[idx], fwd_out, write_err_cnt, last_write_errno);
        }
        slot = &g_frag_slots[idx];
        memset(slot, 0, sizeof(*slot));
        slot->in_use = 1;
        slot->saddr = ip->saddr;
        slot->daddr = ip->daddr;
        slot->ip_id = ip->id;
        slot->proto = ip->proto;
        slot->created_at = now;
    }

    if (slot->non_9296) {
        forward_out_frame(pkt, frame_len, fwd_out, write_err_cnt, last_write_errno);
        return;
    }

    if (frag_off_bytes == 0 && payload_len >= sizeof(struct udp_header)) {
        struct udp_header *uh = (struct udp_header *)((uint8_t *)ip + ip_hl);
        if (ntohs(uh->dest) == 9296) {
            slot->is_udp_9296 = 1;
        } else {
            slot->non_9296 = 1;
            flush_frag_slot_raw(slot, fwd_out, write_err_cnt, last_write_errno);
            forward_out_frame(pkt, frame_len, fwd_out, write_err_cnt, last_write_errno);
            return;
        }
    }

    if (slot->frag_count >= MAX_FRAGS_PER_PKT) {
        flush_frag_slot_raw(slot, fwd_out, write_err_cnt, last_write_errno);
        forward_out_frame(pkt, frame_len, fwd_out, write_err_cnt, last_write_errno);
        return;
    }

    int fi = slot->frag_count++;
    memcpy(slot->frags[fi].frame, pkt, frame_len);
    slot->frags[fi].frame_len = frame_len;
    slot->frags[fi].ip_hl = ip_hl;
    slot->frags[fi].frag_off_bytes = frag_off_bytes;
    slot->frags[fi].payload_len = payload_len;
    slot->frags[fi].more_frags = more_frags;
    debug_log("frag slot id=0x%04x idx=%d off=%zu plen=%zu MF=%d",
              ntohs(ip->id), fi, frag_off_bytes, payload_len, more_frags);

    if (!more_frags) {
        slot->has_last = 1;
        slot->expected_ip_payload_len = frag_off_bytes + payload_len;
    }

    if (!slot->has_last || !slot->is_udp_9296 || slot->expected_ip_payload_len < sizeof(struct udp_header)) {
        return;
    }

    /* 按偏移排序检查是否连续覆盖 [0, expected_ip_payload_len) */
    for (int a = 0; a < slot->frag_count - 1; a++) {
        for (int b = a + 1; b < slot->frag_count; b++) {
            if (slot->frags[b].frag_off_bytes < slot->frags[a].frag_off_bytes) {
                __typeof__(slot->frags[0]) tmp = slot->frags[a];
                slot->frags[a] = slot->frags[b];
                slot->frags[b] = tmp;
            }
        }
    }

    size_t cursor = 0;
    for (int i = 0; i < slot->frag_count; i++) {
        if (slot->frags[i].frag_off_bytes != cursor) return;
        cursor += slot->frags[i].payload_len;
    }
    if (cursor != slot->expected_ip_payload_len) return;

    uint8_t assembled[FRAG_ASSEMBLE_CAP];
    for (int i = 0; i < slot->frag_count; i++) {
        size_t off = slot->frags[i].frag_off_bytes;
        size_t plen = slot->frags[i].payload_len;
        memcpy(assembled + off,
               slot->frags[i].frame + sizeof(struct eth_header) + slot->frags[i].ip_hl,
               plen);
    }

    struct udp_header *udp = (struct udp_header *)assembled;
    size_t udp_len = ntohs(udp->len);
    if (udp_len >= sizeof(struct udp_header) && udp_len <= slot->expected_ip_payload_len) {
        uint8_t *payload = assembled + sizeof(struct udp_header);
        size_t udp_payload_len = udp_len - sizeof(struct udp_header);
        if (udp_payload_len >= 32) {
            char diag_buf[160] = "";
            if (g_debug_mode) {
                char hex_buf[128];
                debug_hex_prefix(payload, udp_payload_len, hex_buf, sizeof(hex_buf));
                debug_log("frag reassembled UDP/9296 id=0x%04x frags=%d payload_len=%zu hex=[%s]",
                          ntohs(slot->ip_id), slot->frag_count, udp_payload_len, hex_buf);
            }
            if (mutate_launchspec(payload, udp_payload_len, profile_num, udp_payload_len >= 1000 ? diag_buf : NULL, sizeof(diag_buf))) {
                udp->check = 0;
                udp->check = htons(udp_checksum_raw(slot->saddr, slot->daddr, assembled, udp_len));

                /* 原位回填每一片 UDP 数据并重算各自 IP 校验和 */
                for (int i = 0; i < slot->frag_count; i++) {
                    uint8_t *dst_frame = slot->frags[i].frame;
                    struct ip_header *fip = (struct ip_header *)(dst_frame + sizeof(struct eth_header));
                    memcpy(dst_frame + sizeof(struct eth_header) + slot->frags[i].ip_hl,
                           assembled + slot->frags[i].frag_off_bytes,
                           slot->frags[i].payload_len);
                    fip->check = 0;
                    fip->check = htons(calc_checksum(fip, slot->frags[i].ip_hl));
                }

                uint8_t seq_key[8];
                memcpy(seq_key, payload + 1, 4);
                memcpy(seq_key + 4, payload + 17, 4);
                int already_seen = 0;
                for (int s = 0; s < *unique_seqs && s < MAX_SEEN_SEQS; s++) {
                    if (memcmp(seen_seqs[s], seq_key, 8) == 0) {
                        already_seen = 1;
                        break;
                    }
                }
                if (!already_seen) {
                    if (*unique_seqs < MAX_SEEN_SEQS) {
                        memcpy(seen_seqs[*unique_seqs], seq_key, 8);
                    }
                    (*unique_seqs)++;
                    if (conf) {
                        conf->armed = 1;
                        conf->accepted = 0;
                        conf->streaming = 0;
                        conf->samples = 0;
                    }
                    if (streaminfo_at) *streaminfo_at = 0.0;
                }
                if (!(*first_mutated_announced)) {
                    *first_mutated_announced = 1;
                    *first_mutated_at = now;
                    printf("[注入] 🎯 已重组分片并修改 LaunchSpec 握手参数为 %s Mbps！\n", profile_num);
                    fflush(stdout);
                }
            } else if (udp_payload_len >= 1000) {
                (*unmatched_9296_large_out)++;
                if (first_unmatched_diag && !first_unmatched_diag[0] && diag_buf[0]) {
                    snprintf(first_unmatched_diag, diag_cap, "%s", diag_buf);
                }
                debug_log("frag UDP/9296 missed LaunchSpec: %s", diag_buf[0] ? diag_buf : "no_diag");
            }
        }
    }

    flush_frag_slot_raw(slot, fwd_out, write_err_cnt, last_write_errno);
}

int main(int argc, char *argv[]) {
    setvbuf(stdout, NULL, _IOLBF, 0);

    char ps5_ip_str[64] = "";
    char portal_ip_str[64] = "";
    char bitrate_arg[32] = "100M";
    int restore_only = 0;
    int check_privilege = 0;
    int stop_existing = 0;
    int do_install_sudoers = 0;
    int clamshell_cmd = -1;

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
        } else if (strcmp(argv[i], "--watch") == 0) {
            g_watch_mode = 1;
            g_mode_oneway = 1;
        } else if (strcmp(argv[i], "--debug") == 0) {
            g_debug_mode = 1;
        } else if (strcmp(argv[i], "--parent-pid") == 0 && i + 1 < argc) {
            long p = strtol(argv[++i], NULL, 10);
            if (p > 1) g_parent_pid = (pid_t)p;
        } else if (strcmp(argv[i], "--restore") == 0) {
            restore_only = 1;
        } else if (strcmp(argv[i], "--check-privilege") == 0) {
            check_privilege = 1;
        } else if (strcmp(argv[i], "--stop") == 0) {
            stop_existing = 1;
        } else if (strcmp(argv[i], "--install-sudoers") == 0) {
            do_install_sudoers = 1;
        } else if (strcmp(argv[i], "--clamshell-keepawake") == 0 && i + 1 < argc) {
            const char *mode = argv[++i];
            if (strcmp(mode, "on") == 0) clamshell_cmd = 1;
            else if (strcmp(mode, "off") == 0) clamshell_cmd = 0;
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

    if (clamshell_cmd >= 0) {
        if (geteuid() != 0) {
            printf("[错误] ❌ 需要管理员特权 (UID=0) 才能修改系统休眠开关。\n");
            fflush(stdout);
            return 1;
        }
        return set_clamshell_keepawake(clamshell_cmd) == 0 ? 0 : 1;
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
            char pid_path[PROC_PIDPATHINFO_MAXSIZE] = "";
            int path_len = proc_pidpath((pid_t)pid, pid_path, sizeof(pid_path));
            const char *base = (path_len > 0) ? strrchr(pid_path, '/') : NULL;
            int is_portal_proc = (path_len > 0 && ((base && strcmp(base, "/portal_engine") == 0) || strcmp(pid_path, "portal_engine") == 0));

            if (is_portal_proc && kill((pid_t)pid, SIGINT) == 0) {
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
            } else {
                unlink(PID_FILE);
            }
        } else {
            unlink(PID_FILE);
        }
        restore_clamshell_keepawake_if_marked();
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

    char ps5_route_iface[64] = "";
    char portal_route_iface[64] = "";
    int ps5_has_gw = 0, portal_has_gw = 0;
    int ps5_route_err = check_route_for_ip("PS5", ps5_ip_str, g_iface, ps5_route_iface, sizeof(ps5_route_iface), &ps5_has_gw);
    int portal_route_err = check_route_for_ip("PS Portal", portal_ip_str, g_iface, portal_route_iface, sizeof(portal_route_iface), &portal_has_gw);
    if (g_watch_mode && (ps5_route_err != 0 || portal_route_err != 0)) {
        emit_event("{\"type\":\"state\",\"state\":\"out_of_lan\",\"reason\":\"route_mismatch\"}");
        fflush(stdout);
        unlink(PID_FILE);
        return 2;
    }

    if (!g_watch_mode) {
        ping_hosts_parallel(ps5_ip_str, portal_ip_str);
        if (ps5_ip_str[0] && resolve_mac_via_arp(ps5_ip_str, g_iface, g_ps5_mac, 0) == 0) {
            g_has_ps5_mac = 1;
        }
        if (portal_ip_str[0] && resolve_mac_via_arp(portal_ip_str, g_iface, g_portal_mac, 0) == 0) {
            g_has_portal_mac = 1;
        }
    }

    char own_ip_buf[16], own_mac_buf[18], ps5_mac_buf[18], portal_mac_buf[18];
    format_ip_str(g_own_ip, own_ip_buf);
    format_mac_str(g_own_mac, own_mac_buf);
    if (g_has_ps5_mac) format_mac_str(g_ps5_mac, ps5_mac_buf);
    if (g_has_portal_mac) format_mac_str(g_portal_mac, portal_mac_buf);

    printf("[诊断] 网卡 %s (%s | MAC %s) | 模式: %s\n",
           g_iface, own_ip_buf, own_mac_buf,
           g_watch_mode ? "被动旁路守望 (watch/oneway)" : (g_mode_oneway ? "单向视频直连 (oneway)" : "双向遥测验证 (twoway)"));
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
    if (!g_watch_mode && (!g_has_ps5_mac || !g_has_portal_mac)) {
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

    g_engine_t0 = monotonic_seconds();
    debug_log("引擎初始化完成: iface=%s watch=%d mode=%s bitrate=%s bpf_fd=%d route_ps5=%s(gw=%d) route_portal=%s(gw=%d)",
              g_iface, g_watch_mode, g_mode_oneway ? "oneway" : "twoway", profile_num, g_bpf_fd,
              ps5_route_iface[0] ? ps5_route_iface : "?", ps5_has_gw,
              portal_route_iface[0] ? portal_route_iface : "?", portal_has_gw);

    if (!g_watch_mode) {
        disable_kernel_ip_bypass();
    }

    uint8_t *bpf_buffer = malloc(BPF_BUF_LEN);
    if (!bpf_buffer) {
        restore_network_state(0);
        printf("[错误] ❌ 内存分配失败。\n");
        return 1;
    }

    enum WatchPhase {
        WATCH_IDLE = 0,
        WATCH_PREFLIGHT = 1,
        WATCH_ACTIVE_BURST = 2
    };

    enum WatchPhase watch_phase = g_watch_mode ? WATCH_IDLE : WATCH_ACTIVE_BURST;
    double start_ts = monotonic_seconds();
    double ready_at = start_ts + 1.5;
    double end_ts = start_ts + 121.5;
    double next_arp = 0.0;
    double preflight_deadline = 0.0;
    double preflight_next_probe = 0.0;
    double burst_deadline = 0.0;
    double watch_cooldown_until = 0.0;
    double last_portal_seen_at = -1000.0;
    double last_parent_check_at = start_ts;
    int ps5_liveness_ok = 0;

    double first_mutated_at = 0.0;
    double streaminfo_at = 0.0;
    int ready_announced = 0;
    int first_mutated_announced = 0;
    int first_out_seen = 0;
    int first_in_seen = 0;
    int spoof_started_announced = 0;
    int early_direct_handoff = 0;
    int mac_conflict_aborted = 0;
    int frag_info_announced = 0;
    int ps5_mac_logged = 0;
    int portal_mac_logged = 0;
    int cooldown_notify_pending = 0;

    uint64_t fwd_in = 0;
    uint64_t fwd_out = 0;
    uint64_t write_err_cnt = 0;
    uint64_t unmatched_9296_large_out = 0;
    uint64_t debug_udp9296_out_cnt = 0;
    uint64_t debug_arp_seen_cnt = 0;
    char first_unmatched_diag[160] = "";
    int last_write_errno = 0;
    int first_tcp9295_logged = 0;
    uint8_t seen_seqs[MAX_SEEN_SEQS][8];
    int unique_seqs = 0;

    static const uint8_t BROADCAST_MAC[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    static const uint8_t ZERO_MAC[6] = { 0, 0, 0, 0, 0, 0 };

    ConfirmationState conf;
    memset(&conf, 0, sizeof(conf));
    conf.confirm_threshold = confirm_target;

    if (g_watch_mode) {
        emit_event("{\"type\":\"state\",\"state\":\"watching\"}");
        printf("----------------------------------------------------------------------\n");
        printf("[就绪] 🟢 自动守望已就绪！现在随时可唤醒 PS Portal 并点击连接 PS5。\n");
        fflush(stdout);
    }

    while (g_running) {
        double now = monotonic_seconds();

        if (g_parent_pid > 1 && (now - last_parent_check_at >= 2.0)) {
            last_parent_check_at = now;
            if (kill(g_parent_pid, 0) != 0 && errno == ESRCH) {
                printf("[守望] ℹ️ 主进程 (PID %d) 已退出，正在安全回收引擎。\n", (int)g_parent_pid);
                fflush(stdout);
                break;
            }
        }

        expire_frag_slots(now, &fwd_out, &write_err_cnt, &last_write_errno);

        if (!g_watch_mode) {
            if (now >= end_ts) break;
            if (g_mode_oneway && first_mutated_announced && first_mutated_at > 0.0 && (now - first_mutated_at >= 3.0)) {
                break;
            }
            if (!g_mode_oneway && conf.accepted && conf.streaming && streaminfo_at > 0.0 && (now - streaminfo_at >= 5.0)) {
                early_direct_handoff = 1;
                break;
            }
        } else {
            if (watch_phase == WATCH_IDLE && cooldown_notify_pending && now >= watch_cooldown_until) {
                cooldown_notify_pending = 0;
                emit_event("{\"type\":\"cooldown_ended\"}");
                printf("[就绪] 🟢 冷却已结束，现在随时可唤醒 PS Portal 并点击连接 PS5。\n");
                fflush(stdout);
            }
            if (watch_phase == WATCH_PREFLIGHT) {
                if (ps5_liveness_ok && g_has_ps5_mac && g_has_portal_mac) {
                    watch_phase = WATCH_ACTIVE_BURST;
                    burst_deadline = now + 120.0;
                    next_arp = 0.0;
                    first_mutated_announced = 0;
                    first_mutated_at = 0.0;
                    first_out_seen = 0;
                    spoof_started_announced = 0;
                    unique_seqs = 0;
                    frag_info_announced = 0;
                    unmatched_9296_large_out = 0;
                    debug_udp9296_out_cnt = 0;
                    first_tcp9295_logged = 0;
                    first_unmatched_diag[0] = '\0';
                    cooldown_notify_pending = 0;
                    reset_frag_slots();
                    disable_kernel_ip_bypass();
                    emit_event("{\"type\":\"state\",\"state\":\"bursting\",\"seconds\":120}");
                    debug_log("WATCH_PREFLIGHT -> WATCH_ACTIVE_BURST (ps5_alive=1 ps5_mac=1 portal_mac=1)");
                    printf("----------------------------------------------------------------------\n");
                    printf("[指引] 🎮 已检测到 Portal 唤醒并开启增强通道！请在 120 秒内于 Portal 上点击「连接 PS5」。\n");
                    fflush(stdout);
                } else if (now >= preflight_deadline) {
                    watch_phase = WATCH_IDLE;
                    watch_cooldown_until = now + 3.0;
                    debug_log("WATCH_PREFLIGHT 超时(2.0s): ps5_alive=%d has_ps5_mac=%d has_portal_mac=%d -> 退回 WATCH_IDLE(3s冷却)",
                              ps5_liveness_ok, g_has_ps5_mac, g_has_portal_mac);
                    printf("[守望] 💤 PS5 未在 2 秒内响应在线预检，退回静默待命（有新连接流量时可立即重试）。\n");
                    fflush(stdout);
                } else if (now >= preflight_next_probe && g_ps5_ip) {
                    const uint8_t *dst_mac = g_has_ps5_mac ? g_ps5_mac : BROADCAST_MAC;
                    send_arp_raw(g_bpf_fd, dst_mac, g_own_mac, 1, g_own_mac, g_own_ip, ZERO_MAC, g_ps5_ip);
                    if (!g_has_portal_mac && g_portal_ip) {
                        send_arp_raw(g_bpf_fd, BROADCAST_MAC, g_own_mac, 1, g_own_mac, g_own_ip, ZERO_MAC, g_portal_ip);
                    }
                    debug_log("WATCH_PREFLIGHT 探测发送: ps5_alive=%d ps5_mac=%d portal_mac=%d",
                              ps5_liveness_ok, g_has_ps5_mac, g_has_portal_mac);
                    preflight_next_probe = now + 0.25;
                }
            } else if (watch_phase == WATCH_ACTIVE_BURST) {
                int burst_done = 0;
                const char *burst_res = "timeout";
                if (first_mutated_announced) {
                    if (first_mutated_at > 0.0 && (now - first_mutated_at >= 3.0)) {
                        burst_done = 1;
                        burst_res = "enhanced";
                    }
                } else if (now >= burst_deadline) {
                    burst_done = 1;
                    burst_res = "timeout";
                }
                if (burst_done) {
                    restore_arp_to_direct(0);
                    reset_frag_slots();
                    watch_phase = WATCH_IDLE;
                    watch_cooldown_until = now + 20.0;
                    if (strcmp(burst_res, "enhanced") == 0) {
                        cooldown_notify_pending = 0;
                        emit_event("{\"type\":\"state\",\"state\":\"watching\",\"result\":\"enhanced\"}");
                        printf("[成功] 🎉 已为本次串流开启 %s Mbps 高画质（修改 %d 个启动包 · 视频直连不经 Mac），现在可以正常游玩！\n",
                               profile_num, unique_seqs);
                    } else {
                        cooldown_notify_pending = 1;
                        emit_event("{\"type\":\"state\",\"state\":\"watching\",\"result\":\"timeout\",\"cooldown\":20}");
                        printf("[守望] ⏸ 本轮 120 秒窗口内暂未收到连接握手，已恢复直连路由。请等待 20 秒冷却结束后再用 Portal 连接。\n");
                        if (unmatched_9296_large_out > 0) {
                            printf("[诊断] 💡 窗口内捕获到 %llu 个 UDP/9296 大载荷包但未命中 LaunchSpec 模板 (%s)。\n",
                                   (unsigned long long)unmatched_9296_large_out,
                                   first_unmatched_diag[0] ? first_unmatched_diag : "未知原因");
                        }
                    }
                    fflush(stdout);
                }
            }
        }

        if (watch_phase == WATCH_ACTIVE_BURST && now >= next_arp) {
            if (!g_has_ps5_mac && g_ps5_ip) {
                send_arp_raw(g_bpf_fd, BROADCAST_MAC, g_own_mac, 1, g_own_mac, g_own_ip, ZERO_MAC, g_ps5_ip);
                debug_log("ACTIVE_BURST 广播 ARP 探测 PS5 MAC");
            }
            if (!g_has_portal_mac && g_portal_ip) {
                send_arp_raw(g_bpf_fd, BROADCAST_MAC, g_own_mac, 1, g_own_mac, g_own_ip, ZERO_MAC, g_portal_ip);
                debug_log("ACTIVE_BURST 广播 ARP 探测 Portal MAC");
            }
            if (g_has_ps5_mac && g_has_portal_mac && g_ps5_ip && g_portal_ip) {
                if (validate_distinct_macs() != 0) {
                    printf("[错误] ❌ 检测到设备 MAC 冲突（Mac / PS5 / Portal 存在相同 MAC），已中止中继以保护网络！\n");
                    fflush(stdout);
                    if (g_watch_mode) {
                        restore_arp_to_direct(0);
                        watch_phase = WATCH_IDLE;
                        watch_cooldown_until = now + 60.0;
                        emit_event("{\"type\":\"error\",\"code\":\"mac_conflict\"}");
                    } else {
                        mac_conflict_aborted = 1;
                        break;
                    }
                } else {
                    if (!spoof_started_announced) {
                        spoof_started_announced = 1;
                        g_spoof_active = 1;
                        save_restore_state();
                        printf("[诊断] ✅ 双方 MAC 已就绪，已启动%s。\n",
                               g_mode_oneway ? "单向 ARP 牵引" : "双向 ARP 中继牵引");
                        fflush(stdout);
                    }
                    send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_own_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
                    if (!g_mode_oneway) {
                        send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_own_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
                    }
                    debug_log("周期发送 ARP 牵引 (op=2 -> Portal%s)", g_mode_oneway ? "" : " & PS5");
                }
            }
            next_arp = now + ((g_has_ps5_mac && g_has_portal_mac) ? 1.0 : 0.20);
        }

        if (!g_watch_mode && !ready_announced && now >= ready_at) {
            ready_announced = 1;
            emit_event("{\"type\":\"state\",\"state\":\"listening\"}");
            printf("----------------------------------------------------------------------\n");
            printf("[就绪] 🎮 增强通道已就绪！现在请在 120 秒内于 PS Portal 上点击连接 PS5。\n");
            fflush(stdout);
        }

        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(g_bpf_fd, &read_fds);
        struct timeval tv = { 0, (watch_phase == WATCH_IDLE) ? 200000 : 50000 };

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

            if (memcmp(eth->src, g_own_mac, 6) == 0) continue;

            if (ntohs(eth->ethertype) == 0x0806 && pkt_len >= sizeof(struct eth_header) + sizeof(struct arp_header)) {
                struct arp_header *arp = (struct arp_header *)(pkt + sizeof(struct eth_header));
                uint16_t arp_op = ntohs(arp->op);

                if (g_ps5_ip && arp->spa == g_ps5_ip && memcmp(arp->sha, g_own_mac, 6) != 0) {
                    ps5_liveness_ok = 1;
                    if (!g_has_ps5_mac || memcmp(g_ps5_mac, arp->sha, 6) != 0) {
                        memcpy(g_ps5_mac, arp->sha, 6);
                        g_has_ps5_mac = 1;
                        ps5_mac_logged = 0;
                    }
                    if (!ps5_mac_logged) {
                        char mac_s[18];
                        ps5_mac_logged = 1;
                        format_mac_str(g_ps5_mac, mac_s);
                        printf("[诊断] 📡 捕获 PS5 MAC: %s\n", mac_s);
                        fflush(stdout);
                    }
                    if (g_has_portal_mac && watch_phase == WATCH_ACTIVE_BURST) next_arp = 0.0;
                }
                if (g_portal_ip && arp->spa == g_portal_ip && memcmp(arp->sha, g_own_mac, 6) != 0) {
                    if (!g_has_portal_mac || memcmp(g_portal_mac, arp->sha, 6) != 0) {
                        memcpy(g_portal_mac, arp->sha, 6);
                        g_has_portal_mac = 1;
                        portal_mac_logged = 0;
                    }
                    if (!portal_mac_logged) {
                        char mac_s[18];
                        portal_mac_logged = 1;
                        format_mac_str(g_portal_mac, mac_s);
                        printf("[诊断] 📡 捕获 Portal MAC: %s\n", mac_s);
                        fflush(stdout);
                    }
                    if (g_has_ps5_mac && watch_phase == WATCH_ACTIVE_BURST) next_arp = 0.0;
                }

                int is_portal_src = (g_portal_ip && arp->spa == g_portal_ip);
                int is_ps5_src = (g_ps5_ip && arp->spa == g_ps5_ip);
                if (g_debug_mode && (is_portal_src || is_ps5_src || (g_ps5_ip && arp->tpa == g_ps5_ip) || (g_portal_ip && arp->tpa == g_portal_ip)) && debug_arp_seen_cnt < 120) {
                    debug_arp_seen_cnt++;
                    char sha_s[18], spa_s[16], tpa_s[16];
                    format_mac_str(arp->sha, sha_s);
                    format_ip_str(arp->spa, spa_s);
                    format_ip_str(arp->tpa, tpa_s);
                    debug_log("RX ARP op=%u (%s) sha=%s spa=%s -> tpa=%s phase=%d",
                              arp_op, arp_op == 1 ? "Who-Has" : (arp_op == 2 ? "Reply" : "Other"),
                              sha_s, spa_s, tpa_s, (int)watch_phase);
                }

                if (g_watch_mode && watch_phase == WATCH_IDLE) {
                    int strong_arp = (arp_op == 1 && is_portal_src && arp->tpa == g_ps5_ip);
                    int wifi_wake = (arp_op == 1 && is_portal_src && (last_portal_seen_at < 0.0 || (now - last_portal_seen_at >= 60.0)));
                    if (is_portal_src) last_portal_seen_at = now;
                    if (strong_arp || (wifi_wake && now >= watch_cooldown_until)) {
                        watch_phase = WATCH_PREFLIGHT;
                        ps5_liveness_ok = 0;
                        preflight_deadline = now + 2.0;
                        preflight_next_probe = 0.0;
                        debug_log("ARP 触发 WATCH_PREFLIGHT (strong_arp=%d wifi_wake=%d)", strong_arp, wifi_wake);
                        printf("[守望] 🔍 捕获 %s，正在 2 秒内预检 PS5 在线状态...\n",
                               strong_arp ? "Portal ARP 请求 PS5" : "Portal Wi-Fi 唤醒信号");
                        fflush(stdout);
                    }
                } else if (is_portal_src) {
                    last_portal_seen_at = now;
                }

                /* 抢占应答目标 ARP（同时覆盖 Who-Has op=1 与 Reply/无故 ARP op=2，含 tpa=0 RFC5227），防止真实对端覆盖欺骗条目 */
                if (watch_phase == WATCH_ACTIVE_BURST && g_has_ps5_mac && g_has_portal_mac &&
                    validate_distinct_macs() == 0 && (arp_op == 1 || arp_op == 2)) {
                    if (arp->spa == g_portal_ip && arp->tpa == g_ps5_ip) {
                        send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_own_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
                        send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_own_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
                        debug_log("⚡ ARP 抢占回击 Portal (来源 Portal 请求/通告 PS5, op=%u)", arp_op);
                    } else if (arp->spa == g_ps5_ip && (arp->tpa == g_portal_ip || arp->tpa == g_ps5_ip || arp->tpa == 0)) {
                        send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_own_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
                        send_arp_raw(g_bpf_fd, g_portal_mac, g_own_mac, 2, g_own_mac, g_ps5_ip, g_portal_mac, g_portal_ip);
                        debug_log("⚡ ARP 抢占反制 Portal (来源 PS5 op=%u, 防止覆盖欺骗表项)", arp_op);
                        if (!g_mode_oneway && arp->tpa == g_portal_ip) {
                            send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_own_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
                            send_arp_raw(g_bpf_fd, g_ps5_mac, g_own_mac, 2, g_own_mac, g_portal_ip, g_ps5_mac, g_ps5_ip);
                        }
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

            if (g_portal_ip && ip->saddr == g_portal_ip && !g_has_portal_mac) {
                if (!g_has_ps5_mac || memcmp(eth->src, g_ps5_mac, 6) != 0) {
                    memcpy(g_portal_mac, eth->src, 6);
                    g_has_portal_mac = 1;
                    portal_mac_logged = 1;
                    char mac_s[18];
                    format_mac_str(g_portal_mac, mac_s);
                    printf("[诊断] 📡 从 IPv4 流量捕获 Portal MAC: %s\n", mac_s);
                    fflush(stdout);
                    if (g_has_ps5_mac && watch_phase == WATCH_ACTIVE_BURST) next_arp = 0.0;
                }
            }
            if (g_ps5_ip && ip->saddr == g_ps5_ip && !g_has_ps5_mac) {
                if (!g_has_portal_mac || memcmp(eth->src, g_portal_mac, 6) != 0) {
                    memcpy(g_ps5_mac, eth->src, 6);
                    g_has_ps5_mac = 1;
                    ps5_mac_logged = 1;
                    char mac_s[18];
                    format_mac_str(g_ps5_mac, mac_s);
                    printf("[诊断] 📡 从 IPv4 流量捕获 PS5 MAC: %s\n", mac_s);
                    fflush(stdout);
                    if (g_has_portal_mac && watch_phase == WATCH_ACTIVE_BURST) next_arp = 0.0;
                }
            }

            if (g_watch_mode && watch_phase != WATCH_ACTIVE_BURST) {
                /* 旁路守望或预检窗口：识别 UDP 9302/67/9296 与 TCP 9295 触发信号，严禁篡改/转发任何业务包 */
                int src_is_portal = (g_portal_ip && ip->saddr == g_portal_ip);
                int src_is_ps5 = (g_ps5_ip && ip->saddr == g_ps5_ip);
                if (src_is_ps5 && watch_phase == WATCH_PREFLIGHT) {
                    ps5_liveness_ok = 1;
                }
                if (ip->proto == IPPROTO_UDP && (ntohs(ip->frag_off) & 0x1FFF) == 0 && ip_tot >= ip_hl + sizeof(struct udp_header)) {
                    struct udp_header *udp = (struct udp_header *)((uint8_t *)ip + ip_hl);
                    uint16_t dport = ntohs(udp->dest);
                    if (watch_phase == WATCH_IDLE) {
                        int ddp_trigger = (dport == 9302 && (src_is_portal || ip->daddr == g_ps5_ip));
                        int dhcp_wake = (dport == 67 && src_is_portal && (last_portal_seen_at < 0.0 || (now - last_portal_seen_at >= 60.0)));
                        int takion_trigger = (dport == 9296 && src_is_portal && g_ps5_ip && ip->daddr == g_ps5_ip);
                        if (src_is_portal) last_portal_seen_at = now;
                        if (takion_trigger || ((ddp_trigger || dhcp_wake) && now >= watch_cooldown_until)) {
                            watch_phase = WATCH_PREFLIGHT;
                            ps5_liveness_ok = 0;
                            preflight_deadline = now + 2.0;
                            preflight_next_probe = 0.0;
                            debug_log("UDP/%u 触发 WATCH_PREFLIGHT (ddp=%d dhcp=%d takion=%d)",
                                      dport, ddp_trigger, dhcp_wake, takion_trigger);
                            printf("[守望] 🔍 捕获 %s，正在 2 秒内预检 PS5 在线状态...\n",
                                   takion_trigger ? "UDP/9296 握手流量" : (ddp_trigger ? "UDP/9302 DDP 探测" : "Portal DHCP 联网唤醒"));
                            fflush(stdout);
                        }
                    } else if (src_is_portal) {
                        last_portal_seen_at = now;
                    }
                } else if (ip->proto == IPPROTO_TCP && (ntohs(ip->frag_off) & 0x1FFF) == 0 && ip_tot >= ip_hl + 4) {
                    const uint8_t *tcp_bytes = (const uint8_t *)ip + ip_hl;
                    uint16_t dport = (uint16_t)(((uint16_t)tcp_bytes[2] << 8) | tcp_bytes[3]);
                    if (watch_phase == WATCH_IDLE &&
                        dport == 9295 && src_is_portal && g_ps5_ip && ip->daddr == g_ps5_ip) {
                        last_portal_seen_at = now;
                        watch_phase = WATCH_PREFLIGHT;
                        ps5_liveness_ok = 0;
                        preflight_deadline = now + 2.0;
                        preflight_next_probe = 0.0;
                        debug_log("TCP/9295 触发 WATCH_PREFLIGHT (无视冷却)");
                        printf("[守望] 🔍 捕获 TCP/9295 Remote Play 会话连接，正在 2 秒内预检 PS5 在线状态...\n");
                        fflush(stdout);
                    } else if (src_is_portal) {
                        last_portal_seen_at = now;
                    }
                }
                continue;
            }

            if (memcmp(eth->dst, g_own_mac, 6) != 0) continue;

            int is_out = (g_portal_ip && g_ps5_ip && ip->saddr == g_portal_ip && ip->daddr == g_ps5_ip);
            int is_in  = (g_portal_ip && g_ps5_ip && ip->saddr == g_ps5_ip && ip->daddr == g_portal_ip);
            if (!is_out && !is_in) continue;

            if (is_out && ip->proto == IPPROTO_UDP && (ntohs(ip->frag_off) & 0x3FFF) != 0) {
                if (!frag_info_announced && (ntohs(ip->frag_off) & 0x1FFF) == 0 && ip_tot >= ip_hl + sizeof(struct udp_header)) {
                    struct udp_header *frag_udp = (struct udp_header *)((uint8_t *)ip + ip_hl);
                    if (ntohs(frag_udp->dest) == 9296) {
                        frag_info_announced = 1;
                        printf("[诊断] 🧩 检测到分片 UDP/9296 握手包，已启用 IP 分片重组注入通道。\n");
                        fflush(stdout);
                    }
                }
                int was_mutated = first_mutated_announced;
                handle_fragmented_udp_out(
                    pkt, sizeof(struct eth_header) + ip_tot, ip, ip_hl, ip_tot,
                    now, profile_num, seen_seqs, &unique_seqs,
                    &first_mutated_announced, &first_mutated_at,
                    &conf, &streaminfo_at,
                    &unmatched_9296_large_out, first_unmatched_diag, sizeof(first_unmatched_diag),
                    &fwd_out, &write_err_cnt, &last_write_errno
                );
                if (!was_mutated && first_mutated_announced) {
                    emit_event("{\"type\":\"stream_enhanced\",\"bitrate\":%s,\"fragmented\":1}", profile_num);
                }
                continue;
            }

            if (g_debug_mode && is_out && ip->proto == IPPROTO_TCP && ip_tot >= ip_hl + 4 && !first_tcp9295_logged) {
                const uint8_t *tcp_b = (const uint8_t *)ip + ip_hl;
                uint16_t tcp_dport = (uint16_t)(((uint16_t)tcp_b[2] << 8) | tcp_b[3]);
                if (tcp_dport == 9295) {
                    first_tcp9295_logged = 1;
                    debug_log("ACTIVE_BURST 捕获首包 TCP/9295 Portal->PS5 (%zu bytes)", ip_tot);
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
                        int should_log_pkt = (g_debug_mode && debug_udp9296_out_cnt < 40);
                        if (should_log_pkt) {
                            debug_udp9296_out_cnt++;
                            char hex_buf[128];
                            debug_hex_prefix(payload, payload_len, hex_buf, sizeof(hex_buf));
                            debug_log("RX UDP/9296 #%llu sport=%u ip_tot=%zu udp_len=%zu plen=%zu hex=[%s]",
                                      (unsigned long long)debug_udp9296_out_cnt, sport, ip_tot, udp_len, payload_len, hex_buf);
                        }
                        if (mutate_launchspec(payload, payload_len, profile_num, (payload_len >= 1000 || g_debug_mode) ? diag_buf : NULL, sizeof(diag_buf))) {
                            udp->check = 0;
                            udp->check = htons(udp_checksum(ip, udp, udp_len));
                            ip->check = 0;
                            ip->check = htons(calc_checksum(ip, ip_hl));

                            uint8_t seq_key[8];
                            memcpy(seq_key, payload + 1, 4);
                            memcpy(seq_key + 4, payload + 17, 4);
                            int already_seen = 0;
                            for (int s = 0; s < unique_seqs && s < MAX_SEEN_SEQS; s++) {
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
                                emit_event("{\"type\":\"stream_enhanced\",\"bitrate\":%s,\"fragmented\":0}", profile_num);
                                printf("[注入] 🎯 截获并修改 LaunchSpec 握手参数为 %s Mbps！\n", profile_num);
                                fflush(stdout);
                            }
                        } else {
                            if (should_log_pkt && diag_buf[0]) {
                                debug_log("UDP/9296 #%llu 未命中 LaunchSpec (%s)",
                                          (unsigned long long)debug_udp9296_out_cnt, diag_buf);
                            }
                            if (payload_len >= 1000) {
                                unmatched_9296_large_out++;
                                if (!first_unmatched_diag[0] && diag_buf[0]) {
                                    snprintf(first_unmatched_diag, sizeof(first_unmatched_diag), "%s", diag_buf);
                                }
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

            if (!g_watch_mode && conf.confirmed) break;
        }

        if (!g_watch_mode && conf.confirmed) break;
    }

    free(bpf_buffer);
    restore_network_state(0);

    if (mac_conflict_aborted) {
        return 1;
    }
    if (g_watch_mode) {
        printf("[守望] 🛑 自动守望进程已停止并彻底复原网络直连。\n");
        fflush(stdout);
        return 0;
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
