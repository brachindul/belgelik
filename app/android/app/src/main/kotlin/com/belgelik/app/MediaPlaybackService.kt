package com.belgelik.app

import android.app.*
import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder

class MediaPlaybackService : Service() {
    private var mediaSession: MediaSession? = null
    private val channelId = "media_playback_channel"
    private val notificationId = 1001

    // Icerisel diff onbellegi (last-line defense): MainActivity diff'i atlsa
    // bile, servise ulasan degerler ayniysa notification'u tekrar post etme.
    // Position haric tutulur cunku Android MediaStyle playbackSpeed ile konumu
    // interpolasyonla kendisi gunceller; biz sadece gorsel icerigin (title,
    // isPlaying, duration) degistigi noktalarda yeniden post yapmaliyiz.
    private var postedTitle: String? = null
    private var postedIsPlaying: Boolean? = null
    private var postedDuration: Long? = null
    private var firstPostDone = false

    companion object {
        const val ACTION_START = "com.belgelik.app.ACTION_START"
        const val ACTION_UPDATE = "com.belgelik.app.ACTION_UPDATE"
        const val ACTION_STOP = "com.belgelik.app.ACTION_STOP"
        
        const val ACTION_PLAY = "com.belgelik.app.ACTION_PLAY"
        const val ACTION_PAUSE = "com.belgelik.app.ACTION_PAUSE"
        const val ACTION_REWIND = "com.belgelik.app.ACTION_REWIND"
        const val ACTION_FORWARD = "com.belgelik.app.ACTION_FORWARD"

        const val EXTRA_TITLE = "title"
        const val EXTRA_IS_PLAYING = "isPlaying"
        const val EXTRA_POSITION = "position"
        const val EXTRA_DURATION = "duration"

        var onActionCallback: ((String) -> Unit)? = null
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        setupMediaSession()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        when (action) {
            ACTION_START -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "Video"
                val isPlaying = intent.getBooleanExtra(EXTRA_IS_PLAYING, false)
                val position = intent.getLongExtra(EXTRA_POSITION, 0L)
                val duration = intent.getLongExtra(EXTRA_DURATION, 0L)
                updateNotification(title, isPlaying, position, duration)
            }
            ACTION_UPDATE -> {
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "Video"
                val isPlaying = intent.getBooleanExtra(EXTRA_IS_PLAYING, false)
                val position = intent.getLongExtra(EXTRA_POSITION, 0L)
                val duration = intent.getLongExtra(EXTRA_DURATION, 0L)
                updateNotification(title, isPlaying, position, duration)
            }
            ACTION_STOP -> {
                onActionCallback?.invoke("pause")
                resetDiffState()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                stopSelf()
            }
            ACTION_PLAY -> {
                onActionCallback?.invoke("play")
            }
            ACTION_PAUSE -> {
                onActionCallback?.invoke("pause")
            }
            ACTION_REWIND -> {
                onActionCallback?.invoke("rewind")
            }
            ACTION_FORWARD -> {
                onActionCallback?.invoke("forward")
            }
        }
        return START_NOT_STICKY
    }

    // Kullanici uygulamayi son kullanilanlardan kaydirdiginda Activity yok
    // olur ama servis ayri bir bilesen oldugu icin yasamaya devam eder ve
    // bildirim "oynuyormus gibi" ilerlemeye devam eder. Gorev kaldirilinca
    // servisi ve bildirimi durdur.
    override fun onTaskRemoved(rootIntent: Intent?) {
        resetDiffState()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    /**
     * Bildirim diff onbellegini sifirlar. Bir sonraki oynatma acildiginda ilk
     * updateNotification her zaman gercekten post yapsin diye STOP / task
     * remove / destroy sirasinda cagrilmali.
     */
    private fun resetDiffState() {
        postedTitle = null
        postedIsPlaying = null
        postedDuration = null
        firstPostDone = false
    }

    private fun setupMediaSession() {
        mediaSession = MediaSession(this, "MediaPlaybackService").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() {
                    onActionCallback?.invoke("play")
                }
                override fun onPause() {
                    onActionCallback?.invoke("pause")
                }
                override fun onSeekTo(pos: Long) {
                    // Pos is in milliseconds
                }
            })
            isActive = true
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Video Oynatma Kontrolleri",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Video oynatma kontrollerini içeren bildirim kanalı"
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun updateNotification(title: String, isPlaying: Boolean, positionMs: Long, durationMs: Long) {
        // Onceki post ile ayni gorsel icerik mi? Position interpolasyonu
        // sistem tarafindan yapildigi icin onu diff'e katmiyoruz. Ilk post
        // her zaman yapilmali (servisi foreground'a almak icin).
        if (firstPostDone &&
            postedTitle == title &&
            postedIsPlaying == isPlaying &&
            postedDuration == durationMs
        ) {
            return
        }
        postedTitle = title
        postedIsPlaying = isPlaying
        postedDuration = durationMs
        firstPostDone = true

        val stateBuilder = PlaybackState.Builder()
            .setActions(
                PlaybackState.ACTION_PLAY or
                PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_SEEK_TO or
                PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                PlaybackState.ACTION_SKIP_TO_NEXT
            )
            .setState(
                if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                positionMs,
                1.0f
            )
        mediaSession?.setPlaybackState(stateBuilder.build())

        val metadataBuilder = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
        mediaSession?.setMetadata(metadataBuilder.build())

        val playPauseAction = if (isPlaying) ACTION_PAUSE else ACTION_PLAY
        val playPauseIcon = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val playPauseText = if (isPlaying) "Duraklat" else "Oynat"

        val flag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }

        val rewindIntent = PendingIntent.getService(this, 1, Intent(this, MediaPlaybackService::class.java).setAction(ACTION_REWIND), flag)
        val playPauseIntent = PendingIntent.getService(this, 2, Intent(this, MediaPlaybackService::class.java).setAction(playPauseAction), flag)
        val forwardIntent = PendingIntent.getService(this, 3, Intent(this, MediaPlaybackService::class.java).setAction(ACTION_FORWARD), flag)
        val stopIntent = PendingIntent.getService(this, 4, Intent(this, MediaPlaybackService::class.java).setAction(ACTION_STOP), flag)

        val pm = packageManager
        val launchIntent = pm.getLaunchIntentForPackage(packageName)
        val contentIntent = PendingIntent.getActivity(this, 0, launchIntent, flag)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder.setContentTitle(title)
            .setContentText("Belgelik Çalışma Modu")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(mediaSession?.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_rew, "Geri", rewindIntent).build())
            .addAction(Notification.Action.Builder(playPauseIcon, playPauseText, playPauseIntent).build())
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_ff, "İleri", forwardIntent).build())

        builder.setDeleteIntent(stopIntent)

        val notification = builder.build()
        startForeground(notificationId, notification)
    }

    override fun onDestroy() {
        mediaSession?.release()
        resetDiffState()
        super.onDestroy()
    }
}
