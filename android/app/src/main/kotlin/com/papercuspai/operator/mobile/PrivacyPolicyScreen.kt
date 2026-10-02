// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupScreenHeader

internal data class PrivacySection(val title: String, val body: String)

internal object MobilePrivacyPolicy {
    const val UPDATED = "October 2, 2026"
    val sections = listOf(
        PrivacySection(
            "Overview",
            "Papercusp is a companion to a desktop operator you pair with. We do not sell personal data, show ads, or use behavioral advertising. The app has no Papercusp account or sign-up.",
        ),
        PrivacySection(
            "Paired desktop and AI providers",
            "Pairing stores an encrypted device credential on this phone. Chat, commands, workspace identifiers, and device identifiers go to your paired operator. Your operator may send prompts and replies to the AI provider configured by its administrator.",
        ),
        PrivacySection(
            "Voice",
            "Desktop-local voice sends microphone audio to your paired operator for speech recognition and replies. Cloud voice is off until you explicitly agree. When enabled, microphone audio, transcripts, responses, and functional identifiers go to ElevenLabs and its service providers, including AI model providers. They may record, view, store, and share communications to provide and improve the service, train models, and comply with law. You can withdraw consent in Settings; a later cloud session will ask again.",
        ),
        PrivacySection(
            "Wake-word listening",
            "On Android builds with wake-word listening enabled, Picovoice Porcupine continuously uses the microphone to detect the activation word once microphone permission is granted, including while the app is in the background. A foreground-service notification indicates this listening. Builds without wake-word configuration do not start this listener. Cloud voice is separate and still requires your consent.",
        ),
        PrivacySection(
            "Push and crash diagnostics",
            "Firebase Cloud Messaging receives a push token used to deliver operator notifications. Firebase Crashlytics receives crash logs, device and OS details, and an installation identifier so we can diagnose failures. Firebase Analytics, advertising-ID collection, and Android-ID analytics collection are disabled.",
        ),
        PrivacySection(
            "Permissions",
            "Microphone is used for voice. Camera is used to scan a pairing QR code. Notifications deliver messages from your operator. The app does not request contacts, calendar, location, photos, or financial information.",
        ),
        PrivacySection(
            "Retention and control",
            "On-device credentials and preferences remain until you unpair, clear app data, or uninstall. Data on your operator follows its administrator's retention settings. Cloud voice and crash data follow the processors' configured retention and legal requirements. Use Settings to revoke cloud voice consent or forget the device. Contact support to request deletion of developer-controlled cloud voice or crash records.",
        ),
        PrivacySection(
            "Children and changes",
            "Papercusp is not directed to children under 13. We will update this policy when data practices materially change and show a new consent prompt when required.",
        ),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PrivacyPolicyScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    fun open(url: String) {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    }

    Scaffold(
        topBar = {
            PapercupScreenHeader(
                title = "Privacy policy",
                subtitle = "Updated ${MobilePrivacyPolicy.UPDATED}",
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back",
                            tint = PapercupColors.Text,
                        )
                    }
                },
            )
        },
        containerColor = PapercupColors.Ink,
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .background(PapercupColors.ScreenGradient)
                .padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(MobilePrivacyPolicy.sections) { section ->
                PapercupCard(modifier = Modifier.fillMaxWidth()) {
                    Column {
                        Text(
                            text = section.title,
                            style = MaterialTheme.typography.titleSmall,
                            color = PapercupColors.Text,
                        )
                        PapercupMetaText(
                            text = section.body,
                            modifier = Modifier.padding(top = 8.dp),
                        )
                    }
                }
            }
            item {
                PapercupCard(modifier = Modifier.fillMaxWidth()) {
                    Column {
                        Text(
                            text = "Contact and public copy",
                            style = MaterialTheme.typography.titleSmall,
                            color = PapercupColors.Text,
                        )
                        TextButton(onClick = { open(VoicePrivacyDisclosure.PRIVACY_URL) }) {
                            Text("Open papercusp.com privacy policy")
                        }
                        TextButton(onClick = { open(VoicePrivacyDisclosure.SUPPORT_URL) }) {
                            Text("Contact support")
                        }
                    }
                }
            }
        }
    }
}
