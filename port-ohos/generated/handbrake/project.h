#ifndef HB_PROJECT_H
#define HB_PROJECT_H

/* Generated for the HandBrake -> HarmonyOS (OHOS arm64) port.
 *
 * Upstream generates this file with m4 from libhb/handbrake/project.h.m4
 * (which includes a handbrake.m4 written by make/configure.py).  We are not
 * using HandBrake's GNU-make build system for this port, so the substitutions
 * are done by hand.  Values mirror upstream 1.11.2; the HOST_* and FEATURE_*
 * blocks describe the OHOS target and the trimmed feature set.
 */

#define HB_PROJECT_TITLE                     "HandBrake 1.11.2 (HarmonyOS/OHOS arm64 port)"
#define HB_PROJECT_NAME                      "HandBrake"
#define HB_PROJECT_NAME_LOWER                "handbrake"
#define HB_PROJECT_NAME_UPPER                "HANDBRAKE"
#define HB_PROJECT_URL_WEBSITE               "https://handbrake.fr"
#define HB_PROJECT_URL_COMMUNITY             "https://forum.handbrake.fr"
#define HB_PROJECT_URL_IRC                   "irc://irc.freenode.net/handbrake"
#define HB_PROJECT_URL_APPCAST               "https://handbrake.fr/appcast_unstable.xml"
#define HB_PROJECT_VERSION_MAJOR             1
#define HB_PROJECT_VERSION_MINOR             11
#define HB_PROJECT_VERSION_POINT             2
#define HB_PROJECT_VERSION                   "1.11.2"
#define HB_PROJECT_VERSION_HEX               0x00010b0200000001LL
#define HB_PROJECT_BUILD                     2026060701
#define HB_PROJECT_REPO_URL                  "https://github.com/HandBrake/HandBrake"
#define HB_PROJECT_REPO_TAG                  "1.11.2"
#define HB_PROJECT_REPO_REV                  0
#define HB_PROJECT_REPO_HASH                 "9eb6c936803e8b071035b1a77662cb0db58441ea"
#define HB_PROJECT_REPO_BRANCH               "master"
#define HB_PROJECT_REPO_REMOTE               "origin"
#define HB_PROJECT_REPO_TYPE                 "release"
#define HB_PROJECT_REPO_OFFICIAL             1
#define HB_PROJECT_REPO_DATE                 "2026-06-07 13:36:41"

#define HB_PROJECT_HOST_SPEC                 "aarch64-linux-ohos"
#define HB_PROJECT_HOST_MACHINE              "aarch64"
#define HB_PROJECT_HOST_VENDOR               "unknown"
#define HB_PROJECT_HOST_SYSTEM               "linux"
#define HB_PROJECT_HOST_SYSTEMF              "HarmonyOS"
#define HB_PROJECT_HOST_RELEASE              ""
#define HB_PROJECT_HOST_TITLE                "HarmonyOS aarch64"
#define HB_PROJECT_HOST_ARCH                 "aarch64"

#define HB_PROJECT_FEATURE_ASM               0
#define HB_PROJECT_FEATURE_FDK_AAC           0
#define HB_PROJECT_FEATURE_FFMPEG_AAC        1
#define HB_PROJECT_FEATURE_FFMPEG_PRORES     1
#define HB_PROJECT_FEATURE_FLATPAK           0
#define HB_PROJECT_FEATURE_GTK               0
#define HB_PROJECT_FEATURE_MF                0
#define HB_PROJECT_FEATURE_NVENC             0
#define HB_PROJECT_FEATURE_NVDEC             0
#define HB_PROJECT_FEATURE_QSV               0
#define HB_PROJECT_FEATURE_VCE               0
#define HB_PROJECT_FEATURE_X265              1
#define HB_PROJECT_FEATURE_NUMA              0
#define HB_PROJECT_FEATURE_LIBDOVI           0

#define HB_PROJECT_SECURITY_HARDEN           0

#endif /* HB_PROJECT_PROJECT_H */
