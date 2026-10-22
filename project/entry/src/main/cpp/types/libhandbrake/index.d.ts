/* HandBrake NAPI surface (libhandbrake.so) */

/** libhb version string this build was produced from, e.g. "1.11.2". */
export const hbVersion: () => string;

/**
 * MUST be called before runCli().
 *
 * libhb's Linux temp-dir default is /tmp, which does not exist inside a
 * HarmonyOS app sandbox; this routes it to the app's cache dir via
 * hb_set_temporary_directory() and exports TMPDIR / XDG_CONFIG_HOME.
 * Returns 0 on success.
 */
export const hbSetPaths: (cacheDir: string, filesDir: string) => number;

/** The temp directory libhb actually resolved (evidence that hbSetPaths worked). */
export const hbTempDir: () => string;

/**
 * Tee every log line (libhb/x265 output included) into this file, append mode.
 * Call right after hbSetPaths(); the parent directory must already exist.
 * Returns 0 on success.
 */
export const hbSetLogFile: (path: string) => number;

/**
 * Register a progress callback. It is invoked on the JS thread with an
 * encoding percentage (0..100), parsed from HandBrakeCLI's own progress line.
 */
export const hbSetProgressCallback: (cb: (percent: number) => void) => void;

/** Kill the running CLI child process. Returns 0 if something was killed. */
export const hbCancel: () => number;

/** Set an environment variable for libhb (e.g. HB_SUB_FONT for libass). */
export const hbSetEnv: (key: string, value: string) => number;

/** fn(line) for every non-progress CLI output line (used for --scan parsing). */
export const hbSetLogCallback: (cb: (line: string) => void) => void;

/** Run HandBrakeCLI with the given argv (without the program name). Resolves to the exit status. */
export const runCli: (args: string[]) => Promise<number>;
