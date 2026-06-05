// SPDX-License-Identifier: GPL-3.0-or-later
package com.papercuspai.operator.mobile

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.mlkit.vision.MlKitAnalyzer
import androidx.camera.view.CameraController
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Image
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.graphics.Brush
import com.papercuspai.operator.mobile.theme.PapercupCameraShape
import com.papercuspai.operator.mobile.theme.PapercupCard
import com.papercuspai.operator.mobile.theme.PapercupColors
import com.papercuspai.operator.mobile.theme.PapercupMetaText
import com.papercuspai.operator.mobile.theme.PapercupCardHeader
import androidx.compose.runtime.*
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import java.util.concurrent.Executors
import kotlinx.coroutines.launch
import uniffi.papercup.OperatorClient
import uniffi.papercup.PairException
import uniffi.papercup.PairOutcome
import uniffi.papercup.QrPayload
import uniffi.papercup.parseQrPayload

/// One-shot pair flow. Either the QR scanner finds a payload, or the user
/// pastes the JSON manually. We then call `OperatorClient.pair()` with the
/// `server` from the payload as the base URL, persist the result, and
/// return it via `onPaired`.
@Composable
fun PairScreen(onPaired: (DeviceCredentials) -> Unit) {
    var mode by remember { mutableStateOf<PairMode>(PairMode.Choose) }
    var error by remember { mutableStateOf<String?>(null) }
    var redeeming by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    fun redeem(payload: QrPayload) {
        if (redeeming) return
        redeeming = true
        error = null
        scope.launch {
            try {
                // D-005: the server moved the mesh to Defguard self-enrollment —
                // pair() just exchanges the token; the outcome carries a
                // defguardEnrollmentUrl we open once so the phone joins the mesh.
                // No WireGuard keypair / wg-config at pair time anymore.
                val client = OperatorClient(payload.server, null)
                val outcome: PairOutcome = client.pair(payload.pairToken)
                outcome.defguardEnrollmentUrl?.takeIf { it.isNotBlank() }?.let { url ->
                    runCatching {
                        val intent = android.content.Intent(
                            android.content.Intent.ACTION_VIEW,
                            android.net.Uri.parse(url),
                        ).apply { flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK }
                        context.startActivity(intent)
                    }
                }
                onPaired(
                    DeviceCredentials(
                        server = payload.server,
                        deviceToken = outcome.deviceToken,
                        deviceId = outcome.deviceId,
                        workspaceId = outcome.workspaceId,
                        meshUrl = null,
                        defguardEnrollmentUrl = outcome.defguardEnrollmentUrl,
                    ),
                )
            } catch (e: PairException) {
                error = "Pair failed: ${e::class.simpleName}: ${e.message ?: ""}"
            } catch (t: Throwable) {
                error = "Pair failed: ${t::class.simpleName}: ${t.message ?: ""}"
            } finally {
                redeeming = false
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(PapercupColors.ScreenGradient)
            .padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        PapercuspWordmark(
            modifier = Modifier
                .width(256.dp)
                .aspectRatio(520f / 170f),
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "MISSION CONSOLE",
            style = MaterialTheme.typography.labelSmall,
            color = PapercupColors.AccentStrong.copy(alpha = 0.62f),
            letterSpacing = 1.4.sp,
        )
        Spacer(Modifier.height(24.dp))
        Text(
            "Pair with your desktop",
            style = MaterialTheme.typography.headlineMedium,
            color = PapercupColors.Text,
        )
        Spacer(Modifier.height(24.dp))

        when (mode) {
            PairMode.Choose -> {
                Text(
                    "On your desktop: Settings → Mobile Access → \"Pair new device\" → scan the QR code shown.",
                    modifier = Modifier.widthIn(max = 320.dp),
                    style = MaterialTheme.typography.bodyMedium,
                    color = PapercupColors.TextMuted,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
                Spacer(Modifier.height(24.dp))
                PrimaryPairButton(
                    text = if (redeeming) "Pairing…" else "Scan QR",
                    enabled = !redeeming,
                    onClick = { mode = PairMode.Scan },
                )
                Spacer(Modifier.height(10.dp))
                SecondaryPairButton(
                    text = stringResource(R.string.pair_paste_payload),
                    enabled = !redeeming,
                    onClick = { mode = PairMode.Paste },
                )
            }

            PairMode.Scan -> ScanPanel(
                disabled = redeeming,
                onCancel = { mode = PairMode.Choose },
                onPaste = { mode = PairMode.Paste },
                onPayload = { redeem(it) },
                onError = { error = it; mode = PairMode.Choose },
            )

            PairMode.Paste -> PastePanel(
                disabled = redeeming,
                onCancel = { mode = PairMode.Choose },
                onSubmit = { text ->
                    try {
                        redeem(parseQrPayload(text))
                    } catch (_: PairException.InvalidQr) {
                        error = "That payload doesn't look right — expected JSON with " +
                            "server, pairToken, workspaceId."
                    }
                },
            )
        }

        if (redeeming) {
            Spacer(Modifier.height(16.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(8.dp))
                PapercupMetaText(stringResource(R.string.pair_redeeming))
            }
        }

        error?.let {
            Spacer(Modifier.height(24.dp))
            PapercupCard(
                modifier = Modifier.widthIn(max = 320.dp),
                accent = PapercupColors.ErrorSoft,
                contentPadding = PaddingValues(12.dp),
            ) {
                Text(
                    it,
                    color = PapercupColors.Error,
                    fontFamily = FontFamily.Monospace,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
}

@Composable
private fun PrimaryPairButton(
    text: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(999.dp)
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier
            .widthIn(min = 144.dp)
            .height(48.dp)
            .clip(shape)
            .background(
                Brush.verticalGradient(
                    listOf(
                        Color(0xFFD3FAFF),
                        PapercupColors.Accent,
                        Color(0xFF0891B2),
                    ),
                ),
            )
            .border(1.dp, PapercupColors.AccentStrong.copy(alpha = 0.48f), shape),
        shape = shape,
        colors = ButtonDefaults.buttonColors(
            containerColor = Color.Transparent,
            contentColor = PapercupColors.ButtonInk,
            disabledContainerColor = Color.Transparent,
            disabledContentColor = PapercupColors.ButtonInk.copy(alpha = 0.56f),
        ),
        contentPadding = PaddingValues(horizontal = 32.dp, vertical = 12.dp),
    ) {
        Text(text, style = MaterialTheme.typography.titleSmall)
    }
}

@Composable
private fun SecondaryPairButton(
    text: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(999.dp)
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = modifier
            .widthIn(min = 144.dp)
            .height(48.dp)
            .clip(shape)
            .background(PapercupColors.AccentSoft)
            .border(1.dp, PapercupColors.AccentStrong.copy(alpha = 0.48f), shape),
        shape = shape,
        colors = ButtonDefaults.buttonColors(
            containerColor = Color.Transparent,
            contentColor = PapercupColors.AccentStrong,
            disabledContainerColor = Color.Transparent,
            disabledContentColor = PapercupColors.AccentStrong.copy(alpha = 0.56f),
        ),
        contentPadding = PaddingValues(horizontal = 32.dp, vertical = 12.dp),
    ) {
        Text(text, style = MaterialTheme.typography.titleSmall)
    }
}

@Composable
private fun PapercuspWordmark(modifier: Modifier = Modifier) {
    Image(
        painter = painterResource(R.drawable.pairing_wordmark),
        contentDescription = null,
        modifier = modifier,
    )
}

private sealed interface PairMode {
    data object Choose : PairMode
    data object Scan : PairMode
    data object Paste : PairMode
}

@Composable
private fun ScanPanel(
    disabled: Boolean,
    onCancel: () -> Unit,
    onPaste: () -> Unit,
    onPayload: (QrPayload) -> Unit,
    onError: (String) -> Unit,
) {
    val context = LocalContext.current
    var hasPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
                == PackageManager.PERMISSION_GRANTED,
        )
    }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        hasPermission = it
    }
    LaunchedEffect(Unit) {
        if (!hasPermission) launcher.launch(Manifest.permission.CAMERA)
    }

    PapercupCard {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            PapercupCardHeader("Camera scan", meta = if (disabled) "pairing" else "live")
            if (!hasPermission) {
                Text(
                    "Camera permission is required to scan the QR. Grant it from system settings, " +
                        "or use Paste payload instead.",
                    style = MaterialTheme.typography.bodySmall,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = onCancel) { Text(stringResource(R.string.pair_back)) }
                    OutlinedButton(onClick = onPaste) { Text(stringResource(R.string.pair_paste_payload)) }
                }
                return@Column
            }

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(360.dp)
                    .clip(PapercupCameraShape)
                    .border(1.dp, PapercupColors.Accent.copy(alpha = 0.45f), PapercupCameraShape)
                    .background(Color.Black),
            ) {
                CameraPreview(
                    enabled = !disabled,
                    onPayload = onPayload,
                    onError = onError,
                )
            }
            OutlinedButton(onClick = onCancel) { Text(stringResource(R.string.pair_back)) }
        }
    }
}

@Composable
private fun CameraPreview(
    enabled: Boolean,
    onPayload: (QrPayload) -> Unit,
    onError: (String) -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    val controller = remember {
        LifecycleCameraController(context).apply {
            cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
            setEnabledUseCases(CameraController.IMAGE_ANALYSIS)
        }
    }
    val scanner: BarcodeScanner = remember {
        BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                .build(),
        )
    }
    var consumed by remember { mutableStateOf(false) }

    DisposableEffect(lifecycleOwner) {
        controller.bindToLifecycle(lifecycleOwner)
        // Background executor — running ML Kit analysis on the main
        // thread freezes the UI and trips ANR ("Activity top resumed
        // state loss timeout"). Single thread is fine; one frame at a
        // time is plenty for QR.
        val analysisExecutor = Executors.newSingleThreadExecutor()
        val mainExecutor = ContextCompat.getMainExecutor(context)
        controller.setImageAnalysisAnalyzer(
            analysisExecutor,
            // 0 = original (sensor) coordinates; we don't need view-mapped boxes for QR detect.
            MlKitAnalyzer(listOf(scanner), 0, mainExecutor) { result ->
                if (consumed || !enabled) return@MlKitAnalyzer
                val barcode = result.getValue(scanner)?.firstOrNull() ?: return@MlKitAnalyzer
                val raw = barcode.rawValue ?: return@MlKitAnalyzer
                consumed = true
                try {
                    onPayload(parseQrPayload(raw))
                } catch (_: PairException.InvalidQr) {
                    consumed = false
                    onError("Scanned QR isn't a Papercup pair payload.")
                }
            },
        )
        onDispose {
            controller.unbind()
            analysisExecutor.shutdown()
            scanner.close()
        }
    }

    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { ctx ->
            PreviewView(ctx).apply {
                this.controller = controller
                scaleType = PreviewView.ScaleType.FILL_CENTER
            }
        },
    )
}

@Composable
private fun PastePanel(
    disabled: Boolean,
    onCancel: () -> Unit,
    onSubmit: (String) -> Unit,
) {
    var text by remember { mutableStateOf("") }
    PapercupCard {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            PapercupCardHeader(stringResource(R.string.pair_manual_code_label), meta = "JSON")
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                label = { Text(stringResource(R.string.pair_payload_label)) },
                placeholder = { Text("""{"server":"…","pairToken":"…","workspaceId":"…"}""") },
                modifier = Modifier.fillMaxWidth(),
                minLines = 4,
                enabled = !disabled,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = onCancel, enabled = !disabled) { Text(stringResource(R.string.pair_back)) }
                Button(
                    onClick = { onSubmit(text) },
                    enabled = !disabled && text.isNotBlank(),
                ) { Text(stringResource(R.string.pair_button)) }
            }
        }
    }
}
