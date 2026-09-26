package org.levarac.beid.support

import android.content.Intent

/** Carries only the frozen JSON text; the chooser leaves destination and sending to the user. */
fun supportShareIntent(json: String, chooserTitle: String): Intent = Intent.createChooser(
    Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_TEXT, json)
    },
    chooserTitle,
)
