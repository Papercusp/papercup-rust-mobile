// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.mikepenz.aboutlibraries.Libs
import com.mikepenz.aboutlibraries.entity.Library
import com.mikepenz.aboutlibraries.ui.compose.m3.LibrariesContainer
import com.mikepenz.aboutlibraries.ui.compose.m3.LicenseDialog
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

internal fun parseLibraryNotices(json: String): Libs =
    Libs.Builder().withJson(json).build().also {
        require(it.libraries.isNotEmpty()) { "Bundled library notices are empty" }
    }

@Composable
fun LibraryNoticesScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val loaded by produceState<Result<Libs>?>(initialValue = null, context) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                context.resources.openRawResource(R.raw.aboutlibraries).bufferedReader().use {
                    parseLibraryNotices(it.readText())
                }
            }
        }
    }
    LibraryNoticesContent(loaded?.getOrNull(), loaded?.isFailure == true, onBack)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LibraryNoticesContent(libraries: Libs?, failed: Boolean = false, onBack: () -> Unit) {
    var selected by remember { mutableStateOf<Library?>(null) }
    val uriHandler = LocalUriHandler.current
    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = stringResource(R.string.settings_library_notices),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = PapercupColors.Text)
                    }
                },
            )
        },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        if (libraries == null) {
            Text(
                stringResource(if (failed) R.string.library_notices_error else R.string.library_notices_loading),
                modifier = Modifier.padding(padding).padding(16.dp),
                color = PapercupColors.Text,
            )
        } else {
            LibrariesContainer(
                libraries = libraries,
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(vertical = 8.dp),
                onLibraryClick = { selected = it },
            )
        }
    }
    selected?.let { library ->
        // Override the viewer's first-license behavior: preserve every supplied
        // license, including linked references whose text needs supplementation.
        LicenseDialog(library = library, onDismiss = { selected = null }, body = {
            Column {
                Text(library.name, style = MaterialTheme.typography.titleMedium)
                if (library.licenses.isEmpty()) Text(stringResource(R.string.library_notices_missing))
                library.licenses.forEach { license ->
                    Text(license.name, modifier = Modifier.padding(top = 12.dp), style = MaterialTheme.typography.titleSmall)
                    license.licenseContent?.takeIf { it.isNotBlank() }?.let { Text(it) }
                    license.url?.takeIf { it.isNotBlank() }?.let { url ->
                        TextButton(onClick = { uriHandler.openUri(url) }) {
                            Text(stringResource(R.string.library_notices_open))
                        }
                    }
                    if (license.licenseContent.isNullOrBlank() && license.url.isNullOrBlank()) {
                        Text(stringResource(R.string.library_notices_missing))
                    }
                }
            }
        })
    }
}
