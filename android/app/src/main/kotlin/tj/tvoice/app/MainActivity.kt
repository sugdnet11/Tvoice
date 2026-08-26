package tj.tvoice.app

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var platformChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterSipRuntime.initialize(applicationContext)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FlutterSipRuntime.METHOD_CHANNEL,
        ).setMethodCallHandler(::handleSipMethod)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FlutterSipRuntime.EVENT_CHANNEL,
        ).setStreamHandler(FlutterSipRuntime)

        platformChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PLATFORM_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialLink" -> result.success(intent?.dataString)
                    "shareText" -> {
                        val text = call.argument<String>("text").orEmpty()
                        val title = call.argument<String>("title").orEmpty()
                        if (text.isBlank()) {
                            result.success(false)
                        } else {
                            shareText(text, title)
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.dataString?.let { link ->
            platformChannel?.invokeMethod("link", link)
        }
    }

    private fun shareText(text: String, chooserTitle: String) {
        val sendIntent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }
        startActivity(
            Intent.createChooser(
                sendIntent,
                chooserTitle.ifBlank { "Поделиться через" },
            ),
        )
    }

    private fun handleSipMethod(call: MethodCall, result: MethodChannel.Result) {
        runCatching {
            when (call.method) {
                "register" -> {
                    val number = call.argument<String>("number").orEmpty()
                    val password = call.argument<String>("password").orEmpty()
                    FlutterSipRuntime.register(number, password)
                    result.success(true)
                }

                "call" -> {
                    FlutterSipRuntime.call(call.argument<String>("number").orEmpty())
                    result.success(null)
                }

                "answer" -> {
                    FlutterSipRuntime.answer()
                    result.success(null)
                }

                "reject", "hangup" -> {
                    FlutterSipRuntime.hangup()
                    result.success(null)
                }

                "unregister" -> {
                    FlutterSipRuntime.unregister()
                    result.success(null)
                }

                "setMuted" -> {
                    FlutterSipRuntime.setMuted(call.argument<Boolean>("muted") == true)
                    result.success(null)
                }

                "setSpeaker" -> {
                    FlutterSipRuntime.setSpeaker(call.argument<Boolean>("enabled") == true)
                    result.success(null)
                }

                "setHeld" -> {
                    FlutterSipRuntime.setHeld(call.argument<Boolean>("held") == true)
                    result.success(null)
                }

                "state" -> result.success(FlutterSipRuntime.snapshot())
                else -> result.notImplemented()
            }
        }.onFailure { error ->
            result.error("sip_error", error.message ?: "SIP error", null)
        }
    }

    private companion object {
        const val PLATFORM_CHANNEL = "tj.tvoice.app/platform"
    }
}
