#include "SSHBridge.h"
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <sys/socket.h>
#include <netdb.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <sys/stat.h>
#include <stdlib.h>

static pthread_once_t ssh_once = PTHREAD_ONCE_INIT;
static int ssh_initialization;
static void initialize_ssh(void) { ssh_initialization = libssh2_init(0); }
static double ssh_now(void) {
    struct timespec value; clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}
typedef struct {
    int socket; LIBSSH2_SESSION *session; FTPOptions options;
    FTPCancelCallback cancel; void *context; double changed;
} SSHConnection;
static int wait_socket(SSHConnection *connection, double deadline) {
    if (connection->cancel && connection->cancel(connection->context)) return -1000;
    if (ssh_now() >= deadline) return -1001;
    int directions = connection->session ? libssh2_session_block_directions(connection->session) : LIBSSH2_SESSION_BLOCK_OUTBOUND;
    short events = 0;
    if (directions & LIBSSH2_SESSION_BLOCK_INBOUND) events |= POLLIN;
    if (directions & LIBSSH2_SESSION_BLOCK_OUTBOUND) events |= POLLOUT;
    struct pollfd descriptor = { connection->socket, events ? events : POLLIN | POLLOUT, 0 };
    int rc = poll(&descriptor, 1, 100);
    if (rc < 0 && errno != EINTR) return -1002;
    return 0;
}
// The resolver owns its input and result until both the waiter and worker
// release it. Cancellation stops waiting without touching a still-running DNS call.
typedef struct {
    pthread_mutex_t lock; pthread_cond_t ready; int references, done, code;
    char *host, *service; struct addrinfo *addresses;
} SSHResolver;
static void release_resolver(SSHResolver *resolver) {
    pthread_mutex_lock(&resolver->lock); int last = --resolver->references == 0; pthread_mutex_unlock(&resolver->lock);
    if (last) {
        if (resolver->addresses) freeaddrinfo(resolver->addresses);
        free(resolver->host); free(resolver->service);
        pthread_cond_destroy(&resolver->ready); pthread_mutex_destroy(&resolver->lock); free(resolver);
    }
}
static void *resolve_worker(void *pointer) {
    SSHResolver *resolver = pointer;
    struct addrinfo hints = {0}, *addresses = NULL; hints.ai_socktype = SOCK_STREAM; hints.ai_family = AF_UNSPEC;
    int code = getaddrinfo(resolver->host, resolver->service, &hints, &addresses);
    pthread_mutex_lock(&resolver->lock);
    resolver->addresses = addresses; resolver->code = code; resolver->done = 1;
    pthread_cond_signal(&resolver->ready); pthread_mutex_unlock(&resolver->lock);
    release_resolver(resolver); return NULL;
}
static int resolve_host(SSHConnection *connection, const char *host, const char *service, double deadline, struct addrinfo **addresses) {
    SSHResolver *resolver = calloc(1, sizeof(*resolver)); if (!resolver) return -1002;
    resolver->host = strdup(host); resolver->service = strdup(service); resolver->references = 2;
    pthread_mutex_init(&resolver->lock, NULL); pthread_cond_init(&resolver->ready, NULL);
    pthread_t worker;
    if (!resolver->host || !resolver->service || pthread_create(&worker, NULL, resolve_worker, resolver)) {
        release_resolver(resolver); release_resolver(resolver); return -1002;
    }
    pthread_detach(worker);
    int code = 0; pthread_mutex_lock(&resolver->lock);
    while (!resolver->done) {
        if (connection->cancel && connection->cancel(connection->context)) { code = -1000; break; }
        if (ssh_now() >= deadline) { code = -1001; break; }
        struct timespec until; clock_gettime(CLOCK_REALTIME, &until); until.tv_nsec += 100000000;
        if (until.tv_nsec >= 1000000000) { ++until.tv_sec; until.tv_nsec -= 1000000000; }
        pthread_cond_timedwait(&resolver->ready, &resolver->lock, &until);
    }
    if (!code) {
        if (resolver->code) code = -1002;
        else { *addresses = resolver->addresses; resolver->addresses = NULL; }
    }
    pthread_mutex_unlock(&resolver->lock); release_resolver(resolver); return code;
}
static int connect_host(SSHConnection *connection, const char *host, int port) {
    char service[8]; snprintf(service, sizeof(service), "%d", port);
    double deadline = ssh_now() + connection->options.connect_timeout;
    struct addrinfo *addresses = NULL;
    int resolved = resolve_host(connection, host, service, deadline, &addresses); if (resolved) return resolved;
    int rc = -1002;
    for (struct addrinfo *address = addresses; address; address = address->ai_next) {
        connection->socket = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (connection->socket < 0) continue;
        fcntl(connection->socket, F_SETFL, O_NONBLOCK);
        int result = connect(connection->socket, address->ai_addr, address->ai_addrlen);
        if (!result) { rc = 0; break; }
        if (errno == EINPROGRESS) {
            for (;;) {
                rc = wait_socket(connection, deadline); if (rc) break;
                int error = 0; socklen_t length = sizeof(error);
                struct pollfd descriptor = { connection->socket, POLLOUT, 0 };
                if (poll(&descriptor, 1, 0) > 0) {
                    if (!getsockopt(connection->socket, SOL_SOCKET, SO_ERROR, &error, &length) && !error) rc = 0;
                    else rc = -1002;
                    break;
                }
            }
        }
        if (!rc) break;
        close(connection->socket); connection->socket = -1;
        if (rc == -1000 || rc == -1001) break;
    }
    freeaddrinfo(addresses); return rc;
}
static int handshake(SSHConnection *connection, const char *host, int port, SSHHostCallback hostkey) {
    pthread_once(&ssh_once, initialize_ssh);
    if (ssh_initialization) return ssh_initialization;
    if (connection->cancel && connection->cancel(connection->context)) return -1000;
    int rc = connect_host(connection, host, port); if (rc) return rc;
    connection->session = libssh2_session_init(); if (!connection->session) return -1002;
    libssh2_session_set_blocking(connection->session, 0);
    double deadline = ssh_now() + connection->options.response_timeout;
    while ((rc = libssh2_session_handshake(connection->session, connection->socket)) == LIBSSH2_ERROR_EAGAIN) {
        rc = wait_socket(connection, deadline); if (rc) return rc;
    }
    if (rc) return rc;
    size_t length = 0; int type = 0;
    const char *key = libssh2_session_hostkey(connection->session, &length, &type);
    if (!key || !hostkey || !hostkey((const unsigned char *)key, length, type, connection->context)) return -1003;
    return 0;
}
static void cleanup_ssh(SSHConnection *connection) {
    if (connection->socket >= 0) shutdown(connection->socket, SHUT_RDWR);
    if (connection->session) libssh2_session_free(connection->session);
    if (connection->socket >= 0) close(connection->socket);
}
static SSHResult ssh_result(SSHConnection *connection, int code, unsigned long status) {
    SSHResult result = {.code = code, .status = status};
    // Do not copy server-provided free text: it can echo credentials, including
    // a truncated secret. Keep the actual SSH/SFTP numeric result and operation.
    if (code) snprintf(result.message, sizeof(result.message), "SSH operation failed (%d), SFTP status %lu", code, status);
    cleanup_ssh(connection); return result;
}
SSHResult ssh_probe(const char *host, int port, FTPOptions options, SSHHostCallback hostkey, FTPCancelCallback cancel, void *context) {
    SSHConnection connection = {.socket = -1, .options = options, .cancel = cancel, .context = context};
    return ssh_result(&connection, handshake(&connection, host, port, hostkey), 0);
}
const char *ssh_result_message(const SSHResult *result) { return result->message; }

static int authenticate(SSHConnection *connection, const char *username, const char *password) {
    if (connection->cancel && connection->cancel(connection->context)) return -1000;
    int rc; double deadline = ssh_now() + connection->options.response_timeout;
    while ((rc = libssh2_userauth_password_ex(connection->session, username, (unsigned int)strlen(username), password, (unsigned int)strlen(password), NULL)) == LIBSSH2_ERROR_EAGAIN) {
        rc = wait_socket(connection, deadline); if (rc) return rc;
    }
    return rc;
}
static LIBSSH2_SFTP *open_sftp(SSHConnection *connection, int *code) {
    LIBSSH2_SFTP *sftp; double deadline = ssh_now() + connection->options.response_timeout;
    while (!(sftp = libssh2_sftp_init(connection->session))) {
        *code = libssh2_session_last_errno(connection->session);
        if (*code != LIBSSH2_ERROR_EAGAIN) return NULL;
        *code = wait_socket(connection, deadline); if (*code) return NULL;
    }
    *code = 0; return sftp;
}
static LIBSSH2_SFTP_HANDLE *open_handle(SSHConnection *connection, LIBSSH2_SFTP *sftp, const char *path, int upload, int *code) {
    LIBSSH2_SFTP_HANDLE *handle; double deadline = ssh_now() + connection->options.response_timeout;
    unsigned long flags = upload ? LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC : 0;
    while (!(handle = libssh2_sftp_open_ex(sftp, path, (unsigned int)strlen(path), flags, 0644, upload ? LIBSSH2_SFTP_OPENFILE : LIBSSH2_SFTP_OPENDIR))) {
        *code = libssh2_session_last_errno(connection->session);
        if (*code != LIBSSH2_ERROR_EAGAIN) return NULL;
        *code = wait_socket(connection, deadline); if (*code) return NULL;
    }
    *code = 0; return handle;
}
static int close_handle(SSHConnection *connection, LIBSSH2_SFTP_HANDLE **handle) {
    int rc; double deadline = ssh_now() + connection->options.response_timeout;
    while ((rc = libssh2_sftp_close_handle(*handle)) == LIBSSH2_ERROR_EAGAIN) {
        rc = wait_socket(connection, deadline); if (rc) return rc;
    }
    // libssh2 frees a handle for every terminal close result, including failure.
    *handle = NULL;
    return rc;
}
static SSHResult finish_sftp(SSHConnection *connection, LIBSSH2_SFTP *sftp, LIBSSH2_SFTP_HANDLE *handle, int code) {
    unsigned long status = sftp ? libssh2_sftp_last_error(sftp) : 0;
    if (code && connection->socket >= 0) shutdown(connection->socket, SHUT_RDWR);
    if (handle && code) libssh2_sftp_close_handle(handle);
    if (sftp) {
        // Subsystem shutdown is bounded even when the server disappears.
        double deadline = ssh_now() + 1; int rc;
        while ((rc = libssh2_sftp_shutdown(sftp)) == LIBSSH2_ERROR_EAGAIN) {
            if (wait_socket(connection, deadline)) { shutdown(connection->socket, SHUT_RDWR); libssh2_sftp_shutdown(sftp); break; }
        }
    }
    return ssh_result(connection, code, status);
}
SSHResult ssh_list(const char *host, int port, const char *path, const char *username, const char *password, FTPOptions options,
                   SSHHostCallback hostkey, SSHEntryCallback entry, FTPCancelCallback cancel, void *context) {
    SSHConnection connection = {.socket = -1, .options = options, .cancel = cancel, .context = context};
    int code = handshake(&connection, host, port, hostkey);
    if (!code) code = authenticate(&connection, username, password);
    if (code) return ssh_result(&connection, code, 0);
    LIBSSH2_SFTP *sftp = open_sftp(&connection, &code);
    if (!sftp) return ssh_result(&connection, code, 0);
    LIBSSH2_SFTP_HANDLE *handle = open_handle(&connection, sftp, path, 0, &code);
    if (!handle) return finish_sftp(&connection, sftp, NULL, code);
    char name[65536]; LIBSSH2_SFTP_ATTRIBUTES attributes;
    double deadline = ssh_now() + options.stall_timeout;
    for (;;) {
        if (cancel && cancel(context)) { code = -1000; break; }
        memset(&attributes, 0, sizeof(attributes));
        int count = libssh2_sftp_readdir_ex(handle, name, sizeof(name), NULL, 0, &attributes);
        if (count == LIBSSH2_ERROR_EAGAIN) { code = wait_socket(&connection, deadline); if (code) break; continue; }
        if (count < 0) { code = count; break; }
        if (!count) break;
        deadline = ssh_now() + options.stall_timeout;
        if ((count == 1 && name[0] == '.') || (count == 2 && !memcmp(name, "..", 2))) continue;
        if (!(attributes.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS)) { code = -1004; break; }
        int directory = LIBSSH2_SFTP_S_ISDIR(attributes.permissions);
        int64_t size = attributes.flags & LIBSSH2_SFTP_ATTR_SIZE && attributes.filesize <= INT64_MAX ? (int64_t)attributes.filesize : -1;
        if (!entry || !entry((const unsigned char *)name, (size_t)count, directory, size, context)) { code = -1004; break; }
    }
    if (!code) { code = close_handle(&connection, &handle); }
    return finish_sftp(&connection, sftp, handle, code);
}
SSHResult ssh_upload(const char *host, int port, const char *path, const char *file, const char *username, const char *password, FTPOptions options,
                     SSHHostCallback hostkey, FTPProgressCallback progress, FTPCancelCallback cancel, void *context) {
    SSHConnection connection = {.socket = -1, .options = options, .cancel = cancel, .context = context};
    FILE *input = fopen(file, "rb"); struct stat attributes;
    if (!input || fstat(fileno(input), &attributes) || !S_ISREG(attributes.st_mode)) {
        if (input) fclose(input); return ssh_result(&connection, -1005, 0);
    }
    int code = handshake(&connection, host, port, hostkey);
    if (!code) code = authenticate(&connection, username, password);
    if (code) { fclose(input); return ssh_result(&connection, code, 0); }
    LIBSSH2_SFTP *sftp = open_sftp(&connection, &code);
    if (!sftp) { fclose(input); return ssh_result(&connection, code, 0); }
    LIBSSH2_SFTP_HANDLE *handle = open_handle(&connection, sftp, path, 1, &code);
    if (!handle) { fclose(input); return finish_sftp(&connection, sftp, NULL, code); }
    char buffer[32768]; int64_t sent = 0;
    double deadline = ssh_now() + options.stall_timeout;
    while (!code) {
        if (cancel && cancel(context)) { code = -1000; break; }
        size_t count = fread(buffer, 1, sizeof(buffer), input);
        if (ferror(input)) { code = -1005; break; }
        if (!count) break;
        size_t offset = 0;
        while (offset < count) {
            if (cancel && cancel(context)) { code = -1000; break; }
            ssize_t written = libssh2_sftp_write(handle, buffer + offset, count - offset);
            if (written == LIBSSH2_ERROR_EAGAIN || written == 0) { code = wait_socket(&connection, deadline); if (code) break; continue; }
            if (written < 0) { code = (int)written; break; }
            offset += written; sent += written; deadline = ssh_now() + options.stall_timeout;
            if (progress) progress(sent, attributes.st_size, context);
        }
    }
    fclose(input);
    if (!code && sent != attributes.st_size) code = -1005;
    if (!code) {
        if (progress) progress(sent, attributes.st_size, context);
        code = close_handle(&connection, &handle);
    }
    return finish_sftp(&connection, sftp, handle, code);
}

int ssh_available(void) { pthread_once(&ssh_once, initialize_ssh); return !ssh_initialization && libssh2_version(0x010B01) != NULL; }

SSHResult ssh_download(const char *host, int port, const char *path, const char *username, const char *password, FTPOptions options,
                       SSHHostCallback hostkey, FTPDataCallback data, FTPProgressCallback progress, FTPCancelCallback cancel, void *context) {
    SSHConnection connection = {.socket = -1, .options = options, .cancel = cancel, .context = context};
    int code = handshake(&connection, host, port, hostkey);
    if (!code) code = authenticate(&connection, username, password);
    if (code) return ssh_result(&connection, code, 0);
    LIBSSH2_SFTP *sftp = open_sftp(&connection, &code);
    if (!sftp) return ssh_result(&connection, code, 0);
    LIBSSH2_SFTP_HANDLE *handle = NULL;
    double deadline = ssh_now() + options.response_timeout;
    while (!(handle = libssh2_sftp_open_ex(sftp, path, (unsigned int)strlen(path), LIBSSH2_FXF_READ, 0, LIBSSH2_SFTP_OPENFILE))) {
        code = libssh2_session_last_errno(connection.session);
        if (code != LIBSSH2_ERROR_EAGAIN) return finish_sftp(&connection, sftp, NULL, code);
        code = wait_socket(&connection, deadline);
        if (code) return finish_sftp(&connection, sftp, NULL, code);
    }
    LIBSSH2_SFTP_ATTRIBUTES attributes = {0};
    while ((code = libssh2_sftp_fstat_ex(handle, &attributes, 0)) == LIBSSH2_ERROR_EAGAIN) {
        code = wait_socket(&connection, deadline); if (code) break;
    }
    if (code) return finish_sftp(&connection, sftp, handle, code);
    if (!(attributes.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) || !LIBSSH2_SFTP_S_ISREG(attributes.permissions))
        return finish_sftp(&connection, sftp, handle, -1004);
    int64_t total = attributes.flags & LIBSSH2_SFTP_ATTR_SIZE && attributes.filesize <= INT64_MAX ? (int64_t)attributes.filesize : -1;
    int64_t received = 0; char buffer[32768];
    deadline = ssh_now() + options.stall_timeout;
    while (!code) {
        if (cancel && cancel(context)) { code = -1000; break; }
        ssize_t count = libssh2_sftp_read(handle, buffer, sizeof(buffer));
        if (count == LIBSSH2_ERROR_EAGAIN) { code = wait_socket(&connection, deadline); if (code) break; continue; }
        if (count < 0) { code = (int)count; break; }
        if (!count) break;
        if (!data || !data((const unsigned char *)buffer, (size_t)count, context)) { code = -1005; break; }
        received += count; deadline = ssh_now() + options.stall_timeout;
        if (progress) progress(received, total, context);
    }
    if (!code && total >= 0 && received != total) code = -1005;
    if (!code) {
        if (progress) progress(received, total, context);
        code = close_handle(&connection, &handle);
    }
    return finish_sftp(&connection, sftp, handle, code);
}
