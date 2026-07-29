package tj.tvoice.app

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.view.View
import android.widget.TextView
import androidx.annotation.ColorRes
import androidx.core.content.ContextCompat

/** Central design tokens for the programmatic AppCompat UI. */
internal object TvoiceUi {
    const val PAGE_TITLE_SP = 28f
    const val SCREEN_TITLE_SP = 17f
    const val LIST_TITLE_SP = 15f
    const val BODY_SP = 14f
    const val BUTTON_SP = 14f
    const val SECONDARY_SP = 12f
    const val CAPTION_SP = 11f
    const val CALL_NUMBER_SP = 28f

    const val SCREEN_HORIZONTAL_DP = 16
    const val ROW_HEIGHT_DP = 62
    const val AVATAR_DP = 40
    const val TOUCH_DP = 48
    const val BOTTOM_NAV_DP = 62
    const val SEARCH_DP = 40
    const val FIELD_DP = 54
    const val FAB_DP = 54

    fun color(context: Context, @ColorRes id: Int): Int = ContextCompat.getColor(context, id)
    fun regular(): Typeface = Typeface.create("sans-serif", Typeface.NORMAL)
    fun medium(): Typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    fun semiBold(): Typeface = Typeface.create("sans-serif", Typeface.BOLD)
    fun bold(): Typeface = Typeface.create("sans-serif", Typeface.BOLD)

    fun style(textView: TextView, sizeSp: Float, color: Int, typeface: Typeface = regular()) {
        textView.textSize = sizeSp
        textView.setTextColor(color)
        textView.setTypeface(typeface)
        textView.includeFontPadding = false
        textView.setLineSpacing(0f, 1.25f)
    }

    fun rounded(
        context: Context,
        color: Int,
        radiusDp: Int,
        strokeColor: Int? = null,
        strokeDp: Int = 0
    ): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.RECTANGLE
        setColor(color)
        cornerRadius = context.dp(radiusDp).toFloat()
        if (strokeColor != null && strokeDp > 0) setStroke(context.dp(strokeDp), strokeColor)
    }

    fun ripple(context: Context, normalColor: Int, radiusDp: Int): RippleDrawable {
        val pressed = ColorStateList.valueOf(color(context, R.color.tvoice_blue_soft))
        val content = rounded(context, normalColor, radiusDp)
        return RippleDrawable(pressed, content, content.constantState?.newDrawable())
    }

    fun ensureTouchTarget(view: View) {
        view.minimumWidth = view.context.dp(TOUCH_DP)
        view.minimumHeight = view.context.dp(TOUCH_DP)
    }
}

internal fun Context.dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
