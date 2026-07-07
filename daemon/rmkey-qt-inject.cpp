/* rmkey-qt-inject — LD_PRELOAD text injector for xochitl/Qt6.
 *
 * Listens on TCP 127.0.0.1:31338, reads framed protocol messages from
 * persistent connections, and commits received text/control-key events
 * to the current Qt focus object using synthetic QKeyEvent.
 *
 * Frame format (per message):
 *   uint8  type    — 0x01 = TEXT_UTF8, 0x02 = CONTROL_KEY
 *   uint32 length  — payload length, little-endian
 *   bytes[] payload — length bytes
 *
 * Deploy on tablet:
 *   cp librmkey_qt_inject.so /tmp/
 *   mkdir -p /run/systemd/system/xochitl.service.d
 *   cat >/run/systemd/system/xochitl.service.d/rm-key.conf <<'EOF'
 *   [Service]
 *   Environment=LD_PRELOAD=/tmp/librmkey_qt_inject.so
 *   EOF
 *   systemctl daemon-reload
 *   systemctl restart xochitl.service
 *   journalctl -u xochitl.service -f
 *
 * Send from tablet:
 *   printf '\x01\x05\x00\x00\x00hello' | nc 127.0.0.1 31338
 *   printf '\x02\x07\x00\x00\x00ENTER' | nc 127.0.0.1 31338
 *
 * Undo:
 *   rm -f /run/systemd/system/xochitl.service.d/rm-key.conf
 *   systemctl daemon-reload
 *   systemctl restart xochitl.service
 */

#include <QCoreApplication>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QMetaObject>
#include <QObject>
#include <QPointer>
#include <QString>
#include <QByteArray>
#include <QDebug>
#include <QThread>
#include <QWindow>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* ── constants ─────────────────────────────────────────────────────── */

static constexpr uint16_t DEFAULT_LISTEN_PORT = 31338;
static constexpr size_t  MAX_FRAME_SIZE       = 1024 * 1024;
static constexpr size_t  HEADER_SIZE          = 5;   /* 1 + 4 */
static constexpr uint8_t TYPE_TEXT_UTF8       = 0x01;
static constexpr uint8_t TYPE_CONTROL_KEY     = 0x02;
static const char       *LOG_PATH             = "/tmp/rmkey-qt-inject.log";

/* ── file logging ──────────────────────────────────────────────────── */

static void file_log(const char *msg) {
    FILE *f = fopen(LOG_PATH, "a");
    if (!f) return;
    fprintf(f, "%s\n", msg);
    fclose(f);
}

static void file_log_errno(const char *prefix) {
    FILE *f = fopen(LOG_PATH, "a");
    if (!f) return;
    fprintf(f, "%s: %s\n", prefix, strerror(errno));
    fclose(f);
}

/* ── control-key name → Qt::Key mapping ────────────────────────────── */

static Qt::Key map_control_key(const char *name, int len) {
    if (len == 9  && strncmp(name, "BACKSPACE", 9) == 0) return Qt::Key_Backspace;
    if (len == 6  && strncmp(name, "DELETE",  6) == 0) return Qt::Key_Delete;
    if (len == 5  && strncmp(name, "ENTER",   5) == 0) return Qt::Key_Return;
    if (len == 4  && strncmp(name, "LEFT",    4) == 0) return Qt::Key_Left;
    if (len == 5  && strncmp(name, "RIGHT",   5) == 0) return Qt::Key_Right;
    if (len == 2  && strncmp(name, "UP",      2) == 0) return Qt::Key_Up;
    if (len == 4  && strncmp(name, "DOWN",    4) == 0) return Qt::Key_Down;
    if (len == 3  && strncmp(name, "TAB",     3) == 0) return Qt::Key_Tab;
    if (len == 6  && strncmp(name, "ESCAPE",  6) == 0) return Qt::Key_Escape;
    if (len == 4  && strncmp(name, "HOME",    4) == 0) return Qt::Key_Home;
    if (len == 3  && strncmp(name, "END",     3) == 0) return Qt::Key_End;
    return Qt::Key_unknown;
}

/* ── dispatch text frame on Qt main thread ─────────────────────────── */

static void commit_text_on_qt_thread(const QString &text) {
    QObject *focus = QGuiApplication::focusObject();
    if (!focus) {
        qWarning() << "rmkey-qt-inject: no focus object, dropping text" << text;
        return;
    }

    QKeyEvent key_press(QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier,
                        text, false, 1);
    QCoreApplication::sendEvent(focus, &key_press);

    QKeyEvent key_release(QEvent::KeyRelease, Qt::Key_unknown, Qt::NoModifier,
                          QString(), false, 1);
    QCoreApplication::sendEvent(focus, &key_release);
}

static void queue_commit_text(const QString &text) {
    QCoreApplication *app = QCoreApplication::instance();
    if (!app) {
        qWarning() << "rmkey-qt-inject: cannot queue text; no app yet";
        return;
    }
    QPointer<QCoreApplication> app_ptr(app);
    QMetaObject::invokeMethod(app,
        [app_ptr, text]() {
            if (!app_ptr) return;
            commit_text_on_qt_thread(text);
        },
        Qt::QueuedConnection);
}

/* ── dispatch control-key frame on Qt main thread ──────────────────── */

static void commit_control_on_qt_thread(Qt::Key key) {
    QObject *focus = QGuiApplication::focusObject();
    if (!focus) {
        qWarning() << "rmkey-qt-inject: no focus object, dropping key" << key;
        return;
    }

    QKeyEvent key_press(QEvent::KeyPress, key, Qt::NoModifier,
                        QString(), false, 0);
    QCoreApplication::sendEvent(focus, &key_press);

    QKeyEvent key_release(QEvent::KeyRelease, key, Qt::NoModifier,
                          QString(), false, 0);
    QCoreApplication::sendEvent(focus, &key_release);

    /* Escape is often handled by window-level shortcuts rather than the
     * focused item. Unlike text, duplicating Escape does not insert content;
     * send it to the focus window as well so xochitl can handle global cancel
     * behavior.
     */
    if (key == Qt::Key_Escape) {
        QWindow *window = QGuiApplication::focusWindow();
        if (window) {
            QKeyEvent window_press(QEvent::KeyPress, key, Qt::NoModifier,
                                   QString(), false, 0);
            QCoreApplication::sendEvent(window, &window_press);

            QKeyEvent window_release(QEvent::KeyRelease, key, Qt::NoModifier,
                                     QString(), false, 0);
            QCoreApplication::sendEvent(window, &window_release);
        }
    }
}

static void queue_commit_control(Qt::Key key) {
    QCoreApplication *app = QCoreApplication::instance();
    if (!app) {
        qWarning() << "rmkey-qt-inject: cannot queue control; no app yet";
        return;
    }
    QPointer<QCoreApplication> app_ptr(app);
    QMetaObject::invokeMethod(app,
        [app_ptr, key]() {
            if (!app_ptr) return;
            commit_control_on_qt_thread(key);
        },
        Qt::QueuedConnection);
}

/* ── read exactly N bytes from a socket ────────────────────────────── */

static ssize_t read_exact(int fd, void *buf, size_t count) {
    size_t total = 0;
    char   *p   = static_cast<char *>(buf);
    while (total < count) {
        ssize_t n = read(fd, p + total, count - total);
        if (n <= 0) {
            return n < 0 ? -errno : 0;  /* 0 = EOF, negative = error */
        }
        total += static_cast<size_t>(n);
    }
    return static_cast<ssize_t>(total);
}

/* ── per-connection handler (runs in server thread) ────────────────── */

static void handle_client(int client_fd) {
    file_log("client connected");

    for (;;) {
        /* Read 5-byte header: type (1) + length (4 LE) */
        uint8_t  type_buf[1];
        uint32_t len_buf[1];

        ssize_t n = read_exact(client_fd, type_buf, sizeof(type_buf));
        if (n == 0) {
            file_log("client disconnected (EOF)");
            break;
        }
        if (n < 0) {
            char msg[128];
            snprintf(msg, sizeof(msg), "read header type failed: %s",
                     strerror(n > -256 ? -n : n));
            file_log(msg);
            break;
        }

        n = read_exact(client_fd, len_buf, sizeof(len_buf));
        if (n == 0) {
            file_log("client disconnected (EOF mid-header)");
            break;
        }
        if (n < 0) {
            char msg[128];
            snprintf(msg, sizeof(msg), "read header length failed: %s",
                     strerror(n > -256 ? -n : n));
            file_log(msg);
            break;
        }

        uint32_t length = static_cast<uint32_t>(len_buf[0]);

        if (length > MAX_FRAME_SIZE) {
            char msg[128];
            snprintf(msg, sizeof(msg),
                     "frame too large (%u bytes), disconnecting", length);
            file_log(msg);
            break;
        }

        /* Read payload */
        QByteArray payload(static_cast<int>(length), 0);
        n = read_exact(client_fd, payload.data(), length);
        if (n == 0) {
            file_log("client disconnected (EOF mid-payload)");
            break;
        }
        if (n < 0) {
            char msg[128];
            snprintf(msg, sizeof(msg), "read payload failed: %s",
                     strerror(n > -256 ? -n : n));
            file_log(msg);
            break;
        }

        /* Dispatch based on type */
        switch (type_buf[0]) {
        case TYPE_TEXT_UTF8: {
            QString text = QString::fromUtf8(payload);
            file_log("dispatching TEXT_UTF8 frame");
            queue_commit_text(text);
            break;
        }
        case TYPE_CONTROL_KEY: {
            Qt::Key key = map_control_key(payload.constData(),
                                          static_cast<int>(length));
            if (key != Qt::Key_unknown) {
                file_log("dispatching CONTROL_KEY frame");
                queue_commit_control(key);
            } else {
                char msg[128];
                snprintf(msg, sizeof(msg),
                         "unknown control key: ");
                file_log(msg);
                file_log(payload.constData());
            }
            break;
        }
        default: {
            char msg[128];
            snprintf(msg, sizeof(msg), "unknown frame type: 0x%02x",
                     type_buf[0]);
            file_log(msg);
            break;
        }
        }
    }

    close(client_fd);
}

/* ── TCP server thread ─────────────────────────────────────────────── */

static void *server_thread_main(void *) {
    file_log("server thread started");
    signal(SIGPIPE, SIG_IGN);

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        file_log_errno("socket failed");
        qWarning() << "rmkey-qt-inject: socket failed" << strerror(errno);
        return nullptr;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    uint16_t listen_port = DEFAULT_LISTEN_PORT;
    const char *port_env = getenv("RMKEY_INJECT_PORT");
    if (port_env && *port_env) {
        long parsed = strtol(port_env, nullptr, 10);
        if (parsed > 0 && parsed <= 65535) {
            listen_port = static_cast<uint16_t>(parsed);
        }
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   /* 127.0.0.1 only */
    addr.sin_port        = htons(listen_port);

    if (bind(server_fd, reinterpret_cast<struct sockaddr *>(&addr),
             sizeof(addr)) < 0) {
        file_log_errno("bind failed");
        qWarning() << "rmkey-qt-inject: bind 127.0.0.1:" << listen_port
                   << "failed" << strerror(errno);
        close(server_fd);
        return nullptr;
    }

    if (listen(server_fd, 8) < 0) {
        file_log_errno("listen failed");
        qWarning() << "rmkey-qt-inject: listen failed" << strerror(errno);
        close(server_fd);
        return nullptr;
    }

    {
        char msg[128];
        snprintf(msg, sizeof(msg), "listening on 127.0.0.1:%u", listen_port);
        file_log(msg);
    }
    qWarning() << "rmkey-qt-inject: listening on 127.0.0.1:" << listen_port;

    for (;;) {
        int client_fd = accept(server_fd, nullptr, nullptr);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            qWarning() << "rmkey-qt-inject: accept failed" << strerror(errno);
            continue;
        }
        handle_client(client_fd);
    }

    return nullptr;
}

/* ── LD_PRELOAD constructor ────────────────────────────────────────── */

__attribute__((constructor)) static void rmkey_qt_inject_init(void) {
    file_log("constructor called");

    /* Prevent LD_PRELOAD from leaking into any helper processes that
     * xochitl may exec after startup, such as cloud-sync helpers.
     */
    unsetenv("LD_PRELOAD");

    pthread_t thread;
    int err = pthread_create(&thread, nullptr, server_thread_main, nullptr);
    if (err != 0) {
        file_log("pthread_create failed");
        fprintf(stderr, "rmkey-qt-inject: pthread_create failed: %s\n",
                strerror(err));
        return;
    }
    pthread_detach(thread);
}
