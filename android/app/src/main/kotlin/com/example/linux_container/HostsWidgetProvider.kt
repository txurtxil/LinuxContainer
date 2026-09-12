package com.example.linux_container

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * Widget de escritorio "XTR Hosts": lista los hosts SSH y los favoritos SFTP
 * (espejo JSON en FlutterSharedPreferences, escrito por WidgetSync.dart).
 * Cada fila lanza MainActivity con extras xtr_widget_*; MainActivity los
 * reenvía a Flutter por el canal xtr/widget.
 */
class HostsWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_REFRESH = "com.example.linux_container.widget.REFRESH"

        /** Llamado desde MainActivity (canal xtr/widget "refresh") y desde el
         *  botón de refresco del propio widget. */
        fun requestRefresh(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(
                ComponentName(context, HostsWidgetProvider::class.java))
            if (ids.isNotEmpty()) {
                mgr.notifyAppWidgetViewDataChanged(ids, R.id.widget_list)
            }
        }
    }

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) updateOne(context, mgr, id)
    }

    private fun updateOne(context: Context, mgr: AppWidgetManager, widgetId: Int) {
        val views = RemoteViews(context.packageName, R.layout.widget_hosts)

        // Adapter de la lista -> nuestro RemoteViewsService
        val svcIntent = Intent(context, HostsWidgetService::class.java)
        views.setRemoteAdapter(R.id.widget_list, svcIntent)
        views.setEmptyView(R.id.widget_list, R.id.widget_empty)

        // Plantilla de PendingIntent para clicks de fila: cada fila rellena
        // los extras xtr_widget_* con setOnClickFillInIntent.
        val clickIntent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val clickPi = PendingIntent.getActivity(
            context, 0, clickIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
        views.setPendingIntentTemplate(R.id.widget_list, clickPi)

        // Botón de refresco de la cabecera
        val refreshIntent = Intent(context, HostsWidgetProvider::class.java).apply {
            action = ACTION_REFRESH
        }
        val refreshPi = PendingIntent.getBroadcast(
            context, 1, refreshIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
        views.setOnClickPendingIntent(R.id.widget_refresh, refreshPi)

        mgr.updateAppWidget(widgetId, views)
        mgr.notifyAppWidgetViewDataChanged(widgetId, R.id.widget_list)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REFRESH) requestRefresh(context)
    }
}
