#ifndef FTP_SSH_BRIDGE_H
#define FTP_SSH_BRIDGE_H
#include "CurlBridge.h"
typedef int (*SSHHostCallback)(const unsigned char *key, size_t length, int type, void *context);
typedef struct { int code; unsigned long status; char message[768]; } SSHResult;
SSHResult ssh_probe(const char *host, int port, FTPOptions options, SSHHostCallback hostkey, FTPCancelCallback cancel, void *context);
const char *ssh_result_message(const SSHResult *result);
typedef int (*SSHEntryCallback)(const unsigned char *name, size_t length, int directory, int64_t size, void *context);
SSHResult ssh_list(const char *host, int port, const char *path, const char *username, const char *password, FTPOptions options,
                   SSHHostCallback hostkey, SSHEntryCallback entry, FTPCancelCallback cancel, void *context);
SSHResult ssh_upload(const char *host, int port, const char *path, const char *file, const char *username, const char *password, FTPOptions options,
                     SSHHostCallback hostkey, FTPProgressCallback progress, FTPCancelCallback cancel, void *context);
SSHResult ssh_download(const char *host, int port, const char *path, const char *username, const char *password, FTPOptions options,
                       SSHHostCallback hostkey, FTPDataCallback data, FTPProgressCallback progress, FTPCancelCallback cancel, void *context);
int ssh_available(void);
#endif
