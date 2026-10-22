/* ohos_stubs.c -- HandBrake -> HarmonyOS (OHOS arm64) platform adaptation layer.
 *
 * Upstream HandBrake compiles every libhb/*.c unconditionally
 * (`LIBHB.c = $(wildcard $(LIBHB.src/)*.c)` in libhb/module.defs) and has no
 * configure switch to drop individual libhb sources.  It therefore *hard*
 * requires ~26 third-party libraries.
 *
 * For this port we deliberately trim the feature set to "file-based video
 * transcoding" and drop six libraries whose cross-compilation was out of scope:
 *
 *   libtheora      -> enctheora.c     (Theora video encoder)
 *   libvorbis      -> encvorbis.c     (Vorbis audio encoder)
 *   SVT-AV1        -> encsvtav1.c     (AV1 video encoder)
 *   libdvdread     -> dvd.c           (DVD-Video source)
 *   libdvdnav      -> dvdnav.c        (DVD-Video navigation)
 *   libbluray      -> bd.c            (Blu-ray source)
 *   libass (+fribidi/harfbuzz/freetype/fontconfig) -> rendersub.c (subtitle burn-in)
 *
 * Dropping those .c files leaves the following symbols undefined, because they
 * are referenced unconditionally by hb.c / common.c / param.c / work.c /
 * reader.c / scan.c.  This file supplies inert replacements so that libhb links
 * and, crucially, fails *gracefully* with a clear log message if a user selects
 * a trimmed feature instead of crashing or behaving unpredictably.
 */

#include "handbrake/handbrake.h"
#include "handbrake/internal.h"

/* ------------------------------------------------------------------ *
 * Work objects for the trimmed encoders.
 *
 * HB_PROJECT_FEATURE_X265 guards hb_encx265 in hb.c, but hb_enctheora,
 * hb_encvorbis and hb_encsvtav1 are registered unconditionally
 * (hb.c: hb_global_init()), so they must exist at link time.
 * ------------------------------------------------------------------ */

static int ohos_trimmed_work_init(hb_work_object_t *w, hb_job_t *job)
{
    hb_error("%s is not available in this HarmonyOS build of HandBrake.",
             w->name);
    return -1;
}

static int ohos_trimmed_work_work(hb_work_object_t *w,
                                  hb_buffer_t **buf_in,
                                  hb_buffer_t **buf_out)
{
    return HB_WORK_ERROR;
}

static void ohos_trimmed_work_close(hb_work_object_t *w)
{
    /* nothing to release */
}

hb_work_object_t hb_enctheora =
{
    WORK_ENCTHEORA,
    "Theora encoder (libtheora - not built for OHOS)",
    ohos_trimmed_work_init,
    ohos_trimmed_work_work,
    ohos_trimmed_work_close
};

hb_work_object_t hb_encvorbis =
{
    WORK_ENCVORBIS,
    "Vorbis encoder (libvorbis - not built for OHOS)",
    ohos_trimmed_work_init,
    ohos_trimmed_work_work,
    ohos_trimmed_work_close
};

hb_work_object_t hb_encsvtav1 =
{
    WORK_ENCSVTAV1,
    "SVT-AV1 encoder (SVT-AV1 - not built for OHOS)",
    ohos_trimmed_work_init,
    ohos_trimmed_work_work,
    ohos_trimmed_work_close
};

/* ------------------------------------------------------------------ *
 * Optical-disc sources (dvd.c / dvdnav.c / bd.c).
 * reader.c and scan.c call these unconditionally; returning NULL makes them
 * treat the path as "not a disc" and fall through to the FFmpeg file reader,
 * which is exactly the behaviour we want.
 * ------------------------------------------------------------------ */

hb_dvd_t *hb_dvd_init(hb_handle_t *h, const char *path)
{
    return NULL;
}

/* Public API (declared in handbrake/handbrake.h), defined in the excluded
 * dvd.c.  The CLI frontend calls it to choose dvdnav over dvdread; with no disc
 * support at all the setting is meaningless, so accept and ignore it. */
void hb_dvd_set_dvdnav(int enable)
{
    (void)enable;
}

hb_bd_t *hb_bd_init(hb_handle_t *h, const char *path,
                    int keep_duplicate_titles)
{
    return NULL;
}

/* hb_dvd_init()/hb_bd_init() always return NULL above, so scan.c and reader.c
 * never reach the facades below.  They still have to exist for the link, because
 * upstream's dvd.c/dvdnav.c/bd.c define both the facade layer (which dispatches
 * through hb_dvd_func_t / hb_bd_func_t method tables) and the implementations. */

int          hb_dvd_title_count(hb_dvd_t *d)                    { return 0; }
hb_title_t * hb_dvd_title_scan(hb_dvd_t *d, int title,
                               uint64_t min_duration,
                               uint64_t max_duration)           { return NULL; }
int          hb_dvd_start(hb_dvd_t *d, hb_title_t *title,
                          int chapter)                          { return 0; }
void         hb_dvd_stop(hb_dvd_t *d)                           { }
int          hb_dvd_seek(hb_dvd_t *d, float f)                  { return 0; }
hb_buffer_t *hb_dvd_read(hb_dvd_t *d)                           { return NULL; }
int          hb_dvd_chapter(hb_dvd_t *d)                        { return 0; }
void         hb_dvd_close(hb_dvd_t **d)                         { }
void         hb_dvd_set_angle(hb_dvd_t *d, int angle)           { }
int          hb_dvd_is_break(hb_dvd_t *d)                       { return 0; }
int          hb_dvd_angle_count(hb_dvd_t *d)                    { return 1; }
int          hb_dvd_main_feature(hb_dvd_t *d,
                                 hb_list_t *list_title)         { return 0; }

int          hb_bd_title_count(hb_bd_t *d)                      { return 0; }
hb_title_t * hb_bd_title_scan(hb_bd_t *d, int t,
                              uint64_t min_duration,
                              uint64_t max_duration)            { return NULL; }
int          hb_bd_start(hb_bd_t *d, hb_title_t *title)         { return 0; }
void         hb_bd_stop(hb_bd_t *d)                             { }
int          hb_bd_seek(hb_bd_t *d, float f)                    { return 0; }
int          hb_bd_seek_pts(hb_bd_t *d, uint64_t pts)           { return 0; }
int          hb_bd_seek_chapter(hb_bd_t *d, int chapter)        { return 0; }
hb_buffer_t *hb_bd_read(hb_bd_t *d)                             { return NULL; }
int          hb_bd_chapter(hb_bd_t *d)                          { return 0; }
void         hb_bd_close(hb_bd_t **d)                           { }
void         hb_bd_set_angle(hb_bd_t *d, int angle)             { }
int          hb_bd_main_feature(hb_bd_t *d,
                                hb_list_t *list_title)          { return 0; }
