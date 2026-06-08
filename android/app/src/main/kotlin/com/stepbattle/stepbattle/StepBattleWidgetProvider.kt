package com.stepbattle.stepbattle

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Renders the StepBattle home-screen widget. Reads four keys that the Dart
 * side writes via `HomeWidget.saveWidgetData`:
 *
 *   • `steps`             — int — today's step count.
 *   • `goal`              — int — daily step goal (default 8000).
 *   • `distance_km_str`   — string — formatted km, e.g. "4.21".
 *   • `kcal`              — int — calories.
 *
 * Whole-widget tap launches MainActivity. We deliberately don't tap-zone
 * individual stats — keeps the surface predictable on Samsung's launcher
 * (different OEMs render touch targets differently inside widgets).
 */
class StepBattleWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.stepbattle_widget).apply {
                val steps = widgetData.getInt("steps", 0)
                val goal = widgetData.getInt("goal", 8000).coerceAtLeast(1)
                val distanceKm = widgetData.getString("distance_km_str", "0.00") ?: "0.00"
                val kcal = widgetData.getInt("kcal", 0)

                setTextViewText(R.id.widget_steps, formatNumber(steps))
                setTextViewText(R.id.widget_distance, distanceKm)
                setTextViewText(R.id.widget_kcal, formatNumber(kcal))

                // ProgressBar max=1000 → use ‰ for 1-decimal precision below 100%.
                val ratio = (steps.toDouble() / goal.toDouble()).coerceIn(0.0, 1.0)
                setProgressBar(R.id.widget_progress, 1000, (ratio * 1000).toInt(), false)
                setTextViewText(
                    R.id.widget_progress_label,
                    "${formatNumber(steps)} / ${formatNumber(goal)} steps"
                )

                // Tap anywhere → open the app.
                val pendingIntent = HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java
                )
                setOnClickPendingIntent(R.id.widget_root, pendingIntent)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }

    /** Thousand-separator without pulling in java.text on older devices. */
    private fun formatNumber(n: Int): String {
        val s = n.toString()
        val out = StringBuilder()
        for (i in s.indices) {
            if (i > 0 && (s.length - i) % 3 == 0) out.append(',')
            out.append(s[i])
        }
        return out.toString()
    }
}
