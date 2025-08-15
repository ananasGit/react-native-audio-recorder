package com.audiorecorder

import android.Manifest
import android.content.pm.PackageManager
import android.media.MediaRecorder
import android.media.AudioFormat
import android.media.AudioRecord
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.facebook.react.bridge.WritableNativeMap
import com.facebook.react.module.annotations.ReactModule
import java.io.File
import java.io.IOException
import kotlin.math.*

@ReactModule(name = AudioRecorderModule.NAME)
class AudioRecorderModule(reactContext: ReactApplicationContext) :
  NativeAudioRecorderSpec(reactContext) {

  private var permissionPromise: Promise? = null

  private var mediaRecorder: MediaRecorder? = null
  private var audioRecord: AudioRecord? = null
  private var isRecording = false
  private var isPaused = false
  
  private var recordingStartTime: Long = 0
  private var lastVoiceActivityTime: Long = 0
  private var actualSpeechStartTime: Long = 0
  private var totalSpeechDuration: Double = 0.0
  private var hasDetectedVoice = false
  private var isInThinkingPause = false
  
  private var thinkingPauseThreshold: Double = 0.0
  private var endOfSpeechThreshold: Double = 0.0
  private var noiseFloorDb: Double = 0.0
  private var voiceActivityThresholdDb: Double = 0.0
  private var maxDurationSeconds: Double = 0.0
  private var minRecordingDurationMs: Double = 0.0
  
  private var outputFilePath: String? = null
  private var currentPromise: Promise? = null
  
  private val mainHandler = Handler(Looper.getMainLooper())
  private var levelMonitoringRunnable: Runnable? = null
  private var silenceTimeoutRunnable: Runnable? = null

  override fun getName(): String {
    return NAME
  }

  override fun startRecording(config: ReadableMap, promise: Promise) {
    if (isRecording) {
      promise.reject("recording_in_progress", "Recording is already in progress")
      return
    }

    if (!hasRecordAudioPermission()) {
      promise.reject("permission_denied", "Record audio permission not granted")
      return
    }

    // Store config
    thinkingPauseThreshold = config.getDouble("thinkingPauseThreshold")
    endOfSpeechThreshold = config.getDouble("endOfSpeechThreshold")
    noiseFloorDb = config.getDouble("noiseFloorDb")
    voiceActivityThresholdDb = config.getDouble("voiceActivityThresholdDb")
    maxDurationSeconds = config.getDouble("maxDurationSeconds")
    minRecordingDurationMs = config.getDouble("minRecordingDurationMs")

    // Reset state
    recordingStartTime = 0
    lastVoiceActivityTime = 0
    actualSpeechStartTime = 0
    totalSpeechDuration = 0.0
    hasDetectedVoice = false
    isInThinkingPause = false
    currentPromise = promise

    try {
      setupRecording(config)
      startRecordingInternal()
      promise.resolve(null)
    } catch (e: Exception) {
      // Clean up on failure
      cleanup()
      currentPromise = null
      promise.reject("recording_setup_error", "Failed to setup recording: ${e.message}")
    }
  }

  private fun setupRecording(config: ReadableMap) {
    val format = config.getString("format") ?: "aac"
    val sampleRate = config.getInt("sampleRate")
    val channels = config.getInt("channels")
    val bitRate = config.getInt("bitRate")

    // Validate configuration
    if (sampleRate < 8000 || sampleRate > 48000) {
      throw IllegalArgumentException("Sample rate must be between 8000 and 48000 Hz")
    }
    if (channels < 1 || channels > 2) {
      throw IllegalArgumentException("Channels must be 1 (mono) or 2 (stereo)")
    }
    if (bitRate < 8000 || bitRate > 320000) {
      throw IllegalArgumentException("Bit rate must be between 8000 and 320000 bps")
    }

    // Create output file
    val outputDir = reactApplicationContext.getExternalFilesDir(null)
    val fileName = "recording_${System.currentTimeMillis()}.$format"
    val outputFile = File(outputDir, fileName)
    outputFilePath = outputFile.absolutePath

    // Setup MediaRecorder
    mediaRecorder = MediaRecorder().apply {
      setAudioSource(MediaRecorder.AudioSource.MIC)
      
      when (format) {
        "aac" -> setOutputFormat(MediaRecorder.OutputFormat.AAC_ADTS)
        "mp3" -> setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        else -> setOutputFormat(MediaRecorder.OutputFormat.DEFAULT)
      }
      
      when (format) {
        "aac" -> setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        "mp3" -> setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
        else -> setAudioEncoder(MediaRecorder.AudioEncoder.DEFAULT)
      }
      
      setAudioSamplingRate(sampleRate)
      setAudioEncodingBitRate(bitRate)
      setAudioChannels(channels)
      setOutputFile(outputFilePath)
    }

    // Setup AudioRecord for level monitoring
    val channelConfig = if (channels == 1) AudioFormat.CHANNEL_IN_MONO else AudioFormat.CHANNEL_IN_STEREO
    val audioFormat = AudioFormat.ENCODING_PCM_16BIT
    val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
    
    audioRecord = AudioRecord(
      MediaRecorder.AudioSource.MIC,
      sampleRate,
      channelConfig,
      audioFormat,
      bufferSize
    )
  }

  private fun startRecordingInternal() {
    try {
      mediaRecorder?.prepare()
      mediaRecorder?.start()
      audioRecord?.startRecording()
      
      isRecording = true
      recordingStartTime = System.currentTimeMillis()
      
      startLevelMonitoring()
    } catch (e: IOException) {
      throw RuntimeException("Failed to start recording: ${e.message}")
    }
  }

  private fun startLevelMonitoring() {
    levelMonitoringRunnable = object : Runnable {
      override fun run() {
        if (isRecording) {
          updateAudioLevels()
          mainHandler.postDelayed(this, 100) // Check every 100ms
        }
      }
    }
    mainHandler.post(levelMonitoringRunnable!!)
  }

  private fun updateAudioLevels() {
    if (!isRecording || audioRecord == null) return

    val bufferSize = 1024
    val buffer = ShortArray(bufferSize)
    val read = audioRecord!!.read(buffer, 0, bufferSize)
    
    if (read > 0) {
      val amplitude = calculateAmplitude(buffer, read)
      val dbLevel = amplitudeToDb(amplitude)
      val currentTime = System.currentTimeMillis()

      // Check if we've reached max duration
      if ((currentTime - recordingStartTime) / 1000.0 >= maxDurationSeconds) {
        finishRecordingWithReason("max_duration_reached")
        return
      }

      // Voice activity detection
      if (dbLevel > noiseFloorDb && dbLevel > voiceActivityThresholdDb) {
        // Voice detected
        if (!hasDetectedVoice) {
          hasDetectedVoice = true
          actualSpeechStartTime = currentTime
        }

        lastVoiceActivityTime = currentTime
        isInThinkingPause = false

        // Cancel any pending silence timer
        silenceTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        silenceTimeoutRunnable = null

      } else if (hasDetectedVoice) {
        // Silence detected after voice
        val silenceDuration = (currentTime - lastVoiceActivityTime) / 1000.0

        if (silenceDuration >= thinkingPauseThreshold && !isInThinkingPause) {
          // Entered thinking pause
          isInThinkingPause = true

          // Schedule end-of-speech detection
          val remainingTime = ((endOfSpeechThreshold - thinkingPauseThreshold) * 1000).toLong()
          silenceTimeoutRunnable = Runnable { handleEndOfSpeech() }
          mainHandler.postDelayed(silenceTimeoutRunnable!!, remainingTime)
        }
      }
    }
  }

  private fun calculateAmplitude(buffer: ShortArray, read: Int): Double {
    var sum = 0.0
    for (i in 0 until read) {
      sum += (buffer[i] * buffer[i]).toDouble()
    }
    return sqrt(sum / read)
  }

  private fun amplitudeToDb(amplitude: Double): Double {
    return if (amplitude > 0) {
      20 * log10(amplitude / 32767.0)
    } else {
      -96.0 // Minimum dB level
    }
  }

  private fun handleEndOfSpeech() {
    val currentTime = System.currentTimeMillis()
    val totalSilence = (currentTime - lastVoiceActivityTime) / 1000.0

    if (totalSilence >= endOfSpeechThreshold) {
      // Calculate actual speech duration (excluding final silence)
      totalSpeechDuration = (lastVoiceActivityTime - actualSpeechStartTime) / 1000.0

      // Only finish if we have minimum recording duration
      if ((currentTime - recordingStartTime) >= minRecordingDurationMs) {
        finishRecordingWithReason("silence_detected")
      }
    }
  }

  private fun finishRecordingWithReason(reason: String) {
    stopLevelMonitoring()

    if (!isRecording) return

    try {
      mediaRecorder?.stop()
      audioRecord?.stop()
      isRecording = false

      val endTime = System.currentTimeMillis()
      val totalDuration = (endTime - recordingStartTime) / 1000.0

      // Get file info
      val file = File(outputFilePath ?: "")
      val fileSize = if (file.exists()) file.length() else 0L

      val result = WritableNativeMap().apply {
        putString("filePath", outputFilePath)
        putDouble("duration", totalDuration)
        putDouble("actualSpeechDuration", totalSpeechDuration)
        putDouble("fileSize", fileSize.toDouble())
        putString("reason", reason)
      }

      currentPromise?.resolve(result)
      currentPromise = null

    } catch (e: Exception) {
      currentPromise?.reject("recording_finish_error", "Failed to finish recording: ${e.message}")
      currentPromise = null
    } finally {
      cleanup()
    }
  }

  override fun stopRecording(promise: Promise) {
    if (!isRecording) {
      promise.reject("not_recording", "No recording in progress")
      return
    }

    // Update promise for manual stop
    currentPromise = promise

    // Calculate speech duration up to now
    val currentTime = System.currentTimeMillis()
    if (hasDetectedVoice) {
      totalSpeechDuration = (currentTime - actualSpeechStartTime) / 1000.0
    }

    finishRecordingWithReason("manual_stop")
  }

  override fun cancelRecording(promise: Promise) {
    stopLevelMonitoring()

    if (isRecording) {
      try {
        mediaRecorder?.stop()
        audioRecord?.stop()
        isRecording = false

        // Delete the file
        outputFilePath?.let { path ->
          val file = File(path)
          if (file.exists()) {
            file.delete()
          }
        }
      } catch (e: Exception) {
        // Ignore errors during cleanup
      }
    }

    cleanup()
    currentPromise = null
    promise.resolve(null)
  }

  override fun isRecording(): Boolean {
    return isRecording
  }

  override fun checkMicrophonePermission(promise: Promise) {
    val hasPermission = ContextCompat.checkSelfPermission(
      reactApplicationContext,
      Manifest.permission.RECORD_AUDIO
    ) == PackageManager.PERMISSION_GRANTED

    promise.resolve(hasPermission)
  }

  override fun requestMicrophonePermission(promise: Promise) {
    val hasPermission = hasRecordAudioPermission()
    if (hasPermission) {
      promise.resolve(true)
      return
    }

    val currentActivity = currentActivity
    if (currentActivity == null) {
      promise.reject("no_activity", "No current activity available")
      return
    }

    // For TurboModule context, we'll request permission and return current status
    // The calling code should handle the actual permission result via system callbacks
    ActivityCompat.requestPermissions(
      currentActivity,
      arrayOf(Manifest.permission.RECORD_AUDIO),
      PERMISSION_REQUEST_CODE
    )
    
    // Return false since permission was just requested
    promise.resolve(false)
  }

  override fun addListener(eventName: String) {
    // No-op for now, required by TurboModule
  }

  override fun removeListeners(count: Double) {
    // No-op for now, required by TurboModule
  }

  private fun hasRecordAudioPermission(): Boolean {
    return ContextCompat.checkSelfPermission(
      reactApplicationContext,
      Manifest.permission.RECORD_AUDIO
    ) == PackageManager.PERMISSION_GRANTED
  }

  private fun stopLevelMonitoring() {
    levelMonitoringRunnable?.let { mainHandler.removeCallbacks(it) }
    silenceTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
    levelMonitoringRunnable = null
    silenceTimeoutRunnable = null
  }

  private fun cleanup() {
    try {
      mediaRecorder?.release()
      audioRecord?.release()
    } catch (e: Exception) {
      // Ignore cleanup errors
    }
    mediaRecorder = null
    audioRecord = null
  }

  override fun onCatalystInstanceDestroy() {
    super.onCatalystInstanceDestroy()
    permissionPromise = null
  }

  companion object {
    const val NAME = "AudioRecorder"
    private const val PERMISSION_REQUEST_CODE = 1001
  }
}
