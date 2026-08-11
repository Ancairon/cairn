package com.ancairon.cairn

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity()
{
    @Deprecated("Android's legacy callback is used to keep Flutter in control of back navigation.")
    override fun onBackPressed() {
        // Do not finish the activity here. Forward the event to Flutter,
        // where the discovery screen closes menus/search or shows its exit
        // prompt.
        flutterEngine?.navigationChannel?.popRoute()
    }
}
