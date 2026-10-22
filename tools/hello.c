#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/utsname.h>

int main(void) {
    struct utsname u;
    printf("hello from HarmonyOS native!\n");
    printf("compiled: %s %s\n", __DATE__, __TIME__);
    printf("sizeof(void*)=%zu  sizeof(long)=%zu\n", sizeof(void *), sizeof(long));
#ifdef __MUSL__
    printf("libc: musl (__MUSL__ defined)\n");
#else
    printf("libc: not musl\n");
#endif
    if (uname(&u) == 0) {
        printf("uname: sysname=%s release=%s machine=%s\n", u.sysname, u.release, u.machine);
    }
    printf("pid=%d\n", (int)getpid());
    fflush(stdout);
    return 0;
}
