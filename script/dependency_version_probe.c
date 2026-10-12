#include <libssh2.h>
#include <openssl/crypto.h>
#include <openssl/opensslv.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    const char *ssh = libssh2_version(0);
    if (!ssh || strcmp(ssh, LIBSSH2_VERSION) || OpenSSL_version_num() != OPENSSL_VERSION_NUMBER) {
        fprintf(stderr, "Static library/header version mismatch\n");
        return 1;
    }
    printf("libssh2=%s OpenSSL=%s runtime=%s\n", ssh, OPENSSL_VERSION_STR, OpenSSL_version(OPENSSL_VERSION));
    return 0;
}
