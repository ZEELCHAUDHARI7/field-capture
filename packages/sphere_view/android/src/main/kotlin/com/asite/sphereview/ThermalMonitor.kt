package com.asite.sphereview

import android.content.Context
import android.os.Build
import android.os.PowerManager

/**
 * Reports the device thermal state, and pushes changes as they happen (§5).
 *
 * An 87-frame bracketed capture followed by a 60 s multi-band blend is a
 * genuine sustained load, and on a tablet in direct sun on a site it is enough
 * to throttle. Throttling does not fail — it makes the output quietly worse,
 * which is the one thing architecture §8 refuses to do silently.
 *
 * Android's five-step scale is folded into the four states the pipeline uses.
 * `MODERATE` maps to `fair` rather than `serious` because AOSP describes it as
 * throttling the user experience is "not largely impacted" by; `SEVERE` is the
 * first step where it is, and that is where §5 wants the warning.
 */
class ThermalMonitor(context: Context) {

    private val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager

    private var listener: PowerManager.OnThermalStatusChangedListener? = null

    /** True when the platform can report thermal status at all (API 29+). */
    val isSupported: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && power != null

    fun current(): PlatformThermalState {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return PlatformThermalState.NOMINAL
        val pm = power ?: return PlatformThermalState.NOMINAL
        return map(pm.currentThermalStatus)
    }

    fun start(onChanged: (PlatformThermalState) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val pm = power ?: return
        stop()
        val l = PowerManager.OnThermalStatusChangedListener { status -> onChanged(map(status)) }
        listener = l
        runCatching { pm.addThermalStatusListener(l) }
    }

    fun stop() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val pm = power ?: return
        listener?.let { runCatching { pm.removeThermalStatusListener(it) } }
        listener = null
    }

    private fun map(status: Int): PlatformThermalState =
        when (status) {
            PowerManager.THERMAL_STATUS_NONE -> PlatformThermalState.NOMINAL
            PowerManager.THERMAL_STATUS_LIGHT -> PlatformThermalState.FAIR
            PowerManager.THERMAL_STATUS_MODERATE -> PlatformThermalState.FAIR
            PowerManager.THERMAL_STATUS_SEVERE -> PlatformThermalState.SERIOUS
            PowerManager.THERMAL_STATUS_CRITICAL,
            PowerManager.THERMAL_STATUS_EMERGENCY,
            PowerManager.THERMAL_STATUS_SHUTDOWN -> PlatformThermalState.CRITICAL
            else -> PlatformThermalState.NOMINAL
        }
}
