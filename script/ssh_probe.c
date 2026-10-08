#include "SSHBridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double started;
static double seconds(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9; }
static int cancel(void *context) { return context && seconds()-started > 0.2; }
static int hostkey(const unsigned char *key, size_t length, int type, void *context) {
    (void)key;(void)context;printf("hostkey type=%d bytes=%zu\n",type,length);return length>0;
}
int main(int argc, char **argv) {
    if (argc<3) return 2;
    started=seconds();
    FTPOptions options={.connect_timeout=5,.response_timeout=5,.stall_timeout=5};
    SSHResult result=ssh_probe(argv[1],atoi(argv[2]),options,hostkey,cancel,argc>3?(void*)1:NULL);
    printf("result=%d elapsed=%.3f\n",result.code,seconds()-started);
    return argc>3 ? (result.code == -1000 ? 0:1) : (result.code?1:0);
}
