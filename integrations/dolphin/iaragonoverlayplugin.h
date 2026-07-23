/*
    iaragon Dolphin integration: sync-status overlay icons.
    SPDX-License-Identifier: Apache-2.0
*/
#pragma once

#include <KOverlayIconPlugin>

#include <QElapsedTimer>
#include <QHash>
#include <QLocalSocket>
#include <QQueue>
#include <QSet>
#include <QStringList>

/*
 * Asks the iaragon daemon for the sync status of files under the mirror,
 * over its unix-domain status socket (one absolute path per line in, one
 * status word per line out).
 *
 * getOverlays() is called on Dolphin's main thread and must not block
 * (see the KOverlayIconPlugin contract), so everything is asynchronous:
 * answers land in a small TTL cache and are announced via overlaysChanged.
 * The TTL keeps long-lived views honest — a status that changes gets
 * re-queried and re-announced within a few seconds.
 */
class IaragonOverlayPlugin : public KOverlayIconPlugin
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID "org.iaragon.overlayicon")

public:
    explicit IaragonOverlayPlugin(QObject *parent = nullptr);

    QStringList getOverlays(const QUrl &url) override;

private:
    struct CacheEntry {
        QStringList overlays;
        qint64 freshUntilMs = 0;
    };

    void ensureConnected();
    void queryStatus(const QString &localPath);
    void readReplies();
    void dropPendingQueries();

    QLocalSocket m_socket;
    QHash<QString, CacheEntry> m_cache;
    // The daemon answers strictly in request order on one connection.
    QQueue<QString> m_awaitingReply;
    QSet<QString> m_inFlight;
    QElapsedTimer m_clock;
    qint64 m_nextConnectAttemptMs = 0;
};
