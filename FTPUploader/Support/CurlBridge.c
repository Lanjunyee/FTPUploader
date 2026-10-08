#include "CurlBridge.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <sys/socket.h>
#include <unistd.h>

static pthread_once_t initialization = PTHREAD_ONCE_INIT;
static CURLcode initialization_result;
static void initialize_curl(void) { initialization_result = curl_global_init(CURL_GLOBAL_DEFAULT); }

typedef struct {
    FTPDataCallback data;
    FTPCancelCallback cancel;
    FTPProgressCallback progress;
    void *context;
    FILE *file;
    int64_t file_size;
    int64_t last_download;
    int64_t last_upload;
    double last_change;
    long stall_timeout;
    int downloading;
    int timed_out;
    int read_failed;
    const char *password;
    char response[512];
    curl_socket_t sockets[16];
    size_t socket_count;
} Transfer;

// Keep only live descriptors owned by this handle. Shutdown before removal
// prevents FTP cleanup from waiting for a delayed final response or QUIT.
static curl_socket_t open_socket(void *pointer, curlsocktype purpose, struct curl_sockaddr *address) {
    Transfer *transfer = pointer;
    (void)purpose;
    if (transfer->socket_count == 16) return CURL_SOCKET_BAD;
    curl_socket_t descriptor = socket(address->family, address->socktype, address->protocol);
    if (descriptor != CURL_SOCKET_BAD) transfer->sockets[transfer->socket_count++] = descriptor;
    return descriptor;
}

static int close_socket(void *pointer, curl_socket_t descriptor) {
    Transfer *transfer = pointer;
    for (size_t index = 0; index < transfer->socket_count; ++index) {
        if (transfer->sockets[index] == descriptor) {
            transfer->sockets[index] = transfer->sockets[--transfer->socket_count];
            break;
        }
    }
    return close(descriptor);
}

static int cancelled(Transfer *transfer) {
    if (!transfer->cancel || !transfer->cancel(transfer->context)) return 0;
    for (size_t index = 0; index < transfer->socket_count; ++index)
        shutdown(transfer->sockets[index], SHUT_RDWR);
    return 1;
}

// Redact from the full response before truncating the displayed error.
static void copy_redacted(char *out, size_t capacity, const char *input, size_t length, const char *password, int truncated) {
    size_t written = 0;
    size_t secret_length = password ? strlen(password) : 0;
    for (size_t index = 0; index < length && written + 1 < capacity;) {
        size_t remaining = length - index;
        int full_match = secret_length && secret_length <= remaining && !memcmp(input + index, password, secret_length);
        // libcurl owns its fixed error buffer. If it filled that buffer, also
        // remove a trailing password prefix that it may have truncated.
        int partial_match = truncated && remaining && remaining < secret_length && !memcmp(input + index, password, remaining);
        if (full_match || partial_match) {
            const char *replacement = "[redacted]";
            for (size_t i = 0; replacement[i] && written + 1 < capacity; ++i) out[written++] = replacement[i];
            index += full_match ? secret_length : remaining;
        } else { out[written++] = input[index++]; }
    }
    out[written] = 0;
}

static double monotonic_seconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1000000000.0;
}

static size_t receive_data(char *bytes, size_t size, size_t count, void *pointer) {
    Transfer *transfer = pointer;
    size_t length = size * count;
    if (transfer->data && !transfer->data((const unsigned char *)bytes, length, transfer->context)) return 0;
    return length;
}

static size_t receive_header(char *bytes, size_t size, size_t count, void *pointer) {
    Transfer *transfer = pointer;
    size_t length = size * count;
    if (length >= 3 && bytes[0] >= '0' && bytes[0] <= '9' && bytes[1] >= '0' && bytes[1] <= '9' && bytes[2] >= '0' && bytes[2] <= '9') {
        copy_redacted(transfer->response, sizeof(transfer->response), bytes, length, transfer->password, 0);
        size_t copied = strlen(transfer->response);
        while (copied && (transfer->response[copied - 1] == '\r' || transfer->response[copied - 1] == '\n')) --copied;
        transfer->response[copied] = 0;
    }
    return length;
}

static size_t read_file(char *bytes, size_t size, size_t count, void *pointer) {
    Transfer *transfer = pointer;
    size_t length = fread(bytes, 1, size * count, transfer->file);
    if (ferror(transfer->file)) {
        transfer->read_failed = 1;
        return CURL_READFUNC_ABORT;
    }
    return length;
}

static int update_progress(void *pointer, curl_off_t download_total, curl_off_t downloaded,
                           curl_off_t upload_total, curl_off_t uploaded) {
    Transfer *transfer = pointer;
    if (cancelled(transfer)) return 1;
    (void)download_total;
    (void)upload_total;
    double now = monotonic_seconds();
    if (downloaded != transfer->last_download || uploaded != transfer->last_upload) {
        transfer->last_change = now;
        transfer->last_download = downloaded;
        transfer->last_upload = uploaded;
    }
    if (transfer->progress) transfer->progress(transfer->downloading ? downloaded : uploaded, transfer->downloading ? (download_total > 0 ? download_total : -1) : transfer->file_size, transfer->context);
    if (now - transfer->last_change >= transfer->stall_timeout) {
        transfer->timed_out = 1;
        return 1;
    }
    return 0;
}

static FTPResult perform(const char *url, const char *method, const char *file_path, const char *username, const char *password,
                               FTPOptions options, Transfer *transfer) {
    FTPResult result = {0};
    pthread_once(&initialization, initialize_curl);
    if (initialization_result != CURLE_OK) {
        result.code = initialization_result;
        snprintf(result.message, sizeof(result.message), "Unable to initialize system transfer library");
        return result;
    }
    if (options.tls_mode && !ftps_available()) {
        result.code = CURLE_NOT_BUILT_IN;
        snprintf(result.message, sizeof(result.message), "TLS transport is unavailable; no credentials sent");
        return result;
    }
    CURL *curl = curl_easy_init();
    if (!curl) {
        result.code = CURLE_OUT_OF_MEMORY;
        snprintf(result.message, sizeof(result.message), "Unable to allocate transfer handle");
        return result;
    }
    char error[CURL_ERROR_SIZE] = {0};
    struct curl_slist *commands = NULL;
    CURLcode setup = CURLE_OK;
    CURLM *multi = NULL;
    int added = 0;
    transfer->last_change = monotonic_seconds();
    transfer->stall_timeout = options.stall_timeout;
    transfer->password = password;

#define SET(option, value) do { setup = curl_easy_setopt(curl, option, value); if (setup != CURLE_OK) goto cleanup; } while (0)
    SET(CURLOPT_OPENSOCKETFUNCTION, open_socket);
    SET(CURLOPT_OPENSOCKETDATA, transfer);
    SET(CURLOPT_CLOSESOCKETFUNCTION, close_socket);
    SET(CURLOPT_CLOSESOCKETDATA, transfer);
    SET(CURLOPT_URL, url);
    SET(CURLOPT_PROTOCOLS_STR, options.tls_mode == 2 ? "ftps" : "ftp");
    SET(CURLOPT_USE_SSL, options.tls_mode ? (long)CURLUSESSL_ALL : (long)CURLUSESSL_NONE);
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    if (options.ca_file) SET(CURLOPT_CAINFO, options.ca_file);
    SET(CURLOPT_USERNAME, username);
    SET(CURLOPT_PASSWORD, password);
    SET(CURLOPT_PROXY, "");
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_CONNECTTIMEOUT, options.connect_timeout);
    SET(CURLOPT_SERVER_RESPONSE_TIMEOUT, options.response_timeout);
    SET(CURLOPT_ERRORBUFFER, error);
    SET(CURLOPT_HEADERFUNCTION, receive_header);
    SET(CURLOPT_HEADERDATA, transfer);
    SET(CURLOPT_WRITEFUNCTION, receive_data);
    SET(CURLOPT_WRITEDATA, transfer);
    SET(CURLOPT_NOPROGRESS, 0L);
    SET(CURLOPT_XFERINFOFUNCTION, update_progress);
    SET(CURLOPT_XFERINFODATA, transfer);
    commands = curl_slist_append(NULL, "*OPTS UTF8 ON");
    if (!commands) { setup = CURLE_OUT_OF_MEMORY; goto cleanup; }
    SET(CURLOPT_QUOTE, commands);
    if (file_path) {
        transfer->file = fopen(file_path, "rb");
        struct stat status;
        if (!transfer->file || fstat(fileno(transfer->file), &status) != 0 || !S_ISREG(status.st_mode)) {
            setup = CURLE_READ_ERROR;
            snprintf(error, sizeof(error), "Local file is not a readable regular file");
            goto cleanup;
        }
        transfer->file_size = status.st_size;
        result.expected_size = status.st_size;
        SET(CURLOPT_UPLOAD, 1L);
        SET(CURLOPT_TRANSFERTEXT, 0L);
        SET(CURLOPT_READFUNCTION, read_file);
        SET(CURLOPT_READDATA, transfer);
        SET(CURLOPT_INFILESIZE_LARGE, (curl_off_t)status.st_size);
        SET(CURLOPT_FTP_CREATE_MISSING_DIRS, 0L);
    } else {
        SET(CURLOPT_CUSTOMREQUEST, method);
    }
    // A bounded wait also observes cancellation while no progress callback runs
    // (greeting, connection, data stall, or final server acknowledgement).
    multi = curl_multi_init();
    if (!multi) { setup = CURLE_OUT_OF_MEMORY; goto cleanup; }
    if (cancelled(transfer)) {
        setup = CURLE_ABORTED_BY_CALLBACK; goto cleanup;
    }
    if (curl_multi_add_handle(multi, curl) != CURLM_OK) { setup = CURLE_FAILED_INIT; goto cleanup; }
    added = 1;
    int running = 1;
    while (running) {
        if (cancelled(transfer)) {
            setup = CURLE_ABORTED_BY_CALLBACK; break;
        }
        CURLMcode multi_code = curl_multi_perform(multi, &running);
        if (multi_code != CURLM_OK) { setup = CURLE_RECV_ERROR; break; }
        if (!running) {
            int remaining;
            CURLMsg *message;
            setup = CURLE_FAILED_INIT;
            while ((message = curl_multi_info_read(multi, &remaining))) {
                if (message->msg == CURLMSG_DONE && message->easy_handle == curl) setup = message->data.result;
            }
            break;
        }
        int descriptors;
        if (curl_multi_poll(multi, NULL, 0, 100, &descriptors) != CURLM_OK) {
            setup = CURLE_RECV_ERROR; break;
        }
    }
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &result.response_code);
    result.bytes_sent = transfer->last_upload;
    if (transfer->timed_out) setup = CURLE_OPERATION_TIMEDOUT;
    if (transfer->read_failed) setup = CURLE_READ_ERROR;
    if (setup == CURLE_OK && (result.response_code != 226 && result.response_code != 250)) setup = CURLE_FTP_WEIRD_SERVER_REPLY;
    if (setup == CURLE_OK && file_path && result.bytes_sent != result.expected_size) setup = CURLE_PARTIAL_FILE;

cleanup:
    result.code = setup;
    if (setup != CURLE_OK) {
        char sanitized[CURL_ERROR_SIZE];
        const char *detail = error[0] ? error : curl_easy_strerror(setup);
        copy_redacted(sanitized, sizeof(sanitized), detail, strlen(detail), password, error[0] && strlen(error) == sizeof(error) - 1);
        snprintf(result.message, sizeof(result.message), "%s%s%s", sanitized,
                 transfer->response[0] ? " — " : "", transfer->response);
    }
    if (added) curl_multi_remove_handle(multi, curl);
    if (multi) curl_multi_cleanup(multi);
    if (transfer->file) fclose(transfer->file);
    curl_slist_free_all(commands);
    curl_easy_cleanup(curl);
#undef SET
    return result;
}

int ftp_available(void) {
    const curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
    for (const char * const *protocol = info->protocols; *protocol; ++protocol) {
        if (strcmp(*protocol, "ftp") == 0) return 1;
    }
    return 0;
}

int ftps_available(void) {
    const curl_version_info_data *info = curl_version_info(CURLVERSION_NOW);
    if (!(info->features & CURL_VERSION_SSL)) return 0;
    for (const char * const *protocol = info->protocols; *protocol; ++protocol)
        if (strcmp(*protocol, "ftps") == 0) return 1;
    return 0;
}

const char *ftp_result_message(const FTPResult *result) { return result->message; }

FTPResult ftp_list(const char *url, const char *method, const char *username, const char *password, FTPOptions options,
                              FTPDataCallback callback, FTPCancelCallback cancel, void *context) {
    Transfer transfer = {.data = callback, .cancel = cancel, .context = context};
    return perform(url, method, NULL, username, password, options, &transfer);
}

FTPResult ftp_upload(const char *url, const char *file_path, const char *username, const char *password, FTPOptions options,
                                FTPProgressCallback callback, FTPCancelCallback cancel, void *context) {
    Transfer transfer = {.progress = callback, .cancel = cancel, .context = context};
    return perform(url, NULL, file_path, username, password, options, &transfer);
}

FTPResult ftp_download(const char *url, const char *username, const char *password, FTPOptions options,
                       FTPDataCallback data, FTPProgressCallback progress, FTPCancelCallback cancel, void *context) {
    Transfer transfer = {.data = data, .progress = progress, .cancel = cancel, .context = context, .downloading = 1};
    return perform(url, NULL, NULL, username, password, options, &transfer);
}
