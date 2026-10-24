package com.examtracker.exam_tracker

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Home-screen widget: the next last day, the next exam, and how many jobs close
 * this week. The app writes the text (lib/services/home_widget.dart) into its
 * shared preferences; this only shows it. Tapping it opens the app.
 */
class SummitWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = views(context)
        for (id in ids) manager.updateAppWidget(id, views)
    }

    companion object {
        /** Redraw every placed widget now (the app calls this when the text changes). */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, SummitWidget::class.java))
            if (ids.isNotEmpty()) SummitWidget().onUpdate(context, manager, ids)
        }

        private fun views(context: Context): RemoteViews {
            // shared_preferences (Flutter) keeps its values here, each key with "flutter.".
            val raw = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getString("flutter.widget.summary", null)
            val data = try {
                if (raw == null) JSONObject() else JSONObject(raw)
            } catch (_: Exception) {
                JSONObject()
            }
            val deadline = data.optString("deadline")
            val exam = data.optString("exam")
            val week = data.optString("week")

            val views = RemoteViews(context.packageName, R.layout.summit_widget)
            fun line(id: Int, text: String) {
                views.setTextViewText(id, text)
                views.setViewVisibility(id, if (text.isEmpty()) View.GONE else View.VISIBLE)
            }
            line(R.id.widget_deadline, if (deadline.isEmpty()) "" else "⏳ $deadline")
            line(R.id.widget_exam, if (exam.isEmpty()) "" else "📝 $exam")
            line(R.id.widget_week, week)
            val empty = deadline.isEmpty() && exam.isEmpty() && week.isEmpty()
            line(R.id.widget_empty, if (empty) context.getString(R.string.widget_empty) else "")

            val open = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
            return views
        }
    }
}
