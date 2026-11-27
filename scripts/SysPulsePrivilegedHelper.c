//
//  SysPulsePrivilegedHelper.c
//  SysPulse
//
//  Zero-daemon unified setuid-root helper for SysPulse.
//  Verifies that its parent process is an authentic signed SysPulse binary
//  ("com.rabbit.syspulse") before elevating privileges and executing a fixed set
//  of validated system administration subcommands.
//

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define HELPER_VERSION "2"
#define SYSPULSE_INSTALL_DIR "/Library/Application Support/SysPulse"
#define PORTAL_ENGINE_DEST "/Library/Application Support/SysPulse/portal_engine"
#define CLAMSHELL_STATE_DIR "/var/run/syspulse"
#define CLAMSHELL_MARKER_PATH "/var/run/syspulse/clamshell.active"

static bool starts_with(const char *s, const char *prefix) {
    if (!s || !prefix) return false;
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static bool ends_with(const char *s, const char *suffix) {
    if (!s || !suffix) return false;
    size_t slen = strlen(s);
    size_t suflen = strlen(suffix);
    if (slen < suflen) return false;
    return strcmp(s + slen - suflen, suffix) == 0;
}

static bool has_dotdot_segment(const char *p) {
    if (!p || p[0] != '/') return true;
    const char *seg = p;
    while (*seg) {
        while (*seg == '/') seg++;
        if (*seg == '\0') break;
        const char *end = strchr(seg, '/');
        size_t len = end ? (size_t)(end - seg) : strlen(seg);
        if (len == 2 && seg[0] == '.' && seg[1] == '.') {
            return true;
        }
        if (len == 1 && seg[0] == '.') {
            return true;
        }
        if (!end) break;
        seg = end;
    }
    return false;
}

static bool is_safe_abs_path(const char *p) {
    if (!p || strlen(p) == 0 || strlen(p) >= PATH_MAX) return false;
    if (p[0] != '/') return false;
    if (has_dotdot_segment(p)) return false;
    return true;
}

static bool is_symlink_path(const char *p) {
    struct stat st;
    if (lstat(p, &st) != 0) return false;
    return S_ISLNK(st.st_mode);
}

static bool is_protected_system_path(const char *p) {
    if (!is_safe_abs_path(p)) return true;
    if (strcmp(p, "/") == 0) return true;
    static const char *const forbiddenExact[] = {
        "/Applications", "/Library", "/System", "/Users", "/Volumes",
        "/bin", "/sbin", "/usr", "/etc", "/var", "/tmp",
        "/private", "/private/etc", "/private/var", "/private/tmp",
        "/Library/Application Support", "/Library/LaunchAgents", "/Library/LaunchDaemons"
    };
    for (size_t i = 0; i < sizeof(forbiddenExact) / sizeof(forbiddenExact[0]); i++) {
        if (strcmp(p, forbiddenExact[i]) == 0) return true;
    }
    if (starts_with(p, "/System/")) return true;
    if (starts_with(p, "/usr/")) return true;
    if (starts_with(p, "/bin/")) return true;
    if (starts_with(p, "/sbin/")) return true;
    if (starts_with(p, "/private/var/db/")) return true;
    if (starts_with(p, "/dev/")) return true;
    return false;
}

static bool is_allowed_user_or_app_target(const char *p) {
    if (is_protected_system_path(p)) return false;
    if (starts_with(p, "/Applications/") ||
        starts_with(p, "/Library/") ||
        starts_with(p, "/Users/") ||
        starts_with(p, "/private/tmp/") ||
        starts_with(p, "/tmp/")) {
        return true;
    }
    return false;
}

static bool is_allowed_staging_path(const char *p) {
    if (!is_safe_abs_path(p) || is_symlink_path(p)) return false;
    return starts_with(p, "/var/folders/") ||
           starts_with(p, "/private/var/folders/") ||
           starts_with(p, "/tmp/") ||
           starts_with(p, "/private/tmp/");
}

static bool is_valid_launchd_label(const char *label) {
    if (!label || label[0] == '\0' || strlen(label) > 256) return false;
    for (const char *c = label; *c; c++) {
        unsigned char uc = (unsigned char)*c;
        if (uc <= 32 || uc == '/' || uc == '\'' || uc == '"' || uc == '\\' || uc == ';' || uc == '`') {
            return false;
        }
    }
    return true;
}

static bool is_valid_token(const char *s) {
    if (!s || s[0] == '\0' || strlen(s) > 256) return false;
    for (const char *c = s; *c; c++) {
        unsigned char uc = (unsigned char)*c;
        if (uc <= 32 || uc == '\'' || uc == '"' || uc == '\\' || uc == ';' || uc == '`') {
            return false;
        }
    }
    return true;
}

/// Verify that the direct parent process is the signed SysPulse executable (`com.rabbit.syspulse`).
static bool verify_caller_identity(void) {
    if (getuid() == 0) {
        return true;
    }

    pid_t ppid = getppid();
    if (ppid <= 1) {
        return false;
    }

    char parent_path[PROC_PIDPATHINFO_MAXSIZE];
    memset(parent_path, 0, sizeof(parent_path));
    if (proc_pidpath(ppid, parent_path, sizeof(parent_path)) <= 0) {
        return false;
    }
    if (!ends_with(parent_path, "/Contents/MacOS/SysPulse")) {
        return false;
    }

    CFNumberRef pidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &ppid);
    if (!pidNum) {
        return false;
    }
    const void *keys[] = { kSecGuestAttributePid };
    const void *vals[] = { pidNum };
    CFDictionaryRef attrs = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        vals,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );
    CFRelease(pidNum);
    if (!attrs) {
        return false;
    }

    SecCodeRef guestCode = NULL;
    OSStatus copyStatus = SecCodeCopyGuestWithAttributes(NULL, attrs, kSecCSDefaultFlags, &guestCode);
    CFRelease(attrs);
    if (copyStatus != errSecSuccess || !guestCode) {
        return false;
    }

    SecRequirementRef req = NULL;
    OSStatus reqStatus = SecRequirementCreateWithString(
        CFSTR("identifier \"com.rabbit.syspulse\""),
        kSecCSDefaultFlags,
        &req
    );
    if (reqStatus != errSecSuccess || !req) {
        CFRelease(guestCode);
        return false;
    }

    OSStatus validStatus = SecCodeCheckValidity(guestCode, kSecCSDefaultFlags, req);
    CFRelease(req);
    CFRelease(guestCode);
    return validStatus == errSecSuccess;
}

static int run_exec(const char *path, char *const argv[], bool suppress_output) {
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }
    if (pid == 0) {
        if (suppress_output) {
            int devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) {
                dup2(devnull, STDOUT_FILENO);
                dup2(devnull, STDERR_FILENO);
                if (devnull > STDERR_FILENO) close(devnull);
            }
        }
        execv(path, argv);
        _exit(127);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return 1;
}

static bool elevate_to_root(void) {
    if (setgid(0) != 0) return false;
    if (setuid(0) != 0) return false;
    return true;
}

static int ensure_dir_owned(const char *dir_path, mode_t mode, uid_t uid, gid_t gid) {
    if (mkdir(dir_path, mode) != 0 && errno != EEXIST) {
        return -1;
    }
    chmod(dir_path, mode);
    chown(dir_path, uid, gid);
    return 0;
}

static int cmd_clamshell(const char *action) {
    if (!action) return 64;
    if (strcmp(action, "enable") == 0) {
        ensure_dir_owned(CLAMSHELL_STATE_DIR, 0755, 0, 0);
        int fd = open(CLAMSHELL_MARKER_PATH, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            (void)write(fd, "1\n", 2);
            close(fd);
        }
        char *argv[] = { "/usr/bin/pmset", "-a", "disablesleep", "1", NULL };
        return run_exec("/usr/bin/pmset", argv, true);
    }
    if (strcmp(action, "disable") == 0) {
        unlink(CLAMSHELL_MARKER_PATH);
        char *argv[] = { "/usr/bin/pmset", "-a", "disablesleep", "0", NULL };
        return run_exec("/usr/bin/pmset", argv, true);
    }
    if (strcmp(action, "remove-marker") == 0) {
        unlink(CLAMSHELL_MARKER_PATH);
        return 0;
    }
    return 64;
}

static int cmd_clean_idleassets(const char *target) {
    if (!is_safe_abs_path(target) || is_symlink_path(target)) return 64;
    if (!starts_with(target, "/Library/Application Support/com.apple.idleassetsd/")) {
        return 64;
    }
    struct stat st;
    if (lstat(target, &st) != 0) return 0;
    if (S_ISDIR(st.st_mode)) {
        char *argv[] = {
            "/usr/bin/find",
            (char *)target,
            "-maxdepth", "3",
            "-type", "f",
            "-name", "CFNetworkDownload_*.tmp",
            "-mmin", "+60",
            "-delete",
            NULL
        };
        return run_exec("/usr/bin/find", argv, true);
    }
    if (S_ISREG(st.st_mode)) {
        const char *base = strrchr(target, '/');
        if (!base) return 64;
        base++;
        if (!starts_with(base, "CFNetworkDownload_") || !ends_with(base, ".tmp")) {
            return 64;
        }
        char *argv[] = { "/bin/rm", "-f", (char *)target, NULL };
        return run_exec("/bin/rm", argv, true);
    }
    return 64;
}

static int cmd_daemon_batch(int argc, char **argv) {
    if (argc < 5 || ((argc - 3) % 2) != 0) return 64;
    const char *op = argv[2];
    bool enable = false;
    if (strcmp(op, "enable") == 0) enable = true;
    else if (strcmp(op, "disable") == 0) enable = false;
    else return 64;

    for (int i = 3; i < argc; i += 2) {
        const char *label = argv[i];
        const char *plist = argv[i + 1];
        if (!is_valid_launchd_label(label) || !is_safe_abs_path(plist)) return 64;
        if (!(starts_with(plist, "/Library/LaunchDaemons/") || starts_with(plist, "/Library/LaunchAgents/")) ||
            !ends_with(plist, ".plist")) {
            return 64;
        }

        char svc[300];
        snprintf(svc, sizeof(svc), "system/%s", label);
        if (enable) {
            char *en_args[] = { "/bin/launchctl", "enable", svc, NULL };
            (void)run_exec("/bin/launchctl", en_args, true);
            char *boot_args[] = { "/bin/launchctl", "bootstrap", "system", (char *)plist, NULL };
            if (run_exec("/bin/launchctl", boot_args, true) != 0) {
                char *kick_args[] = { "/bin/launchctl", "kickstart", "-k", svc, NULL };
                (void)run_exec("/bin/launchctl", kick_args, true);
            }
        } else {
            char *dis_args[] = { "/bin/launchctl", "disable", svc, NULL };
            (void)run_exec("/bin/launchctl", dis_args, true);
            char *out_svc[] = { "/bin/launchctl", "bootout", svc, NULL };
            (void)run_exec("/bin/launchctl", out_svc, true);
            char *out_plist[] = { "/bin/launchctl", "bootout", "system", (char *)plist, NULL };
            (void)run_exec("/bin/launchctl", out_plist, true);
        }
    }
    return 0;
}

static int cmd_remove_startup_plist(int argc, char **argv) {
    if (argc != 5) return 64;
    const char *kind = argv[2];
    const char *label = argv[3];
    const char *plist = argv[4];
    if (!is_valid_launchd_label(label) || !is_safe_abs_path(plist) || !ends_with(plist, ".plist")) {
        return 64;
    }

    if (strcmp(kind, "global") == 0) {
        if (!starts_with(plist, "/Library/LaunchAgents/")) return 64;
        char *rm_args[] = { "/bin/rm", "-f", (char *)plist, NULL };
        return run_exec("/bin/rm", rm_args, true);
    }
    if (strcmp(kind, "daemon") == 0) {
        if (!starts_with(plist, "/Library/LaunchDaemons/")) return 64;
        char svc[300];
        snprintf(svc, sizeof(svc), "system/%s", label);
        char *dis_args[] = { "/bin/launchctl", "disable", svc, NULL };
        (void)run_exec("/bin/launchctl", dis_args, true);
        char *out_plist[] = { "/bin/launchctl", "bootout", "system", (char *)plist, NULL };
        (void)run_exec("/bin/launchctl", out_plist, true);
        char *out_svc[] = { "/bin/launchctl", "bootout", svc, NULL };
        (void)run_exec("/bin/launchctl", out_svc, true);
        char *rm_args[] = { "/bin/rm", "-f", (char *)plist, NULL };
        return run_exec("/bin/rm", rm_args, true);
    }
    return 64;
}

static int cmd_dump_btm(void) {
    char *argv[] = { "/usr/bin/sfltool", "dumpbtm", NULL };
    return run_exec("/usr/bin/sfltool", argv, false);
}

static int cmd_uninstall_batch(int argc, char **argv) {
    if (argc < 7) return 64;
    const char *mode = argv[2];
    const char *trash_dir = argv[3];
    long uid_l = strtol(argv[4], NULL, 10);
    long gid_l = strtol(argv[5], NULL, 10);
    bool move_to_trash = false;
    if (strcmp(mode, "trash") == 0) move_to_trash = true;
    else if (strcmp(mode, "delete") == 0) move_to_trash = false;
    else return 64;

    if (move_to_trash) {
        if (!is_safe_abs_path(trash_dir) || !starts_with(trash_dir, "/Users/") || !ends_with(trash_dir, "/.Trash")) {
            return 64;
        }
        ensure_dir_owned(trash_dir, 0700, (uid_t)uid_l, (gid_t)gid_l);
    }

    for (int i = 6; i < argc; i++) {
        const char *target = argv[i];
        if (!is_allowed_user_or_app_target(target)) continue;

        struct stat st;
        if (lstat(target, &st) != 0) continue;

        char *chf_args[] = { "/usr/bin/chflags", "-R", "nouchg", (char *)target, NULL };
        (void)run_exec("/usr/bin/chflags", chf_args, true);

        if (move_to_trash) {
            const char *base = strrchr(target, '/');
            base = base ? (base + 1) : target;
            if (*base == '\0') continue;

            char dest[PATH_MAX];
            snprintf(dest, sizeof(dest), "%s/%s", trash_dir, base);
            struct stat dst_st;
            if (lstat(dest, &dst_st) == 0) {
                time_t now = time(NULL);
                struct tm tm_now;
                localtime_r(&now, &tm_now);
                char ts[32];
                strftime(ts, sizeof(ts), "%Y%m%d%H%M%S", &tm_now);
                snprintf(dest, sizeof(dest), "%s/%s.%s", trash_dir, base, ts);
            }
            char *mv_args[] = { "/bin/mv", (char *)target, dest, NULL };
            if (run_exec("/bin/mv", mv_args, true) == 0) {
                char owner_spec[64];
                snprintf(owner_spec, sizeof(owner_spec), "%ld:%ld", uid_l, gid_l);
                char *chown_args[] = { "/usr/sbin/chown", "-R", owner_spec, dest, NULL };
                (void)run_exec("/usr/sbin/chown", chown_args, true);
            }
        } else {
            char *rm_args[] = { "/bin/rm", "-rf", (char *)target, NULL };
            (void)run_exec("/bin/rm", rm_args, true);
        }
    }
    return 0;
}

static int cmd_patch_antigravity(int argc, char **argv) {
    if (argc != 4) return 64;
    const char *stage = argv[2];
    const char *target = argv[3];
    if (!is_allowed_staging_path(stage)) return 64;
    if (!is_allowed_user_or_app_target(target) || is_symlink_path(target)) return 64;

    struct stat st;
    if (lstat(stage, &st) != 0 || !S_ISREG(st.st_mode)) return 64;

    char *cp_args[] = { "/bin/cp", "-f", (char *)stage, (char *)target, NULL };
    if (run_exec("/bin/cp", cp_args, true) != 0) return 1;

    chmod(target, 0755);

    char *xattr_args[] = { "/usr/bin/xattr", "-d", "com.apple.quarantine", (char *)target, NULL };
    (void)run_exec("/usr/bin/xattr", xattr_args, true);

    char *sign_args[] = {
        "/usr/bin/codesign", "--force", "--preserve-metadata=entitlements,flags", "--sign", "-", (char *)target, NULL
    };
    if (run_exec("/usr/bin/codesign", sign_args, true) != 0) return 2;

    char *verify_args[] = { "/usr/bin/codesign", "--verify", "--strict", (char *)target, NULL };
    if (run_exec("/usr/bin/codesign", verify_args, true) != 0) return 3;

    return 0;
}

static int cmd_replace_app(int argc, char **argv) {
    if (argc != 7) return 64;
    const char *source_app = argv[2];
    const char *target_app = argv[3];
    const char *user_trash = argv[4];
    long uid_l = strtol(argv[5], NULL, 10);
    long gid_l = strtol(argv[6], NULL, 10);

    if (!is_allowed_staging_path(source_app)) return 64;
    if (!is_allowed_user_or_app_target(target_app) || !ends_with(target_app, ".app")) return 64;
    if (!is_safe_abs_path(user_trash) || !starts_with(user_trash, "/Users/") || !ends_with(user_trash, "/.Trash")) {
        return 64;
    }

    char stage_root[PATH_MAX];
    char install_stage[PATH_MAX];
    char backup_stage[PATH_MAX];
    snprintf(stage_root, sizeof(stage_root), "/private/tmp/syspulse_replace_%d", (int)getpid());
    snprintf(install_stage, sizeof(install_stage), "%s/install.app", stage_root);
    snprintf(backup_stage, sizeof(backup_stage), "%s/backup.app", stage_root);

    char *rm_old[] = { "/bin/rm", "-rf", stage_root, NULL };
    (void)run_exec("/bin/rm", rm_old, true);
    ensure_dir_owned(stage_root, 0700, 0, 0);

    char *chf_args[] = { "/usr/bin/chflags", "-R", "nouchg", (char *)target_app, NULL };
    (void)run_exec("/usr/bin/chflags", chf_args, true);

    char *ditto_args[] = { "/usr/bin/ditto", (char *)source_app, install_stage, NULL };
    if (run_exec("/usr/bin/ditto", ditto_args, true) != 0) {
        (void)run_exec("/bin/rm", rm_old, true);
        return 1;
    }

    char *xattr_stage[] = { "/usr/bin/xattr", "-dr", "com.apple.quarantine", install_stage, NULL };
    (void)run_exec("/usr/bin/xattr", xattr_stage, true);

    struct stat target_st;
    bool had_target = (lstat(target_app, &target_st) == 0);
    if (had_target) {
        char *mv_bak[] = { "/bin/mv", (char *)target_app, backup_stage, NULL };
        if (run_exec("/bin/mv", mv_bak, true) != 0) {
            (void)run_exec("/bin/rm", rm_old, true);
            return 2;
        }
    }

    char *mv_new[] = { "/bin/mv", install_stage, (char *)target_app, NULL };
    if (run_exec("/bin/mv", mv_new, true) != 0) {
        struct stat cur_st;
        if (had_target && lstat(target_app, &cur_st) != 0) {
            char *mv_restore[] = { "/bin/mv", backup_stage, (char *)target_app, NULL };
            (void)run_exec("/bin/mv", mv_restore, true);
        }
        (void)run_exec("/bin/rm", rm_old, true);
        return 3;
    }

    char *xattr_dst[] = { "/usr/bin/xattr", "-dr", "com.apple.quarantine", (char *)target_app, NULL };
    (void)run_exec("/usr/bin/xattr", xattr_dst, true);

    struct stat bak_st;
    if (lstat(backup_stage, &bak_st) == 0) {
        const char *app_name = strrchr(target_app, '/');
        app_name = app_name ? (app_name + 1) : "Replaced.app";
        ensure_dir_owned(user_trash, 0700, (uid_t)uid_l, (gid_t)gid_l);

        char trash_dest[PATH_MAX];
        snprintf(trash_dest, sizeof(trash_dest), "%s/%s", user_trash, app_name);
        struct stat tr_st;
        if (lstat(trash_dest, &tr_st) == 0) {
            time_t now = time(NULL);
            struct tm tm_now;
            localtime_r(&now, &tm_now);
            char ts[32];
            strftime(ts, sizeof(ts), "%Y%m%d%H%M%S", &tm_now);
            snprintf(trash_dest, sizeof(trash_dest), "%s/%s.%s", user_trash, app_name, ts);
        }
        char *mv_trash[] = { "/bin/mv", backup_stage, trash_dest, NULL };
        if (run_exec("/bin/mv", mv_trash, true) == 0) {
            char owner_spec[64];
            snprintf(owner_spec, sizeof(owner_spec), "%ld:%ld", uid_l, gid_l);
            char *chown_args[] = { "/usr/sbin/chown", "-R", owner_spec, trash_dest, NULL };
            (void)run_exec("/usr/sbin/chown", chown_args, true);
        }
    }

    char *lsreg_args[] = {
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        "-f",
        (char *)target_app,
        NULL
    };
    (void)run_exec(lsreg_args[0], lsreg_args, true);
    (void)run_exec("/bin/rm", rm_old, true);
    return 0;
}

static int cmd_psportal_install(int argc, char **argv) {
    if (argc != 3) return 64;
    const char *staged = argv[2];
    if (!is_safe_abs_path(staged) || is_symlink_path(staged)) return 64;
    struct stat st;
    if (lstat(staged, &st) != 0 || !S_ISREG(st.st_mode)) return 64;
    if (!(starts_with(staged, "/Applications/") ||
          starts_with(staged, "/Volumes/") ||
          starts_with(staged, "/Users/") ||
          starts_with(staged, "/Library/") ||
          starts_with(staged, "/var/folders/") ||
          starts_with(staged, "/private/var/folders/") ||
          starts_with(staged, "/tmp/") ||
          starts_with(staged, "/private/tmp/"))) {
        return 64;
    }

    ensure_dir_owned(SYSPULSE_INSTALL_DIR, 0755, 0, 0);
    char tmp_dest[PATH_MAX];
    snprintf(tmp_dest, sizeof(tmp_dest), "%s.tmp.%d", PORTAL_ENGINE_DEST, (int)getpid());
    char *cp_args[] = { "/bin/cp", "-f", (char *)staged, tmp_dest, NULL };
    if (run_exec("/bin/cp", cp_args, true) != 0) {
        unlink(tmp_dest);
        return 1;
    }
    chown(tmp_dest, 0, 0);
    chmod(tmp_dest, 0755);
    if (rename(tmp_dest, PORTAL_ENGINE_DEST) != 0) {
        unlink(tmp_dest);
        return 2;
    }
    chown(PORTAL_ENGINE_DEST, 0, 0);
    chmod(PORTAL_ENGINE_DEST, 0755);

    char *sudoers_args[] = { PORTAL_ENGINE_DEST, "--install-sudoers", NULL };
    return run_exec(PORTAL_ENGINE_DEST, sudoers_args, true);
}

static int cmd_psportal_restore(int argc, char **argv) {
    if (argc < 4) return 64;
    const char *engine = argv[2];
    const char *iface = argv[3];
    if (!is_safe_abs_path(engine) || is_symlink_path(engine) || !ends_with(engine, "/portal_engine")) {
        return 64;
    }
    if (!is_valid_token(iface)) return 64;

    const char *ps5 = (argc >= 5 && argv[4][0] != '\0') ? argv[4] : NULL;
    const char *portal = (argc >= 6 && argv[5][0] != '\0') ? argv[5] : NULL;
    if (ps5 && !is_valid_token(ps5)) return 64;
    if (portal && !is_valid_token(portal)) return 64;

    char *exec_args[10];
    int idx = 0;
    exec_args[idx++] = (char *)engine;
    exec_args[idx++] = "--restore";
    exec_args[idx++] = "--interface";
    exec_args[idx++] = (char *)iface;
    if (ps5) {
        exec_args[idx++] = "--ps5";
        exec_args[idx++] = (char *)ps5;
    }
    if (portal) {
        exec_args[idx++] = "--portal";
        exec_args[idx++] = (char *)portal;
    }
    exec_args[idx] = NULL;
    return run_exec(engine, exec_args, false);
}

static int install_single_setuid_helper(const char *macos_dir, const char *name) {
    char src[PATH_MAX];
    char dst[PATH_MAX];
    char tmp[PATH_MAX];
    snprintf(src, sizeof(src), "%s/%s", macos_dir, name);
    snprintf(dst, sizeof(dst), "%s/%s", SYSPULSE_INSTALL_DIR, name);
    snprintf(tmp, sizeof(tmp), "%s/%s.tmp.%d", SYSPULSE_INSTALL_DIR, name, (int)getpid());

    struct stat st;
    if (lstat(src, &st) != 0) {
        return (errno == ENOENT) ? 0 : -1;
    }
    if (!S_ISREG(st.st_mode)) {
        return -1;
    }
    char *cp_args[] = { "/bin/cp", "-f", src, tmp, NULL };
    if (run_exec("/bin/cp", cp_args, true) != 0) {
        unlink(tmp);
        return -1;
    }
    if (chown(tmp, 0, 0) != 0 || chmod(tmp, 04755) != 0 || rename(tmp, dst) != 0) {
        unlink(tmp);
        return -1;
    }
    return 0;
}

static int cmd_manage_subhelper(int argc, char **argv) {
    if (argc < 4) return 64;
    const char *action = argv[2];
    const char *which = argv[3];

    const char *dst = NULL;
    if (strcmp(which, "ups") == 0) {
        dst = SYSPULSE_INSTALL_DIR "/SysPulseUPSHelper";
    } else if (strcmp(which, "optimize") == 0) {
        dst = SYSPULSE_INSTALL_DIR "/SysPulseOptimizeHelper";
    } else {
        return 64;
    }

    if (strcmp(action, "remove") == 0) {
        if (argc != 4) return 64;
        if (unlink(dst) != 0 && errno != ENOENT) {
            return 1;
        }
        return 0;
    }

    if (strcmp(action, "install") == 0) {
        if (argc != 5) return 64;
        const char *staged = argv[4];
        if (!is_allowed_staging_path(staged)) return 64;

        struct stat st;
        if (lstat(staged, &st) != 0 || !S_ISREG(st.st_mode)) {
            return 64;
        }

        ensure_dir_owned(SYSPULSE_INSTALL_DIR, 0755, 0, 0);

        char tmp[PATH_MAX];
        snprintf(tmp, sizeof(tmp), "%s.tmp.%d", dst, (int)getpid());
        char *cp_args[] = { "/bin/cp", "-f", (char *)staged, tmp, NULL };
        if (run_exec("/bin/cp", cp_args, true) != 0) {
            unlink(tmp);
            return 1;
        }
        if (chown(tmp, 0, 0) != 0 || chmod(tmp, 04755) != 0 || rename(tmp, dst) != 0) {
            unlink(tmp);
            return 2;
        }
        return 0;
    }

    return 64;
}

static int cmd_upgrade_helpers(int argc, char **argv) {
    if (argc != 3) return 64;
    const char *macos_dir = argv[2];
    if (!is_safe_abs_path(macos_dir) || is_symlink_path(macos_dir) || !ends_with(macos_dir, "/Contents/MacOS")) {
        return 64;
    }
    ensure_dir_owned(SYSPULSE_INSTALL_DIR, 0755, 0, 0);

    if (install_single_setuid_helper(macos_dir, "SysPulseUPSHelper") != 0) return 1;
    if (install_single_setuid_helper(macos_dir, "SysPulseOptimizeHelper") != 0) return 2;
    if (install_single_setuid_helper(macos_dir, "SysPulsePrivilegedHelper") != 0) return 3;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        return 64;
    }

    if (strcmp(argv[1], "--version") == 0) {
        printf("%s\n", HELPER_VERSION);
        return 0;
    }

    if (!verify_caller_identity()) {
        fprintf(stderr, "SysPulsePrivilegedHelper: unauthorized caller\n");
        return 77;
    }

    if (!elevate_to_root()) {
        fprintf(stderr, "SysPulsePrivilegedHelper: setuid failed\n");
        return 78;
    }

    const char *cmd = argv[1];
    if (strcmp(cmd, "--clamshell") == 0) {
        return cmd_clamshell(argc >= 3 ? argv[2] : NULL);
    }
    if (strcmp(cmd, "--clean-idleassets") == 0) {
        return argc == 3 ? cmd_clean_idleassets(argv[2]) : 64;
    }
    if (strcmp(cmd, "--daemon-batch") == 0) {
        return cmd_daemon_batch(argc, argv);
    }
    if (strcmp(cmd, "--remove-startup-plist") == 0) {
        return cmd_remove_startup_plist(argc, argv);
    }
    if (strcmp(cmd, "--dump-btm") == 0) {
        return cmd_dump_btm();
    }
    if (strcmp(cmd, "--uninstall-batch") == 0) {
        return cmd_uninstall_batch(argc, argv);
    }
    if (strcmp(cmd, "--patch-antigravity") == 0) {
        return cmd_patch_antigravity(argc, argv);
    }
    if (strcmp(cmd, "--replace-app") == 0) {
        return cmd_replace_app(argc, argv);
    }
    if (strcmp(cmd, "--psportal-install") == 0) {
        return cmd_psportal_install(argc, argv);
    }
    if (strcmp(cmd, "--psportal-restore") == 0) {
        return cmd_psportal_restore(argc, argv);
    }
    if (strcmp(cmd, "--upgrade-helpers") == 0) {
        return cmd_upgrade_helpers(argc, argv);
    }
    if (strcmp(cmd, "--manage-subhelper") == 0) {
        return cmd_manage_subhelper(argc, argv);
    }

    return 64;
}
