// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import uniffi.papercup.version

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    HelloPapercup()
                }
            }
        }
    }
}

@Composable
fun HelloPapercup() {
    // Phase 0: prove the JNI bridge is wired by calling into the Rust core.
    // If this string renders, libpapercup.so loaded and uniffi found the
    // `version()` symbol.
    val coreVersion = remember { version() }
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = "Papercup",
            style = MaterialTheme.typography.displayMedium,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = "papercup-core $coreVersion",
            style = MaterialTheme.typography.bodyLarge,
            fontFamily = FontFamily.Monospace,
        )
        Spacer(Modifier.height(24.dp))
        Text(
            text = "Phase 0 — Rust ↔ Compose bridge confirmed.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}
