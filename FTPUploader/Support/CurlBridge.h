#ifndef FTP_CURL_BRIDGE_H
#define FTP_CURL_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

typedef int (*FTPDataCallback)(const unsigned char *bytes, size_t length, void *context);
typedef void (*FTPProgressCallback)(int64_t sent, int64_t total, void *context);

typedef struct {
    long connect_timeout;
    long response_timeout;
    long stall_timeout;
} FTPOptions;

typedef struct {
    int code;
    long response_code;
    int64_t bytes_sent;
    int64_t expected_size;
    char message[768];
} FTPResult;

int ftp_available(void);
const char *ftp_result_message(const FTPResult *result);
FTPResult ftp_list(const char *url, const char *method, const char *username, const char *password, FTPOptions options,
                              FTPDataCallback callback, void *context);
FTPResult ftp_upload(const char *url, const char *file_path, const char *username, const char *password, FTPOptions options,
                                FTPProgressCallback callback, void *context);

#endif
