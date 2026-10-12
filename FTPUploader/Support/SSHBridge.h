#ifndef FTP_SSH_BRIDGE_H
#define FTP_SSH_BRIDGE_H
#include "CurlBridge.h"
typedef int (*SSHHostCallback)(const unsigned char *key, size_t length, int type, void *context);
typedef struct { int code; unsigned long status; int directory_attempted; char message[768]; } SSHResult;
SSHResult ssh_probe(const char *host, int port, FTPOptions options, SSHHostCallback hostkey, FTPCancelCallback cancel, void *context);
const char *ssh_result_message(const SSHResult *result);
/* Values match RemoteEntry.Kind; absent or unrecognized type is unknown. */
enum SSHEntryKind { SSH_ENTRY_UNKNOWN = 0, SSH_ENTRY_FILE = 1, SSH_ENTRY_DIRECTORY = 2, SSH_ENTRY_LINK = 3, SSH_ENTRY_OTHER = 4 };
typedef int (*SSHEntryCallback)(const unsigned char *name, size_t length, int kind, int64_t size, void *context);
SSHResult ssh_list(const char *host, int port, const char *path, const char *username, const char *password, const unsigned char *private_key, size_t private_key_len, const char *passphrase, FTPOptions options,
                   SSHHostCallback hostkey, SSHEntryCallback entry, FTPCancelCallback cancel, void *context);
SSHResult ssh_upload(const char *host, int port, const char *path, const char *file, const char *username, const char *password, const unsigned char *private_key, size_t private_key_len, const char *passphrase, FTPOptions options,
                     SSHHostCallback hostkey, FTPProgressCallback progress, FTPCancelCallback cancel, void *context);
/* Borrows the caller's validated fd and closes only its own duplicate. */
SSHResult ssh_upload_fd(const char *host, int port, const char *path, int file_fd, const char *username, const char *password,
                        const unsigned char *private_key, size_t private_key_len, const char *passphrase, FTPOptions options,
                        SSHHostCallback hostkey, FTPProgressCallback progress, FTPCancelCallback cancel, void *context);
SSHResult ssh_download(const char *host, int port, const char *path, const char *username, const char *password, const unsigned char *private_key, size_t private_key_len, const char *passphrase, FTPOptions options,
                       SSHHostCallback hostkey, FTPDataCallback data, FTPProgressCallback progress, FTPCancelCallback cancel, void *context);
SSHResult ssh_mkdir(const char *host, int port, const char *path, const char *username, const char *password,
                    const unsigned char *private_key, size_t private_key_len, const char *passphrase, FTPOptions options,
                    SSHHostCallback hostkey, FTPCancelCallback cancel, void *context);
/* Owner-local, serial-only cache. NULL preserves the per-operation API.
 * The caller binds endpoint/authentication/trust and must destroy after backend return. */
typedef struct SSHTransportSession SSHTransportSession;
SSHTransportSession *ssh_session_create(void);
void ssh_session_destroy(SSHTransportSession *session);
SSHResult ssh_session_list(SSHTransportSession *, const char *, int, const char *, const char *, const char *, const unsigned char *, size_t, const char *, FTPOptions, SSHHostCallback, SSHEntryCallback, FTPCancelCallback, void *);
SSHResult ssh_session_mkdir(SSHTransportSession *, const char *, int, const char *, const char *, const char *, const unsigned char *, size_t, const char *, FTPOptions, SSHHostCallback, FTPCancelCallback, void *);
SSHResult ssh_session_upload_fd(SSHTransportSession *, const char *, int, const char *, int, const char *, const char *, const unsigned char *, size_t, const char *, FTPOptions, SSHHostCallback, FTPProgressCallback, FTPCancelCallback, void *);
SSHResult ssh_session_download(SSHTransportSession *, const char *, int, const char *, const char *, const char *, const unsigned char *, size_t, const char *, FTPOptions, SSHHostCallback, FTPDataCallback, FTPProgressCallback, FTPCancelCallback, void *);
int ssh_available(void);
#endif
