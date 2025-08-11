import type { TurboModule } from 'react-native';
export interface RecordingConfig {
    format: 'aac' | 'mp3' | 'wav';
    sampleRate: number;
    bitRate: number;
    channels: number;
    thinkingPauseThreshold: number;
    endOfSpeechThreshold: number;
    noiseFloorDb: number;
    voiceActivityThresholdDb: number;
    maxDurationSeconds: number;
    minRecordingDurationMs: number;
}
export interface RecordingResult {
    filePath: string;
    duration: number;
    actualSpeechDuration: number;
    fileSize: number;
    reason: 'silence_detected' | 'manual_stop' | 'max_duration_reached' | 'error';
    error?: string;
}
export interface Spec extends TurboModule {
    startRecording(config: RecordingConfig): Promise<void>;
    stopRecording(): Promise<RecordingResult>;
    cancelRecording(): Promise<void>;
    isRecording(): boolean;
    checkMicrophonePermission(): Promise<boolean>;
    requestMicrophonePermission(): Promise<boolean>;
    addListener(eventName: string): void;
    removeListeners(count: number): void;
}
declare const _default: Spec;
export default _default;
//# sourceMappingURL=NativeAudioRecorder.d.ts.map