import { type RecordingResult } from './NativeAudioRecorder';
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
export declare class AudioRecorder {
    static checkMicrophonePermission(): Promise<boolean>;
    static requestMicrophonePermission(): Promise<boolean>;
    static startRecording(config?: SimpleRecordingConfig): Promise<RecordingResult>;
    static stopRecording(): Promise<RecordingResult>;
    static cancelRecording(): Promise<void>;
    static isRecording(): boolean;
    /**
     * Simple recording with automatic voice activity detection
     * Returns a promise that resolves when the user stops talking
     */
    static record(config?: SimpleRecordingConfig): Promise<RecordingResult>;
    /**
     * Quick recording with sensible defaults for voice messages
     */
    static recordVoiceMessage(): Promise<RecordingResult>;
    /**
     * High quality recording for music or professional use
     */
    static recordHighQuality(maxDurationSeconds?: number): Promise<RecordingResult>;
}
export default AudioRecorder;
//# sourceMappingURL=index.d.ts.map