/* libbluray/bluray.h -- shim header for the HandBrake -> HarmonyOS port.
 *
 * libhb/stream.c includes this header unconditionally, but it never actually
 * calls a single libbluray function: the only "bd_" identifiers it uses are its
 * own struct field (bd_substream_id), HandBrake's own HB_SUBSTREAM_BD_* macros,
 * and FFmpeg's AV_CODEC_ID_PCM_BLURAY.  The include is vestigial.
 *
 * The real libbluray consumer is libhb/bd.c, which this port excludes together
 * with dvd.c/dvdnav.c (optical-disc sources) and replaces with an inert
 * hb_bd_init() in stubs/ohos_stubs.c.
 *
 * Having this shim on the include path lets unmodified stream.c compile, which
 * keeps the port's delta against upstream at zero for that file.
 */
#ifndef HB_PORT_SHIM_LIBBLURAY_BLURAY_H
#define HB_PORT_SHIM_LIBBLURAY_BLURAY_H

/* intentionally empty -- see the comment above */

#endif /* HB_PORT_SHIM_LIBBLURAY_BLURAY_H */
