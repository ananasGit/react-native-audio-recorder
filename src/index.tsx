import AudioRecorderNative, {
  type RecordingResult,
} from './NativeAudioRecorder';
export type { RecordingConfig, RecordingResult } from './NativeAudioRecorder';

export interface SimpleRecordingConfig {
  format?: 'aac' | 'mp3' | 'wav';
  sampleRate?: number;
  bitRate?: number;
  channels?: 1 | 2;
  thinkingPauseThreshold?: number;
  endOfSpeechThreshold?: number;
  noiseFloorDb?: number;
  voiceActivityThresholdDb?: number;
  maxDurationSeconds?: number;
  minRecordingDurationMs?: number;
}

const DEFAULT_CONFIG: Required<SimpleRecordingConfig> = {
  format: 'aac',
  sampleRate: 44100,
  bitRate: 128000,
  channels: 1,
  thinkingPauseThreshold: 1.5,
  endOfSpeechThreshold: 2.5,
  noiseFloorDb: -50,
  voiceActivityThresholdDb: -35,
  maxDurationSeconds: 300, // 5 minutes
  minRecordingDurationMs: 500, // 0.5 seconds
};

export class AudioRecorder {
  static async checkMicrophonePermission(): Promise<boolean> {
    return AudioRecorderNative.checkMicrophonePermission();
  }

  static async requestMicrophonePermission(): Promise<boolean> {
    return AudioRecorderNative.requestMicrophonePermission();
  }

  static async startRecording(
    config: SimpleRecordingConfig = {}
  ): Promise<RecordingResult> {
    // Check permissions first
    const hasPermission = await this.checkMicrophonePermission();
    if (!hasPermission) {
      const granted = await this.requestMicrophonePermission();
      if (!granted) {
        throw new Error('Microphone permission is required for recording');
      }
    }

    // Merge with defaults
    const fullConfig = { ...DEFAULT_CONFIG, ...config };

    // Start recording and return a promise that resolves when recording ends
    return new Promise((resolve, reject) => {
      let isResolved = false;

      // Start the recording
      AudioRecorderNative.startRecording(fullConfig)
        .then(() => {
          // Recording started successfully
          // Now we wait for either manual stop or automatic detection

          // Set up a timeout as fallback for max duration
          const maxTimeout = setTimeout(() => {
            if (!isResolved) {
              this.stopRecording().then(resolve).catch(reject);
            }
          }, fullConfig.maxDurationSeconds * 1000);

          // Store the timeout and resolve function for later use
          (this as any)._currentTimeout = maxTimeout;
          (this as any)._currentResolve = (result: RecordingResult) => {
            if (!isResolved) {
              isResolved = true;
              clearTimeout(maxTimeout);
              resolve(result);
            }
          };
          (this as any)._currentReject = (error: Error) => {
            if (!isResolved) {
              isResolved = true;
              clearTimeout(maxTimeout);
              reject(error);
            }
          };
        })
        .catch((error) => {
          if (!isResolved) {
            isResolved = true;
            reject(error);
          }
        });
    });
  }

  static async stopRecording(): Promise<RecordingResult> {
    try {
      const result = await AudioRecorderNative.stopRecording();

      // Clean up any pending timeouts/callbacks
      if ((this as any)._currentTimeout) {
        clearTimeout((this as any)._currentTimeout);
        delete (this as any)._currentTimeout;
      }

      return result;
    } catch (error) {
      throw error;
    } finally {
      delete (this as any)._currentResolve;
      delete (this as any)._currentReject;
    }
  }

  static async cancelRecording(): Promise<void> {
    try {
      await AudioRecorderNative.cancelRecording();
    } finally {
      // Clean up any pending timeouts/callbacks
      if ((this as any)._currentTimeout) {
        clearTimeout((this as any)._currentTimeout);
        delete (this as any)._currentTimeout;
      }
      delete (this as any)._currentResolve;
      delete (this as any)._currentReject;
    }
  }

  static isRecording(): boolean {
    return AudioRecorderNative.isRecording();
  }

  /**
   * Simple recording with automatic voice activity detection
   * Returns a promise that resolves when the user stops talking
   */
  static async record(
    config: SimpleRecordingConfig = {}
  ): Promise<RecordingResult> {
    if (this.isRecording()) {
      throw new Error('Recording already in progress');
    }

    return this.startRecording(config);
  }

  /**
   * Quick recording with sensible defaults for voice messages
   */
  static async recordVoiceMessage(): Promise<RecordingResult> {
    return this.record({
      format: 'aac',
      sampleRate: 22050, // Lower sample rate for voice
      bitRate: 64000, // Lower bit rate for voice
      channels: 1,
      thinkingPauseThreshold: 1.0,
      endOfSpeechThreshold: 2.0,
      maxDurationSeconds: 120, // 2 minutes max for voice messages
      minRecordingDurationMs: 300,
    });
  }

  /**
   * High quality recording for music or professional use
   */
  static async recordHighQuality(
    maxDurationSeconds: number = 600
  ): Promise<RecordingResult> {
    return this.record({
      format: 'wav',
      sampleRate: 48000,
      bitRate: 256000,
      channels: 2,
      thinkingPauseThreshold: 2.0,
      endOfSpeechThreshold: 3.0,
      maxDurationSeconds,
      minRecordingDurationMs: 1000,
    });
  }
}

// Default export for convenience
export default AudioRecorder;
