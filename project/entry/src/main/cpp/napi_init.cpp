/*
 * napi_init.cpp -- Node-API binding that runs HandBrake inside a HarmonyOS app.
 *
 * The HarmonyOS tablet used for this port refuses to execute a native binary
 * launched from `hdc shell` (SELinux: the `shell` domain may not execute the
 * `data_local_tmp` label, and a tablet has no /storage/Users/currentUser), so
 * native code must run inside an application sandbox.  This module is that
 * sandbox door: it links libhb (plus FFmpeg, x264, x265, jansson, libogg,
 * libjpeg-turbo) and HandBrake's CLI driver, and lets ArkTS drive it.
 *
 * Three things here exist specifically because of the sandbox:
 *
 *  1. sandbox paths  -- libhb's Linux temp dir defaults to /tmp, which does not
 *     exist in a sandbox; hb_set_temporary_directory() fixes it (see §6.7).
 *  2. stdio capture  -- HandBrakeCLI and libhb log to stdout/stderr.  An app has
 *     no console, so without capturing it every diagnostic message is invisible
 *     and a crash looks like "the app just died".  We redirect fds 1 and 2 into
 *     a pipe drained by a helper thread that forwards lines to hilog.
 *  3. fault capture  -- a SIGSEGV inside a codec otherwise takes the whole app
 *     down with no output at all.  We catch the fatal signals, log which one
 *     fired, and unwind back to the CLI wrapper so the caller sees a distinct
 *     result code instead of the process disappearing.
 */
#include <napi/native_api.h>
#include <hilog/log.h>

#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <csetjmp>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <cerrno>
#include <string>
#include <vector>

#include "handbrake/handbrake.h"

#undef LOG_TAG
#define LOG_TAG "HandBrakeOHOS"

/* ------------------------------------------------------------------ *
 * Logging: every line goes to hilog *and* (if a log file was opened) to
 * that file.  The file is written with raw write(2) on an unbuffered fd,
 * so it survives a SIGSEGV -- which is the whole point: on device the
 * process dies inside x265 and hilog alone is awkward to collect.
 * ------------------------------------------------------------------ */
static int             g_log_fd = -1;
static pthread_mutex_t g_log_mu = PTHREAD_MUTEX_INITIALIZER;

static void log_file_raw(const char *s, size_t n)
{
    if (g_log_fd < 0) { return; }
    pthread_mutex_lock(&g_log_mu);
    ssize_t off = 0;
    while (off < (ssize_t)n)
    {
        ssize_t w = write(g_log_fd, s + off, n - (size_t)off);
        if (w <= 0) { break; }
        off += w;
    }
    pthread_mutex_unlock(&g_log_mu);
}

static void log_both(LogLevel prio, const char *fmt, ...)
{
    char    buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    OH_LOG_Print(LOG_APP, prio, 0xFF00, LOG_TAG, "%s", buf);
    if (g_log_fd >= 0)
    {
        log_file_raw(buf, strlen(buf));
        log_file_raw("\n", 1);
    }
}

#define LOGI(...) log_both(LOG_INFO,  __VA_ARGS__)
#define LOGE(...) log_both(LOG_ERROR, __VA_ARGS__)

extern "C" int  hbcli_main(int argc, char **argv);
extern "C" void hbcli_exit(int code);

/* ------------------------------------------------------------------ *
 * 1. exit() interception.
 *
 * test.c calls exit(done_error) exactly once, at the end of a job.  Calling the
 * real exit() would tear down the whole application, so it is renamed to
 * hbcli_exit() and turned into a non-local jump back into run_cli().
 * ------------------------------------------------------------------ */
static jmp_buf g_exit_jmp;
static int     g_exit_code = 0;

extern "C" void hbcli_exit(int code)
{
    g_exit_code = code;
    longjmp(g_exit_jmp, 1);
}

/* ------------------------------------------------------------------ *
 * 3. fatal-signal capture.
 *
 * Logging from a signal handler must be async-signal-safe, so we only
 * write(2) a fixed byte string (the reader thread turns it into a hilog
 * line) and then unwind.
 * ------------------------------------------------------------------ */
static jmp_buf            g_fault_jmp;
static volatile sig_atomic_t g_fault_sig = 0;

static void fault_handler(int sig)
{
    g_fault_sig = sig;
    static const char m1[] = "\n[HandBrakeOHOS] FATAL SIGNAL: ";
    static const char m2[] = " -- libhb/x265 aborted; unwinding\n";
    write(STDERR_FILENO, m1, sizeof(m1) - 1);
    /* print the signal number without snprintf (not async-signal-safe) */
    char num[8];
    int  n = 0, v = sig;
    if (v >= 10) { num[n++] = (char)('0' + (v / 10) % 10); }
    num[n++] = (char)('0' + v % 10);
    write(STDERR_FILENO, num, n);
    write(STDERR_FILENO, m2, sizeof(m2) - 1);
    longjmp(g_fault_jmp, 1);
}

static void install_fault_handlers()
{
    static bool done = false;
    if (done) { return; }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = fault_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;      /* keep the default mask behaviour simple */
    for (int s : {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE}) { sigaction(s, &sa, nullptr); }
    done = true;
}

/* ------------------------------------------------------------------ *
 * 2. stdio -> hilog capture.
 * ------------------------------------------------------------------ */
static int  g_pipe_r = -1;
static int  g_saved_out = -1;
static int  g_saved_err = -1;
static bool g_capture_on = false;

/* ------------------------------------------------------------------ *
 * Progress reporting.
 *
 * HandBrake prints its progress on stdout as
 *     "\rEncoding: task 1 of 1, 45.20 %"
 * (carriage-return separated), which is exactly what the CLI uses to animate
 * a terminal.  We parse it out of the same captured stream and forward the
 * percentage to ArkTS through a threadsafe function, so the UI gets a real
 * progress bar without touching libhb's job/pipeline code.
 * ------------------------------------------------------------------ */
static napi_threadsafe_function g_progress_tsfn = nullptr;
static napi_threadsafe_function g_line_tsfn = nullptr;

/* Delivers one raw CLI output line to ArkTS (used to parse --scan output). */
static void LineCallJs(napi_env env, napi_value js_cb, void * /*context*/, void *data)
{
    std::string *line = static_cast<std::string *>(data);
    if (env != nullptr && js_cb != nullptr && line != nullptr)
    {
        napi_value undefined = nullptr, arg = nullptr;
        napi_get_undefined(env, &undefined);
        napi_create_string_utf8(env, line->c_str(), NAPI_AUTO_LENGTH, &arg);
        napi_call_function(env, undefined, js_cb, 1, &arg, nullptr);
    }
    delete line;
}

static void ProgressCallJs(napi_env env, napi_value js_cb, void * /*context*/, void *data)
{
    double *pct = static_cast<double *>(data);
    if (env != nullptr && js_cb != nullptr)
    {
        napi_value undefined = nullptr, arg = nullptr;
        napi_get_undefined(env, &undefined);
        napi_create_double(env, *pct, &arg);
        napi_call_function(env, undefined, js_cb, 1, &arg, nullptr);
    }
    delete pct;
}

static void emit_progress(double pct)
{
    if (g_progress_tsfn == nullptr) { return; }
    double *p = new double(pct);
    if (napi_call_threadsafe_function(g_progress_tsfn, p, napi_tsfn_nonblocking) != napi_ok)
    {
        delete p;
    }
}

/* "Encoding: task 1 of 1, 45.20 %" -> 45.20 ; anything else -> -1 */
static double parse_progress(const std::string &line)
{
    const char *p = strstr(line.c_str(), "Encoding: task");
    if (p == nullptr) { return -1.0; }
    const char *comma = strchr(p, ',');
    if (comma == nullptr) { return -1.0; }
    double v = atof(comma + 1);
    if (v < 0.0) { v = 0.0; }
    if (v > 100.0) { v = 100.0; }
    return v;
}

static void handle_line(const std::string &line)
{
    if (line.empty()) { return; }
    LOGI("libhb: %s", line.c_str());
    double pct = parse_progress(line);
    if (pct >= 0.0)
    {
        emit_progress(pct);
        return;
    }
    if (g_line_tsfn != nullptr)
    {
        std::string *copy = new std::string(line);
        if (napi_call_threadsafe_function(g_line_tsfn, copy, napi_tsfn_nonblocking) != napi_ok)
        {
            delete copy;
        }
    }
}

static void *log_reader(void *)
{
    char        buf[512];
    std::string line;
    ssize_t     n;
    while ((n = read(g_pipe_r, buf, sizeof(buf))) > 0)
    {
        for (ssize_t i = 0; i < n; i++)
        {
            /* progress lines are terminated by CR, everything else by LF */
            if (buf[i] == '\n' || buf[i] == '\r')
            {
                handle_line(line);
                line.clear();
            }
            else if (line.size() < 400)
            {
                line.push_back(buf[i]);
            }
        }
    }
    handle_line(line);
    return nullptr;
}

static void start_stdio_capture()
{
    if (g_capture_on) { return; }
    int fds[2];
    if (pipe(fds) != 0) { LOGE("pipe() failed, CLI output will be lost"); return; }
    fflush(stdout);
    fflush(stderr);
    g_saved_out = dup(STDOUT_FILENO);
    g_saved_err = dup(STDERR_FILENO);
    g_pipe_r = fds[0];
    dup2(fds[1], STDOUT_FILENO);
    dup2(fds[1], STDERR_FILENO);
    close(fds[1]);
    /* libhb writes with fprintf; a pipe is block-buffered, so on SIGSEGV the
       tail of the log -- exactly the lines that say where it died -- would be
       lost.  Unbuffered makes every line reach the pipe immediately. */
    setvbuf(stdout, nullptr, _IONBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    /* the original stderr is kept so the fault handler never blocks on a full pipe */
    pthread_t th;
    if (pthread_create(&th, nullptr, log_reader, nullptr) == 0) { pthread_detach(th); }
    g_capture_on = true;
    LOGI("stdio capture on (fd 1/2 -> hilog tag %s)", LOG_TAG);
}

/* ------------------------------------------------------------------ *
 * Run HandBrakeCLI's entry point; return its exit status without exiting,
 * and turn a fatal signal into a distinct negative code.
 * ------------------------------------------------------------------ */
static int run_cli_inline(std::vector<char *> &argv)
{
    g_fault_sig = 0;
    if (setjmp(g_fault_jmp) != 0)
    {
        LOGE("run_cli recovered from signal %d", (int)g_fault_sig);
        return -1000 - (int)g_fault_sig;
    }
    g_exit_code = 0;
    if (setjmp(g_exit_jmp) == 0)
    {
        int rc = hbcli_main(static_cast<int>(argv.size()), argv.data());
        return rc;
    }
    return g_exit_code;
}

/* Run one CLI invocation inside a forked child.
 *
 * Why: HandBrake/libhb keep a lot of global state and, once a codec has
 * longjmp-ed out of a SIGSEGV, the process is not reusable -- the next
 * invocation in the same process reports nonsense (e.g. "Missing input
 * device") and crashes for unrelated reasons.  A fresh child per run gives
 * every test a clean libhb, isolates crashes, and lets the parent report the
 * exact termination signal via waitpid().
 */
static void run_cli_child(std::vector<char *> &argv) __attribute__((noreturn));
static void run_cli_child(std::vector<char *> &argv)
{
    /* Let a fault kill the child outright (waitpid -> WTERMSIG) instead of
       unwinding into the parent's jmp_buf, which is meaningless here. */
    for (int s : {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE}) { signal(s, SIG_DFL); }
    pthread_mutex_init(&g_log_mu, nullptr);

    g_exit_code = 0;
    if (setjmp(g_exit_jmp) == 0)
    {
        int rc = hbcli_main(static_cast<int>(argv.size()), argv.data());
        fflush(nullptr);
        _exit(rc & 0xFF);
    }
    fflush(nullptr);
    _exit(g_exit_code & 0xFF);
}

static volatile pid_t g_child_pid = 0;

static int run_cli(std::vector<char *> &argv)
{
    pid_t pid = fork();
    if (pid == 0)
    {
        run_cli_child(argv);          /* never returns */
    }
    if (pid < 0)
    {
        LOGE("fork() failed errno=%d -- falling back to in-process run", errno);
        return run_cli_inline(argv);
    }

    g_child_pid = pid;
    int status = 0;
    for (;;)
    {
        pid_t r = waitpid(pid, &status, 0);
        if (r == pid) { break; }
        if (r < 0 && errno == EINTR) { continue; }
        LOGE("waitpid failed errno=%d", errno);
        return -2;
    }

    g_child_pid = 0;
    if (WIFEXITED(status))
    {
        int rc = WEXITSTATUS(status);
        LOGI("child %d exited normally, rc=%d", (int)pid, rc);
        return rc;
    }
    if (WIFSIGNALED(status))
    {
        int sig = WTERMSIG(status);
        LOGE("child %d killed by signal %d (%s)", (int)pid, sig,
             sig == SIGSEGV ? "SIGSEGV" : sig == SIGBUS ? "SIGBUS" :
             sig == SIGABRT ? "SIGABRT" : sig == SIGILL ? "SIGILL" :
             sig == SIGFPE ? "SIGFPE" : "signal");
        return -1000 - sig;
    }
    LOGI("child %d ended abnormally, status=0x%x", (int)pid, status);
    return -3;
}

/* ------------------------------------------------------------------ *
 * Sandbox path setup -- REQUIRED before anything else touches libhb.
 *
 * libhb's SYS_LINUX temp-dir default is /tmp (see libhb/ports.c:
 * hb_init_temporary_directory(), `base = strdup("/tmp")`).  A HarmonyOS app
 * sandbox has no /tmp and cannot create one, so mkdtemp() fails, libhb logs
 * "Failed to create a temporary directory" and then keeps using the
 * non-existent path -- previews and temp files break, usually in confusing
 * ways far away from the root cause.
 *
 * hb_set_temporary_directory() is the documented public API for this, and it
 * latches through pthread_once(), so it MUST be called before the first libhb
 * call that resolves the temp dir.
 * ------------------------------------------------------------------ */
static bool g_paths_set = false;

static void set_sandbox_paths(const std::string &cacheDir, const std::string &filesDir)
{
    if (g_paths_set) { return; }
    if (!cacheDir.empty())
    {
        mkdir(cacheDir.c_str(), 0700);
        setenv("TMPDIR", cacheDir.c_str(), 1);
        hb_set_temporary_directory(cacheDir.c_str());
        LOGI("temp dir -> %s", cacheDir.c_str());
    }
    if (!filesDir.empty())
    {
        mkdir(filesDir.c_str(), 0700);
        setenv("XDG_CONFIG_HOME", filesDir.c_str(), 1);
        setenv("HOME", filesDir.c_str(), 1);
    }
    install_fault_handlers();
    start_stdio_capture();
    g_paths_set = true;
}

static std::string jstring(napi_env env, napi_value v)
{
    size_t n = 0;
    if (napi_get_value_string_utf8(env, v, nullptr, 0, &n) != napi_ok) { return std::string(); }
    std::string s(n, '\0');
    napi_get_value_string_utf8(env, v, &s[0], n + 1, &n);
    return s;
}

static napi_value HbVersion(napi_env env, napi_callback_info info)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, HB_PROJECT_VERSION, NAPI_AUTO_LENGTH, &result);
    return result;
}

/* hbSetPaths(cacheDir, filesDir) -- call this first. */
static napi_value HbSetPaths(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string cache = argc > 0 ? jstring(env, argv[0]) : std::string();
    std::string files = argc > 1 ? jstring(env, argv[1]) : std::string();
    set_sandbox_paths(cache, files);

    napi_value result = nullptr;
    napi_create_int32(env, g_paths_set ? 0 : -1, &result);
    return result;
}

/* hbTempDir() -- what libhb actually resolved the temp dir to. */
static napi_value HbTempDir(napi_env env, napi_callback_info info)
{
    const char *d = hb_get_temporary_directory();
    napi_value result = nullptr;
    napi_create_string_utf8(env, d ? d : "(null)", NAPI_AUTO_LENGTH, &result);
    return result;
}

/* ------------------------------------------------------------------ *
 * hbSetLogFile(path) -- tee every subsequent log line into this file.
 * Call right after hbSetPaths(); the parent directory must exist.
 * append mode + unbuffered write(2) means the tail of the log survives even
 * if the process dies inside the very next codec call.
 * ------------------------------------------------------------------ */
static napi_value HbSetLogFile(napi_env env, napi_callback_info info)
{
    size_t     argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string path = argc > 0 ? jstring(env, argv[0]) : std::string();
    int         rc   = -1;
    if (!path.empty())
    {
        if (g_log_fd >= 0) { close(g_log_fd); g_log_fd = -1; }
        g_log_fd = open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (g_log_fd >= 0)
        {
            rc = 0;
            char hdr[320];
            snprintf(hdr, sizeof(hdr), "===== log opened: %s =====\n", path.c_str());
            log_file_raw(hdr, strlen(hdr));
            LOGI("log file -> %s", path.c_str());
        }
        else
        {
            LOGE("open(%s) failed, errno=%d", path.c_str(), errno);
        }
    }

    napi_value result = nullptr;
    napi_create_int32(env, rc, &result);
    return result;
}

/* ------------------------------------------------------------------ *
 * Asynchronous: run HandBrakeCLI with the given argument vector and resolve
 * with its exit status (negative = fatal signal, see run_cli).
 * ------------------------------------------------------------------ */
struct CliWork {
    std::vector<std::string> args;
    std::vector<char *>      argv;
    int                      rc = -1;
    napi_async_work          work = nullptr;
    napi_deferred            deferred = nullptr;
};

static void CliExecute(napi_env env, void *data)
{
    CliWork *w = static_cast<CliWork *>(data);
    w->argv.clear();
    for (std::string &s : w->args) { w->argv.push_back(const_cast<char *>(s.c_str())); }
    std::string cmdline;
    for (const std::string &a : w->args)
    {
        if (!cmdline.empty()) { cmdline += ' '; }
        cmdline += a;
        if (cmdline.size() > 900) { cmdline += " ..."; break; }
    }
    LOGI("HandBrakeCLI: %zu args: %s", w->argv.size(), cmdline.c_str());
    w->rc = run_cli(w->argv);
    LOGI("HandBrakeCLI finished, rc=%d", w->rc);
}

static void CliComplete(napi_env env, napi_status status, void *data)
{
    CliWork *w = static_cast<CliWork *>(data);
    napi_value result = nullptr;
    napi_create_int32(env, w->rc, &result);
    napi_resolve_deferred(env, w->deferred, result);
    napi_delete_async_work(env, w->work);
    delete w;
}

static napi_value RunCli(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    /* Safety net: if ArkTS forgot hbSetPaths(), libhb would fall back to /tmp. */
    if (!g_paths_set)
    {
        const char *t = getenv("TMPDIR");
        const char *c = getenv("XDG_CONFIG_HOME");
        LOGE("hbSetPaths() was not called before runCli(); falling back to TMPDIR=%s",
             t ? t : "(unset)");
        set_sandbox_paths(t ? t : ".", c ? c : ".");
    }

    CliWork *w = new CliWork();

    bool isArray = false;
    napi_is_array(env, argv[0], &isArray);
    if (isArray)
    {
        uint32_t len = 0;
        napi_get_array_length(env, argv[0], &len);
        /* argv[0] is a conventional program name; HandBrake's parser starts at 1. */
        w->args.push_back("HandBrakeCLI");
        for (uint32_t i = 0; i < len; i++)
        {
            napi_value item = nullptr;
            napi_get_element(env, argv[0], i, &item);
            size_t n = 0;
            napi_get_value_string_utf8(env, item, nullptr, 0, &n);
            std::string s(n, '\0');
            napi_get_value_string_utf8(env, item, &s[0], n + 1, &n);
            w->args.push_back(s);
        }
    }

    napi_value promise = nullptr;
    napi_create_promise(env, &w->deferred, &promise);

    napi_value resource = nullptr;
    napi_create_string_utf8(env, "HandBrakeCLI", NAPI_AUTO_LENGTH, &resource);
    napi_create_async_work(env, nullptr, resource, CliExecute, CliComplete, w, &w->work);
    napi_queue_async_work(env, w->work);
    return promise;
}

/* hbSetLogCallback(fn) -- fn(line) for every CLI output line that is not a
   progress update.  The scan parser in ArkTS consumes these. */
static napi_value HbSetLogCallback(napi_env env, napi_callback_info info)
{
    size_t     argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_valuetype type = napi_undefined;
    if (argc < 1) { return nullptr; }
    napi_typeof(env, argv[0], &type);

    if (g_line_tsfn != nullptr)
    {
        napi_release_threadsafe_function(g_line_tsfn, napi_tsfn_abort);
        g_line_tsfn = nullptr;
    }
    if (type != napi_function)
    {
        return nullptr;
    }
    napi_value name = nullptr;
    napi_create_string_utf8(env, "hbLine", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, argv[0], nullptr, name,
                                    0, 1, nullptr, nullptr, nullptr,
                                    LineCallJs, &g_line_tsfn);
    return nullptr;
}

/* hbSetEnv(key, value) -- lets ArkTS point libass at a usable font file
   (HB_SUB_FONT): the build has no fontconfig, so a family name cannot be
   resolved and libass needs an explicit font path. */
static napi_value HbSetEnv(napi_env env, napi_callback_info info)
{
    size_t     argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string key   = argc > 0 ? jstring(env, argv[0]) : std::string();
    std::string value = argc > 1 ? jstring(env, argv[1]) : std::string();
    int rc = -1;
    if (!key.empty())
    {
        rc = setenv(key.c_str(), value.c_str(), 1);
        LOGI("env %s=%s (rc=%d)", key.c_str(), value.c_str(), rc);
    }
    napi_value result = nullptr;
    napi_create_int32(env, rc, &result);
    return result;
}

/* hbSetProgressCallback(fn) -- fn(percent) is called from the log reader thread. */
static napi_value HbSetProgressCallback(napi_env env, napi_callback_info info)
{
    size_t     argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    napi_valuetype type = napi_undefined;
    if (argc < 1) { return nullptr; }
    napi_typeof(env, argv[0], &type);

    if (g_progress_tsfn != nullptr)
    {
        napi_release_threadsafe_function(g_progress_tsfn, napi_tsfn_abort);
        g_progress_tsfn = nullptr;
    }
    if (type != napi_function)
    {
        return nullptr;
    }

    napi_value name = nullptr;
    napi_create_string_utf8(env, "hbProgress", NAPI_AUTO_LENGTH, &name);
    napi_create_threadsafe_function(env, argv[0], nullptr, name,
                                    0,                /* unlimited queue */
                                    1,                /* one thread (log reader) */
                                    nullptr, nullptr, nullptr,
                                    ProgressCallJs, &g_progress_tsfn);
    return nullptr;
}

/* hbCancel() -- kill the running CLI child (SIGKILL); no-op when idle. */
static napi_value HbCancel(napi_env env, napi_callback_info info)
{
    pid_t pid = g_child_pid;
    int   rc  = -1;
    if (pid > 0)
    {
        if (kill(pid, SIGKILL) == 0)
        {
            rc = 0;
            LOGE("hbCancel: killed child %d", (int)pid);
        }
        else
        {
            LOGE("hbCancel: kill(%d) failed errno=%d", (int)pid, errno);
        }
    }
    napi_value result = nullptr;
    napi_create_int32(env, rc, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"hbVersion", nullptr, HbVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hbSetPaths", nullptr, HbSetPaths, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hbTempDir", nullptr, HbTempDir, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hbSetLogFile", nullptr, HbSetLogFile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hbSetEnv",  nullptr, HbSetEnv,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hbSetLogCallback", nullptr, HbSetLogCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runCli",    nullptr, RunCli,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hbSetProgressCallback", nullptr, HbSetProgressCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hbCancel",  nullptr, HbCancel,  nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module hbModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "handbrake",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterHandBrakeModule(void)
{
    napi_module_register(&hbModule);
}
