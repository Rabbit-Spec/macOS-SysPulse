#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static int has_dotdot_segment(const char *path) {
    if (!path) return 1;
    if (strcmp(path, "..") == 0) return 1;
    if (strncmp(path, "../", 3) == 0) return 1;
    if (strstr(path, "/../") != NULL) return 1;
    size_t len = strlen(path);
    if (len >= 3 && strcmp(path + len - 3, "/..") == 0) return 1;
    return 0;
}

static int run_exec_wait(const char *exe, char *const argv[]) {
    pid_t pid = fork();
    if (pid == 0) {
        execv(exe, argv);
        _exit(127);
    }
    if (pid < 0) return -1;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static int cmd_periodic(void) {
    if (setuid(0) != 0 || seteuid(0) != 0) return 1;
    if (access("/usr/sbin/periodic", X_OK) != 0) {
        return 0;
    }
    char *const argv[] = { "/usr/sbin/periodic", "daily", "weekly", "monthly", NULL };
    execv("/usr/sbin/periodic", argv);
    return 127;
}

static int cmd_repair_permissions(const char *uid_str, uid_t caller_uid) {
    if (!uid_str || uid_str[0] == '\0') return 2;
    for (const char *p = uid_str; *p != '\0'; p++) {
        if (*p < '0' || *p > '9') return 2;
    }
    char *endptr = NULL;
    unsigned long parsed = strtoul(uid_str, &endptr, 10);
    if (!endptr || *endptr != '\0' || parsed < 501 || parsed >= 65534) {
        return 2;
    }
    if (caller_uid >= 501 && (uid_t)parsed != caller_uid) {
        return 3;
    }
    if (setuid(0) != 0 || seteuid(0) != 0) return 1;
    char *const argv[] = { "/usr/sbin/diskutil", "resetUserPermissions", "/", (char *)uid_str, NULL };
    execv("/usr/sbin/diskutil", argv);
    return 127;
}

static int cmd_purge(void) {
    if (setuid(0) != 0 || seteuid(0) != 0) return 1;
    char *const argv[] = { "/usr/sbin/purge", NULL };
    execv("/usr/sbin/purge", argv);
    return 127;
}

static int cmd_flush_mdns(void) {
    if (setuid(0) != 0 || seteuid(0) != 0) return 1;
    char *const argv[] = { "/usr/bin/killall", "-HUP", "mDNSResponder", NULL };
    execv("/usr/bin/killall", argv);
    return 127;
}

static int cmd_remove_broken_symlink(const char *path) {
    if (!path || has_dotdot_segment(path)) return 2;

    static const char *const allowed_prefixes[] = {
        "/usr/local/bin/",
        "/usr/local/sbin/",
        "/opt/homebrew/bin/",
        "/opt/homebrew/sbin/"
    };
    const char *rest = NULL;
    for (size_t i = 0; i < sizeof(allowed_prefixes) / sizeof(allowed_prefixes[0]); i++) {
        size_t plen = strlen(allowed_prefixes[i]);
        if (strncmp(path, allowed_prefixes[i], plen) == 0) {
            rest = path + plen;
            break;
        }
    }
    if (!rest || rest[0] == '\0' || strchr(rest, '/') != NULL) {
        return 2;
    }

    struct stat l_st;
    if (lstat(path, &l_st) != 0 || !S_ISLNK(l_st.st_mode)) {
        return 3;
    }

    struct stat target_st;
    if (stat(path, &target_st) == 0 || errno != ENOENT) {
        return 4;
    }

    char target_buf[PATH_MAX];
    ssize_t n = readlink(path, target_buf, sizeof(target_buf) - 1);
    if (n <= 0) return 4;
    target_buf[n] = '\0';
    if (strstr(target_buf, ".app/") == NULL) {
        return 5;
    }

    if (setuid(0) != 0 || seteuid(0) != 0) return 1;
    return unlink(path) == 0 ? 0 : 1;
}

static int copy_and_unlink_file(const char *src, const char *dst) {
    int in_fd = open(src, O_RDONLY | O_NOFOLLOW);
    if (in_fd < 0) return -1;

    int out_fd = open(dst, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (out_fd < 0) {
        close(in_fd);
        return -1;
    }

    char buf[8192];
    ssize_t r;
    int err = 0;
    while ((r = read(in_fd, buf, sizeof(buf))) > 0) {
        ssize_t written = 0;
        while (written < r) {
            ssize_t w = write(out_fd, buf + written, (size_t)(r - written));
            if (w <= 0) {
                err = 1;
                break;
            }
            written += w;
        }
        if (err) break;
    }
    if (r < 0) err = 1;

    close(in_fd);
    if (close(out_fd) != 0) err = 1;

    if (err) {
        unlink(dst);
        return -1;
    }
    if (unlink(src) != 0) {
        unlink(dst);
        return -1;
    }
    return 0;
}

static int cmd_trash_broken_system_agent(const char *plist_path, const char *trash_dest, uid_t caller_uid, gid_t caller_gid) {
    if (!plist_path || !trash_dest || has_dotdot_segment(plist_path) || has_dotdot_segment(trash_dest)) {
        return 2;
    }

    static const char *prefix = "/Library/LaunchAgents/";
    size_t plen = strlen(prefix);
    if (strncmp(plist_path, prefix, plen) != 0) return 2;

    const char *basename = plist_path + plen;
    size_t blen = strlen(basename);
    if (blen < 7 || strchr(basename, '/') != NULL) return 2;
    if (strcmp(basename + blen - 6, ".plist") != 0) return 2;
    if (strncmp(basename, "com.apple.", 10) == 0 || strncmp(basename, "com.rabbit.syspulse", 19) == 0) {
        return 2;
    }

    if (strstr(trash_dest, "/.Trash/") == NULL) return 2;
    if (caller_uid != 0 && caller_uid < 501) return 3;

    struct stat src_st;
    if (lstat(plist_path, &src_st) != 0 || !S_ISREG(src_st.st_mode)) {
        return 4;
    }

    struct stat dst_st;
    if (lstat(trash_dest, &dst_st) == 0) {
        return 5;
    }

    if (setuid(0) != 0 || seteuid(0) != 0) return 1;

    // Best-effort bootout for system/ label (strip .plist suffix)
    char label[256];
    size_t label_len = blen - 6;
    if (label_len < sizeof(label)) {
        memcpy(label, basename, label_len);
        label[label_len] = '\0';
        char domain_target[300];
        snprintf(domain_target, sizeof(domain_target), "system/%s", label);
        char *const bootout_argv[] = { "/bin/launchctl", "bootout", domain_target, NULL };
        (void)run_exec_wait("/bin/launchctl", bootout_argv);
    }

    if (rename(plist_path, trash_dest) != 0) {
        if (errno != EXDEV || copy_and_unlink_file(plist_path, trash_dest) != 0) {
            return 6;
        }
    }

    (void)chown(trash_dest, caller_uid, caller_gid);
    (void)chmod(trash_dest, 0644);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 2) return 1;

    if (strcmp(argv[1], "--version") == 0) {
        puts("1");
        return 0;
    }

    uid_t caller_uid = getuid();
    gid_t caller_gid = getgid();

    if (strcmp(argv[1], "--periodic") == 0 && argc == 2) {
        return cmd_periodic();
    }
    if (strcmp(argv[1], "--repair-permissions") == 0 && argc == 3) {
        return cmd_repair_permissions(argv[2], caller_uid);
    }
    if (strcmp(argv[1], "--purge") == 0 && argc == 2) {
        return cmd_purge();
    }
    if (strcmp(argv[1], "--flush-mdns") == 0 && argc == 2) {
        return cmd_flush_mdns();
    }
    if (strcmp(argv[1], "--remove-broken-symlink") == 0 && argc == 3) {
        return cmd_remove_broken_symlink(argv[2]);
    }
    if (strcmp(argv[1], "--trash-broken-system-agent") == 0 && argc == 4) {
        return cmd_trash_broken_system_agent(argv[2], argv[3], caller_uid, caller_gid);
    }

    return 1;
}
