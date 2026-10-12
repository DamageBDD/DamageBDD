/* SPDX-License-Identifier: Apache-2.0
 * Session-bus adapter only. kdeconnectd owns wire protocol, TLS and pairing.
 * No clipboard monitoring. Completed shares become atomic local manifests.
 */
#define _GNU_SOURCE
#include <gio/gio.h>
#include <glib-unix.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

static GMainLoop *loop;
static int spool_fd = -1;
static const char *prefix = "/modules/kdeconnect/devices/";

static gboolean stop_input(gint fd, GIOCondition condition, gpointer data) {
    (void)condition; (void)data;
    char b[64];
    if (read(fd, b, sizeof b) <= 0) { g_main_loop_quit(loop); return G_SOURCE_REMOVE; }
    return G_SOURCE_CONTINUE;
}

static int write_all(int fd, const char *s, size_t n) {
    while (n) { ssize_t k = write(fd, s, n); if (k < 0 && errno == EINTR) continue;
        if (k <= 0) return -1;
        s += k; n -= (size_t)k;
    }
    return 0;
}

static void persist_event(const char *device, const char *kind, const char *value) {
    if (strlen(value) > 65536) return;
    /* Backpressure bounds metadata even if BEAM is stopped or intake is full. */
    char *fd_path = g_strdup_printf("/proc/self/fd/%d", spool_fd);
    GDir *dir = g_dir_open(fd_path, 0, NULL); g_free(fd_path);
    if (!dir) return;
    unsigned count = 0;
    while (g_dir_read_name(dir) && count <= 1024) count++;
    g_dir_close(dir);
    if (count >= 1024) { fputs("spool_full\n", stderr); return; }
    char *d = g_base64_encode((const guchar *)device, strlen(device));
    char *v = g_base64_encode((const guchar *)value, strlen(value));
    char *json = g_strdup_printf("{\"v\":1,\"transport\":\"kdeconnect\",\"device_b64\":\"%s\",\"kind\":\"%s\",\"value_b64\":\"%s\"}\n", d, kind, v);
    char *uuid = g_uuid_string_random();
    char *tmp = g_strdup_printf("%s.tmp", uuid), *name = g_strdup_printf("%s.json", uuid);
    int fd = openat(spool_fd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd >= 0) {
        int ok = write_all(fd, json, strlen(json)) == 0 && fsync(fd) == 0;
        if (close(fd) != 0) ok = 0;
        if (ok && renameat(spool_fd, tmp, spool_fd, name) == 0) {
            if (fsync(spool_fd) != 0) fputs("spool_sync_failed\n", stderr);
        } else { unlinkat(spool_fd, tmp, 0); fputs("spool_write_failed\n", stderr); }
    }
    g_free(d); g_free(v); g_free(json); g_free(uuid); g_free(tmp); g_free(name);
}

static void received(GDBusConnection *connection, const gchar *sender,
    const gchar *path, const gchar *interface, const gchar *signal,
    GVariant *parameters, gpointer data) {
    (void)interface; (void)data;
    if (!g_str_has_prefix(path, prefix) || !g_str_has_suffix(path, "/share")) return;
    size_t n = strlen(path) - strlen(prefix) - strlen("/share");
    if (n < 1 || n > 128) return;
    char *device = g_strndup(path + strlen(prefix), n);
    for (const char *p = device; *p; ++p)
        if (!(g_ascii_isalnum(*p) || *p == '_' || *p == '-')) { g_free(device); return; }
    if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(s)"))) { g_free(device); return; }
    /* Query the unique signal sender; a daemon restart cannot change whom
     * this check authenticates. The subscription filters the well-known name. */
    char *device_path = g_strdup_printf("%s%s", prefix, device);
    GVariant *reply = g_dbus_connection_call_sync(connection, sender, device_path,
        "org.freedesktop.DBus.Properties", "Get",
        g_variant_new("(ss)", "org.kde.kdeconnect.device", "isPaired"),
        G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, NULL, NULL);
    g_free(device_path);
    gboolean paired = FALSE;
    if (reply) {
        GVariant *inner; g_variant_get(reply, "(v)", &inner);
        if (g_variant_is_of_type(inner, G_VARIANT_TYPE_BOOLEAN)) paired = g_variant_get_boolean(inner);
        g_variant_unref(inner); g_variant_unref(reply);
    }
    if (paired) {
        const char *value; g_variant_get(parameters, "(&s)", &value);
        persist_event(device, strcmp(signal, "shareTextReceived") == 0 ? "text" : "uri", value);
    }
    g_free(device);
}

int main(int argc, char **argv) {
    if (argc != 2) { fputs("usage: erm_kdeconnect_share EVENT_DIRECTORY\n", stderr); return 2; }
    umask(0077);
    spool_fd = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (spool_fd < 0 || fstat(spool_fd, &st) || st.st_uid != getuid() || (st.st_mode & 0077)) return 3;
    GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!connection) { close(spool_fd); return 4; }
    g_dbus_connection_signal_subscribe(connection, "org.kde.kdeconnect",
        "org.kde.kdeconnect.device.share", "shareReceived", NULL, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, received, NULL, NULL);
    /* Optional companion upstream patch adds an explicit text-share signal. */
    g_dbus_connection_signal_subscribe(connection, "org.kde.kdeconnect",
        "org.kde.kdeconnect.device.share", "shareTextReceived", NULL, NULL,
        G_DBUS_SIGNAL_FLAGS_NONE, received, NULL, NULL);
    loop = g_main_loop_new(NULL, FALSE);
    g_unix_fd_add(STDIN_FILENO, G_IO_IN | G_IO_HUP | G_IO_ERR, stop_input, NULL);
    puts("ready"); fflush(stdout);
    g_main_loop_run(loop);
    g_main_loop_unref(loop); g_object_unref(connection); close(spool_fd); return 0;
}
