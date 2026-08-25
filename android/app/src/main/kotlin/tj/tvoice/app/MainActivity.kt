package tj.tvoice.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
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
}
