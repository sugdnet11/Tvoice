package tj.tvoice.app

import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat

/** Two-second branded welcome screen shown only from the launcher. */
class SplashActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private val openApplication = Runnable {
        if (isFinishing || isDestroyed) return@Runnable
        startActivity(Intent(this, MainActivity::class.java))
        overridePendingTransition(android.R.anim.fade_in, android.R.anim.fade_out)
        finish()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.rgb(248, 251, 255)
        window.navigationBarColor = Color.rgb(250, 252, 255)
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = true
            isAppearanceLightNavigationBars = true
        }

        val root = FrameLayout(this).apply {
            background = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(
                    Color.rgb(252, 254, 255),
                    Color.rgb(239, 246, 255),
                    Color.rgb(252, 254, 255)
                )
            )
        }
        ViewCompat.setOnApplyWindowInsetsListener(root) { view, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(0, systemBars.top, 0, systemBars.bottom)
            insets
        }

        val companyBrand = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            alpha = 0f
            translationY = -dp(12).toFloat()
        }
        companyBrand.addView(ImageView(this).apply {
            setImageResource(R.drawable.ic_tojiktelecom_mark)
            contentDescription = "TOJIKTELECOM"
        }, LinearLayout.LayoutParams(dp(38), dp(38)))
        companyBrand.addView(TextView(this).apply {
            text = "TOJIKTELECOM"
            textSize = 24f
            setTextColor(Color.rgb(15, 151, 228))
            typeface = Typeface.create("sans-serif", Typeface.BOLD)
            letterSpacing = -0.025f
            includeFontPadding = false
            gravity = Gravity.CENTER_VERTICAL
        }, LinearLayout.LayoutParams(-2, dp(42)).apply { leftMargin = dp(9) })
        root.addView(
            companyBrand,
            FrameLayout.LayoutParams(-2, dp(44), Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply {
                topMargin = dp(58)
            }
        )

        val welcome = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            alpha = 0f
            scaleX = 0.92f
            scaleY = 0.92f
        }
        welcome.addView(TextView(this).apply {
            text = "Tvoice"
            textSize = 58f
            setTextColor(Color.rgb(11, 32, 102))
            typeface = Typeface.create("sans-serif", Typeface.BOLD)
            includeFontPadding = false
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(-2, -2))
        welcome.addView(TextView(this).apply {
            text = "Добро пожаловать!"
            textSize = 21f
            setTextColor(Color.rgb(25, 48, 112))
            typeface = Typeface.create("sans-serif", Typeface.NORMAL)
            includeFontPadding = false
            gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(18) })
        root.addView(welcome, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))

        val dots = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            alpha = 0f
        }
        repeat(3) { index ->
            dots.addView(View(this).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(
                        if (index == 1) Color.rgb(0, 132, 236)
                        else Color.rgb(96, 172, 244)
                    )
                }
            }, LinearLayout.LayoutParams(dp(9), dp(9)).apply {
                if (index > 0) leftMargin = dp(14)
            })
        }
        root.addView(
            dots,
            FrameLayout.LayoutParams(-2, dp(12), Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply {
                bottomMargin = dp(82)
            }
        )

        setContentView(root)
        startAnimations(companyBrand, welcome, dots)
        handler.postDelayed(openApplication, SPLASH_DURATION_MS)
    }

    private fun startAnimations(companyBrand: View, welcome: View, dots: View) {
        AnimatorSet().apply {
            playTogether(
                ObjectAnimator.ofFloat(companyBrand, View.ALPHA, 0f, 1f),
                ObjectAnimator.ofFloat(companyBrand, View.TRANSLATION_Y, -dp(12).toFloat(), 0f)
            )
            duration = 520
            startDelay = 80
            interpolator = DecelerateInterpolator()
            start()
        }
        AnimatorSet().apply {
            playTogether(
                ObjectAnimator.ofFloat(welcome, View.ALPHA, 0f, 1f),
                ObjectAnimator.ofFloat(welcome, View.SCALE_X, 0.92f, 1f),
                ObjectAnimator.ofFloat(welcome, View.SCALE_Y, 0.92f, 1f)
            )
            duration = 680
            startDelay = 220
            interpolator = DecelerateInterpolator()
            start()
        }
        ObjectAnimator.ofFloat(dots, View.ALPHA, 0f, 1f).apply {
            duration = 380
            startDelay = 720
            start()
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(openApplication)
        super.onDestroy()
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    companion object {
        private const val SPLASH_DURATION_MS = 2_000L
    }
}
