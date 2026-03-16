/**
 * exec_napi: fork+exec wrapper for OpenHarmony NAPI
 *
 * Provides: runCommand(cmd: string): string
 *
 * Uses fork+execve instead of popen() to avoid PATH/shell issues in OH sandbox
 */

#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <errno.h>

#undef LOG_TAG
#define LOG_TAG "ExecNAPI"
#define LOGI(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define LOGE(...) OH_LOG_ERROR(LOG_APP, __VA_ARGS__)

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

// fork + execve, capture stdout+stderr via pipe
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
        // Child process
        close(pipefd[0]); // close read end

        // Redirect stdout and stderr to pipe
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[1]);

        // Set PATH so child can find commands
        setenv("PATH", "/bin:/system/bin:/vendor/bin:/data/local/tmp", 1);

        // Execute via /bin/sh -c "cmd"
        const char* argv[] = {"/bin/sh", "-c", cmd.c_str(), nullptr};
        execve("/bin/sh", (char* const*)argv, environ);

        // If execve fails, try /system/bin/sh
        const char* argv2[] = {"/system/bin/sh", "-c", cmd.c_str(), nullptr};
        execve("/system/bin/sh", (char* const*)argv2, environ);

        // If both fail
        dprintf(STDERR_FILENO, "execve failed: %s\n", strerror(errno));
        _exit(127);
    }

    // Parent process
    close(pipefd[1]); // close write end

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

// runCommand(cmd: string): string
static napi_value RunCommand(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    if (argc < 1) {
        return CreateString(env, "error: no command argument");
    }

    std::string cmd = GetStringArg(env, argv[0]);
    LOGI("RunCommand: %{public}s", cmd.c_str());

    std::string result = ExecCommand(cmd);
    LOGI("RunCommand done (%d bytes)", (int)result.size());
    return CreateString(env, result);
}

// Module registration
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"runCommand", nullptr, RunCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
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
