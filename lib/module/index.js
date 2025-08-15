"use strict";

import AudioRecorderNative from "./NativeAudioRecorder.js";
const DEFAULT_CONFIG = {
  format: 'aac',
  sampleRate: 44100,
  bitRate: 128000,
  channels: 1,
  thinkingPauseThreshold: 1.5,
  endOfSpeechThreshold: 2.5,
  noiseFloorDb: -50,
  voiceActivityThresholdDb: -35,
  maxDurationSeconds: 300,
  // 5 minutes
  minRecordingDurationMs: 500 // 0.5 seconds
};
export class AudioRecorder {
  static async checkMicrophonePermission() {
    return AudioRecorderNative.checkMicrophonePermission();
  }
  static async requestMicrophonePermission() {
    return AudioRecorderNative.requestMicrophonePermission();
  }
  static async startRecording(config = {}) {
    // Check permissions first
    const hasPermission = await this.checkMicrophonePermission();
    if (!hasPermission) {
      const granted = await this.requestMicrophonePermission();
      if (!granted) {
        throw new Error('Microphone permission is required for recording');
      }
    }

    // Merge with defaults
    const fullConfig = {
      ...DEFAULT_CONFIG,
      ...config
    };

    // Start recording - the native side will handle the full lifecycle and return the result
    return AudioRecorderNative.startRecording(fullConfig);
  }
  static async stopRecording() {
    return AudioRecorderNative.stopRecording();
  }
  static async cancelRecording() {
    return AudioRecorderNative.cancelRecording();
  }
  static isRecording() {
    return AudioRecorderNative.isRecording();
  }

  /**
   * Simple recording with automatic voice activity detection
   * Returns a promise that resolves when the user stops talking
   */
  static async record(config = {}) {
    if (this.isRecording()) {
      throw new Error('Recording already in progress');
    }
    return this.startRecording(config);
  }

  /**
   * Quick recording with sensible defaults for voice messages
   */
  static async recordVoiceMessage() {
    return this.record({
      format: 'aac',
      sampleRate: 22050,
      // Lower sample rate for voice
      bitRate: 64000,
      // Lower bit rate for voice
      channels: 1,
      thinkingPauseThreshold: 1.0,
      endOfSpeechThreshold: 2.0,
      maxDurationSeconds: 120,
      // 2 minutes max for voice messages
      minRecordingDurationMs: 300
    });
  }

  /**
   * High quality recording for music or professional use
   */
  static async recordHighQuality(maxDurationSeconds = 600) {
    return this.record({
      format: 'wav',
      sampleRate: 48000,
      bitRate: 256000,
      channels: 2,
      thinkingPauseThreshold: 2.0,
      endOfSpeechThreshold: 3.0,
      maxDurationSeconds,
      minRecordingDurationMs: 1000
    });
  }
}

// Default export for convenience
export default AudioRecorder;
//# sourceMappingURL=index.js.map