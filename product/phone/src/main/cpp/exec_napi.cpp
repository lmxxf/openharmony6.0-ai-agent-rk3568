/**
 * exec_napi: fork+exec + daemon mode for OpenHarmony NAPI
 *
 * One-shot mode:
 *   runCommand(cmd: string): string
 *
 * Daemon mode (stdin/stdout pipe):
 *   startDaemon(pythonBase: string, scriptPath: string): boolean
 *   sendMessage(json: string): void
 *   readMessage(): string   (blocking read one line from stdout)
 *   stopDaemon(): void
 *   isDaemonRunning(): boolean
 */

#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <mutex>
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>

#undef LOG_TAG
#define LOG_TAG "ExecNAPI"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

// ============================================================
// Helpers
// ============================================================

static std::string GetStringArg(napi_env env, napi_value value) {
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    std::string str(len, '\0');
    napi_get_value_string_utf8(env, value, &str[0], len + 1, &len);
    return str;
}

static napi_value CreateString(napi_env env, const std::string& str) {
    napi_value result;
    napi_create_string_utf8(env, str.c_str(), str.length(), &result);
    return result;
}

static napi_value CreateBool(napi_env env, bool val) {
    napi_value result;
    napi_get_boolean(env, val, &result);
    return result;
}

// ============================================================
// One-shot exec (existing functionality)
// ============================================================

static std::string ExecCommand(const std::string& cmd) {
    int pipefd[2];
    if (pipe(pipefd) < 0) {
        return "error: pipe() failed: " + std::string(strerror(errno));
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return "error: fork() failed: " + std::string(strerror(errno));
    }

    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[1]);
        setenv("PATH", "/bin:/system/bin:/vendor/bin:/data/local/tmp", 1);
        const char* argv[] = {"/bin/sh", "-c", cmd.c_str(), nullptr};
        execve("/bin/sh", (char* const*)argv, environ);
        dprintf(STDERR_FILENO, "execve failed: %s\n", strerror(errno));
        _exit(127);
    }

    close(pipefd[1]);
    std::string output;
    char buf[1024];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf) - 1)) > 0) {
        buf[n] = '\0';
        output += buf;
    }
    close(pipefd[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    if (exitCode != 0) {
        output += "\n[exit code: " + std::to_string(exitCode) + "]";
    }
    return output;
}

static napi_value RunCommand(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1) return CreateString(env, "error: no command");
    std::string cmd = GetStringArg(env, argv[0]);
    LOGI("RunCommand: %{public}s", cmd.c_str());
    return CreateString(env, ExecCommand(cmd));
}

// ============================================================
// Daemon mode: persistent Python subprocess with stdin/stdout pipes
// ============================================================

static pid_t g_daemon_pid = -1;
static int g_stdin_fd = -1;   // parent writes to Python's stdin
static int g_stdout_fd = -1;  // parent reads from Python's stdout
static std::mutex g_daemon_mutex;

// startDaemon(pythonBase: string, scriptPath: string): boolean
static napi_value StartDaemon(napi_env env, napi_callback_info info) {
    std::lock_guard<std::mutex> lock(g_daemon_mutex);

    if (g_daemon_pid > 0) {
        LOGI("Daemon already running (pid %d)", g_daemon_pid);
        return CreateBool(env, true);
    }

    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 2) {
        LOGE("startDaemon needs pythonBase and scriptPath");
        return CreateBool(env, false);
    }

    std::string pythonBase = GetStringArg(env, argv[0]);
    std::string scriptPath = GetStringArg(env, argv[1]);

    std::string pyBin = pythonBase + "/bin/python3.11";
    std::string ldPath = pythonBase + "/lib";

    // Create two pipes: parent→child (stdin) and child→parent (stdout)
    int pipe_in[2];   // parent writes pipe_in[1], child reads pipe_in[0]
    int pipe_out[2];  // child writes pipe_out[1], parent reads pipe_out[0]

    if (pipe(pipe_in) < 0 || pipe(pipe_out) < 0) {
        LOGE("pipe() failed: %{public}s", strerror(errno));
        return CreateBool(env, false);
    }

    pid_t pid = fork();
    if (pid < 0) {
        LOGE("fork() failed: %{public}s", strerror(errno));
        close(pipe_in[0]); close(pipe_in[1]);
        close(pipe_out[0]); close(pipe_out[1]);
        return CreateBool(env, false);
    }

    if (pid == 0) {
        // Child process
        close(pipe_in[1]);   // close parent's write end
        close(pipe_out[0]);  // close parent's read end

        dup2(pipe_in[0], STDIN_FILENO);    // child reads from pipe_in
        dup2(pipe_out[1], STDOUT_FILENO);  // child writes to pipe_out
        dup2(pipe_out[1], STDERR_FILENO);  // stderr also to pipe_out
        close(pipe_in[0]);
        close(pipe_out[1]);

        setenv("PATH", "/bin:/system/bin:/vendor/bin", 1);
        setenv("LD_LIBRARY_PATH", ldPath.c_str(), 1);
        setenv("PYTHONHOME", pythonBase.c_str(), 1);
        setenv("PYTHONUNBUFFERED", "1", 1);  // crucial: no output buffering

        const char* args[] = {pyBin.c_str(), "-u", scriptPath.c_str(), nullptr};
        execve(pyBin.c_str(), (char* const*)args, environ);

        // If execve fails
        dprintf(STDERR_FILENO, "execve failed: %s\n", strerror(errno));
        _exit(127);
    }

    // Parent process
    close(pipe_in[0]);   // close child's read end
    close(pipe_out[1]);  // close child's write end

    g_daemon_pid = pid;
    g_stdin_fd = pipe_in[1];
    g_stdout_fd = pipe_out[0];

    LOGI("Daemon started: pid=%d, stdin_fd=%d, stdout_fd=%d", pid, g_stdin_fd, g_stdout_fd);
    return CreateBool(env, true);
}

// sendMessage(json: string): void
// Writes a line (json + newline) to Python's stdin
static napi_value SendMessage(napi_env env, napi_callback_info info) {
    std::lock_guard<std::mutex> lock(g_daemon_mutex);

    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc < 1 || g_stdin_fd < 0) {
        return CreateBool(env, false);
    }

    std::string msg = GetStringArg(env, argv[0]);
    msg += "\n";  // JSON lines protocol: one JSON per line

    ssize_t written = write(g_stdin_fd, msg.c_str(), msg.size());
    if (written < 0) {
        LOGE("write to daemon stdin failed: %{public}s", strerror(errno));
        return CreateBool(env, false);
    }

    LOGI("Sent %d bytes to daemon", (int)written);
    return CreateBool(env, true);
}

// readMessage(): string
// Reads one line from Python's stdout (blocking)
static napi_value ReadMessage(napi_env env, napi_callback_info info) {
    // Note: no mutex lock here — read can block, don't hold the lock
    if (g_stdout_fd < 0) {
        return CreateString(env, "error: daemon not running");
    }

    std::string line;
    char c;
    while (true) {
        ssize_t n = read(g_stdout_fd, &c, 1);
        if (n <= 0) {
            if (n == 0) {
                LOGI("Daemon stdout EOF");
                return CreateString(env, line.empty() ? "error: EOF" : line);
            }
            LOGE("read error: %{public}s", strerror(errno));
            return CreateString(env, "error: read failed");
        }
        if (c == '\n') {
            break;  // got a complete line
        }
        line += c;
    }

    LOGI("Read from daemon: %{public}s", line.c_str());
    return CreateString(env, line);
}

// stopDaemon(): void
static napi_value StopDaemon(napi_env env, napi_callback_info info) {
    std::lock_guard<std::mutex> lock(g_daemon_mutex);

    if (g_daemon_pid > 0) {
        LOGI("Stopping daemon pid=%d", g_daemon_pid);
        kill(g_daemon_pid, SIGTERM);

        // Wait briefly, then force kill
        int status;
        pid_t r = waitpid(g_daemon_pid, &status, WNOHANG);
        if (r == 0) {
            usleep(500000); // 500ms
            kill(g_daemon_pid, SIGKILL);
            waitpid(g_daemon_pid, &status, 0);
        }
    }

    if (g_stdin_fd >= 0) { close(g_stdin_fd); g_stdin_fd = -1; }
    if (g_stdout_fd >= 0) { close(g_stdout_fd); g_stdout_fd = -1; }
    g_daemon_pid = -1;

    LOGI("Daemon stopped");
    return CreateBool(env, true);
}

// isDaemonRunning(): boolean
static napi_value IsDaemonRunning(napi_env env, napi_callback_info info) {
    if (g_daemon_pid <= 0) return CreateBool(env, false);

    // Check if process is still alive
    int status;
    pid_t r = waitpid(g_daemon_pid, &status, WNOHANG);
    if (r == g_daemon_pid) {
        // Process exited
        LOGI("Daemon pid=%d has exited", g_daemon_pid);
        if (g_stdin_fd >= 0) { close(g_stdin_fd); g_stdin_fd = -1; }
        if (g_stdout_fd >= 0) { close(g_stdout_fd); g_stdout_fd = -1; }
        g_daemon_pid = -1;
        return CreateBool(env, false);
    }
    return CreateBool(env, true);
}

// ============================================================
// Module registration
// ============================================================

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        // One-shot
        {"runCommand", nullptr, RunCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        // Daemon mode
        {"startDaemon", nullptr, StartDaemon, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendMessage", nullptr, SendMessage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"readMessage", nullptr, ReadMessage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopDaemon", nullptr, StopDaemon, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isDaemonRunning", nullptr, IsDaemonRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

EXTERN_C_START
static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "exec_napi",
    .nm_priv = nullptr,
    .reserved = {0},
};

__attribute__((constructor)) void RegisterExecModule(void) {
    napi_module_register(&g_module);
}
EXTERN_C_END
