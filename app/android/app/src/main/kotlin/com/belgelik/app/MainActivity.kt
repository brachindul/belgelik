package com.belgelik.app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.belgelik.app/media_control"
    private var methodChannel: MethodChannel? = null

    // Son gonderilen degerlerin diff onbellegi. Dart tarafinda throttle olsa
    // bile, ileride baska bir cagri yolu service'i gereksiz tekrar baslatmasin
    // diye sonucu degismeyen updateService cagrilarini burada da eliyoruz.
    // Her updateService = yeni startForegroundService = yeni startId (logcatte
    // lastStartId saniyede 1 artiyordu). Bu diff sayesinde ayni degerlerle
    // gelen cagrilar O(n) degil O(1) maliyete duser.
    private var lastTitle: String? = null
    private var lastIsPlaying: Boolean? = null
    private var lastPosition: Long? = null
    private var lastDuration: Long? = null

    /**
     * Gelen degerler oncekiyle birebir ayni mi? Position karsilastirma esigi
     * 1000ms (bu, native'in Dart throttle'dan bagimsiz ikinci bir guvenlik
     * katmani olmasi icin; zaten Dart ~1500ms throttle yapiyor ama Dart bug'la
     * geri donerse bu katman sistemi korur).
     */
    private fun isSameUpdate(
        title: String,
        isPlaying: Boolean,
        position: Long,
        duration: Long
    ): Boolean {
        val posPrev = lastPosition
        val positionClose = posPrev != null && Math.abs(position - posPrev) < 1000L
        return lastTitle == title &&
            lastIsPlaying == isPlaying &&
            lastDuration == duration &&
            positionClose
    }

    private fun cacheUpdate(
        title: String,
        isPlaying: Boolean,
        position: Long,
        duration: Long
    ) {
        lastTitle = title
        lastIsPlaying = isPlaying
        lastPosition = position
        lastDuration = duration
    }

    private fun clearCache() {
        lastTitle = null
        lastIsPlaying = null
        lastPosition = null
        lastDuration = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val title = call.argument<String>("title") ?: ""
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    val position = call.argument<Number>("position")?.toLong() ?: 0L
                    val duration = call.argument<Number>("duration")?.toLong() ?: 0L

                    // Ilk baslangic cagrisi her zaman gider; cache'i senkronize et
                    // ki sonraki updateService diff'i dogru calissin.
                    cacheUpdate(title, isPlaying, position, duration)

                    val intent = Intent(this, MediaPlaybackService::class.java).apply {
                        action = MediaPlaybackService.ACTION_START
                        putExtra(MediaPlaybackService.EXTRA_TITLE, title)
                        putExtra(MediaPlaybackService.EXTRA_IS_PLAYING, isPlaying)
                        putExtra(MediaPlaybackService.EXTRA_POSITION, position)
                        putExtra(MediaPlaybackService.EXTRA_DURATION, duration)
                    }
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "updateService" -> {
                    val title = call.argument<String>("title") ?: ""
                    val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                    val position = call.argument<Number>("position")?.toLong() ?: 0L
                    val duration = call.argument<Number>("duration")?.toLong() ?: 0L

                    // Defense-in-depth: Dart throttle'i atlasa bile, degerler
                    // ayniysa service'i tekrar baslatma. startForegroundService
                    // cagrilmazsa yeni startId uretilmez, notification repost
                    // edilmez, NotificationManager wake lock alip birakmaz.
                    if (isSameUpdate(title, isPlaying, position, duration)) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    cacheUpdate(title, isPlaying, position, duration)

                    val intent = Intent(this, MediaPlaybackService::class.java).apply {
                        action = MediaPlaybackService.ACTION_UPDATE
                        putExtra(MediaPlaybackService.EXTRA_TITLE, title)
                        putExtra(MediaPlaybackService.EXTRA_IS_PLAYING, isPlaying)
                        putExtra(MediaPlaybackService.EXTRA_POSITION, position)
                        putExtra(MediaPlaybackService.EXTRA_DURATION, duration)
                    }
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(null)
                }
                "stopService" -> {
                    // Cache'i temizle: bir sonraki oynatma diff'i sifirdan
                    // baslasin (aksi halde eski position cacheda kalir).
                    clearCache()
                    val intent = Intent(this, MediaPlaybackService::class.java).apply {
                        action = MediaPlaybackService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(null)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Handle callbacks from MediaPlaybackService
        MediaPlaybackService.onActionCallback = { action ->
            runOnUiThread {
                methodChannel?.invokeMethod("onAction", action)
            }
        }
    }

    override fun onDestroy() {
        MediaPlaybackService.onActionCallback = null
        clearCache()
        super.onDestroy()
    }
}
