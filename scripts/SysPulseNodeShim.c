#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/*
 * Lightweight Node.js shim for systems without standalone Node installed.
 * Invokes Antigravity's embedded Electron binary with ELECTRON_RUN_AS_NODE=1
 * while preserving argv[0] so process lists report ".../bin/node", and injects
 * --require=<dir>/preload.cjs so ELECTRON_RUN_AS_NODE is stripped before any
 * script spawns child processes (including GUI Antigravity relaunch).
 */
int main(int argc, char *argv[]) {
    setenv("ELECTRON_RUN_AS_NODE", "1", 1);

    char raw_exec_path[PATH_MAX];
    uint32_t raw_size = sizeof(raw_exec_path);
    char resolved_self[PATH_MAX];
    const char *self_path = argv[0];

    if (_NSGetExecutablePath(raw_exec_path, &raw_size) == 0) {
        if (realpath(raw_exec_path, resolved_self) != NULL) {
            self_path = resolved_self;
        } else {
            self_path = raw_exec_path;
        }
    }
    if (self_path && self_path[0] != '\0') {
        setenv("SYSPULSE_NODE_SHIM_PATH", self_path, 1);
    }

    char preload_path[PATH_MAX];
    preload_path[0] = '\0';
    if (self_path && self_path[0] != '\0') {
        char self_copy[PATH_MAX];
        strncpy(self_copy, self_path, sizeof(self_copy) - 1);
        self_copy[sizeof(self_copy) - 1] = '\0';
        const char *dir = dirname(self_copy);
        if (dir && dir[0] != '\0') {
            snprintf(preload_path, sizeof(preload_path), "%s/preload.cjs", dir);
        }
    }

    int should_inject_preload = 0;
    if (preload_path[0] != '\0' && access(preload_path, R_OK) == 0 && argc >= 2) {
        const char *first_arg = argv[1];
        if (strcmp(first_arg, "-v") != 0 &&
            strcmp(first_arg, "--version") != 0 &&
            strcmp(first_arg, "-h") != 0 &&
            strcmp(first_arg, "--help") != 0) {
            int already_has_preload = 0;
            for (int i = 1; i < argc; i++) {
                if (argv[i] && strstr(argv[i], "preload.cjs") != NULL) {
                    already_has_preload = 1;
                    break;
                }
            }
            if (!already_has_preload) {
                should_inject_preload = 1;
            }
        }
    }

    char **exec_argv = argv;
    char req_flag[PATH_MAX + 16];
    if (should_inject_preload) {
        snprintf(req_flag, sizeof(req_flag), "--require=%s", preload_path);
        char **new_argv = (char **)calloc((size_t)argc + 2, sizeof(char *));
        if (new_argv != NULL) {
            new_argv[0] = argv[0];
            new_argv[1] = req_flag;
            for (int i = 1; i < argc; i++) {
                new_argv[i + 1] = argv[i];
            }
            new_argv[argc + 1] = NULL;
            exec_argv = new_argv;
        }
    }

    const char *env_bin = getenv("SYSPULSE_EMBEDDED_NODE_BIN");
    if (env_bin && env_bin[0] != '\0' && access(env_bin, X_OK) == 0) {
        execv(env_bin, exec_argv);
        return 126;
    }

    const char *candidates[] = {
        "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
        "/Applications/Antigravity - Insiders.app/Contents/MacOS/Antigravity - Insiders"
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        if (access(candidates[i], X_OK) == 0) {
            execv(candidates[i], exec_argv);
            return 126;
        }
    }

    const char *home = getenv("HOME");
    if (home && home[0] != '\0') {
        char buf[PATH_MAX];
        const char *rel[] = {
            "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
            "/Applications/Antigravity - Insiders.app/Contents/MacOS/Antigravity - Insiders"
        };
        for (size_t i = 0; i < sizeof(rel) / sizeof(rel[0]); i++) {
            snprintf(buf, sizeof(buf), "%s%s", home, rel[i]);
            if (access(buf, X_OK) == 0) {
                execv(buf, exec_argv);
                return 126;
            }
        }
    }

    fprintf(stderr, "SysPulseNodeShim: embedded Antigravity Node runtime not found.\n");
    return 127;
}
