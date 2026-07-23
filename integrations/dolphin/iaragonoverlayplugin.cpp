/*
    iaragon Dolphin integration: sync-status overlay icons.
    SPDX-License-Identifier: LGPL-2.0-or-later
*/
#include "iaragonoverlayplugin.h"

#include <QDir>
#include <QFile>
#include <QUrl>

namespace
{
constexpr qint64 cacheTtlMs = 3000;
constexpr qint64 reconnectHoldOffMs = 5000;

QStringList overlaysForStatus(const QByteArray &status)
{
    // Breeze ships these (they are what the VCS plugins use); themes decide
    // the exact look.
    if (status == "synced") {
        return {QStringLiteral("vcs-normal")};
    }
    if (status == "syncing") {
        return {QStringLiteral("vcs-update-required")};
    }
    return {};
}

// Must mirror the daemon's choice (resolve_status_socket_path in the
// composition root): the user runtime dir when the session has one, the
// data dir otherwise.
QString daemonSocketPath()
{
    const QString runtimeDir = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (!runtimeDir.isEmpty()) {
        const QString candidate = runtimeDir + QStringLiteral("/iaragon.sock");
        if (QFile::exists(candidate)) {
            return candidate;
        }
    }
    return QDir::homePath() + QStringLiteral("/.local/share/iaragon/status.sock");
}
} // namespace

IaragonOverlayPlugin::IaragonOverlayPlugin(QObject *parent)
    : KOverlayIconPlugin(parent)
{
    m_clock.start();
    connect(&m_socket, &QLocalSocket::readyRead, this, &IaragonOverlayPlugin::readReplies);
    connect(&m_socket, &QLocalSocket::disconnected, this, &IaragonOverlayPlugin::dropPendingQueries);
}

QStringList IaragonOverlayPlugin::getOverlays(const QUrl &url)
{
    if (!url.isLocalFile()) {
        return {};
    }
    const QString path = url.toLocalFile();
    if (path.contains(QLatin1Char('\n'))) {
        return {}; // a newline would corrupt the line protocol
    }

    const qint64 now = m_clock.elapsed();
    const auto cached = m_cache.constFind(path);
    if (cached != m_cache.constEnd() && now < cached->freshUntilMs) {
        return cached->overlays;
    }

    // Stale or unseen: ask again, answer with what we have meanwhile.
    queryStatus(path);
    return cached != m_cache.constEnd() ? cached->overlays : QStringList();
}

void IaragonOverlayPlugin::ensureConnected()
{
    if (m_socket.state() != QLocalSocket::UnconnectedState) {
        return;
    }
    // Do not hammer connect() while the daemon is down: one attempt per
    // hold-off window, triggered by whatever getOverlays comes along.
    const qint64 now = m_clock.elapsed();
    if (now < m_nextConnectAttemptMs) {
        return;
    }
    m_nextConnectAttemptMs = now + reconnectHoldOffMs;
    m_socket.connectToServer(daemonSocketPath());
}

void IaragonOverlayPlugin::queryStatus(const QString &localPath)
{
    if (m_inFlight.contains(localPath)) {
        return;
    }
    ensureConnected();
    if (m_socket.state() != QLocalSocket::ConnectedState) {
        return; // the next getOverlays retries once we are connected
    }
    m_socket.write(localPath.toUtf8() + '\n');
    m_awaitingReply.enqueue(localPath);
    m_inFlight.insert(localPath);
}

void IaragonOverlayPlugin::readReplies()
{
    while (m_socket.canReadLine()) {
        const QByteArray status = m_socket.readLine().trimmed();
        if (m_awaitingReply.isEmpty()) {
            // Protocol slip; start over on a fresh connection.
            m_socket.abort();
            return;
        }
        const QString path = m_awaitingReply.dequeue();
        m_inFlight.remove(path);

        const QStringList overlays = overlaysForStatus(status);
        const QStringList before = m_cache.value(path).overlays;
        CacheEntry entry;
        entry.overlays = overlays;
        entry.freshUntilMs = m_clock.elapsed() + cacheTtlMs;
        m_cache.insert(path, entry);
        if (overlays != before) {
            Q_EMIT overlaysChanged(QUrl::fromLocalFile(path), overlays);
        }
    }
}

void IaragonOverlayPlugin::dropPendingQueries()
{
    // Replies for these will never arrive; the TTL brings the paths back.
    m_awaitingReply.clear();
    m_inFlight.clear();
}
