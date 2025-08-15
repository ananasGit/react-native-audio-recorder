# react-native-audio-recorder

🎙️ **Smart audio recording library for React Native with automatic voice activity detection**

No more fiddling with audio levels in JavaScript! This library handles voice detection, silence detection, and automatic stopping internally, giving you a clean and simple API.

## Features

- ✅ **Smart Voice Activity Detection** - Automatically detects when you start/stop talking
- ✅ **Thinking Pauses** - Ignores brief pauses (1-2s) so users can think while speaking  
- ✅ **End-of-Speech Detection** - Automatically stops after sustained silence (2.5s)
- ✅ **Noise Filtering** - Built-in background noise filtering
- ✅ **Multiple Formats** - AAC, MP3, WAV support with configurable quality
- ✅ **Permission Handling** - Automatic microphone permission requests
- ✅ **TypeScript** - Full TypeScript support with detailed types
- ✅ **Cross Platform** - iOS and Android support

## Installation

```sh
npm install react-native-audio-recorder
```

### iOS Setup

Add microphone permission to your `ios/YourApp/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs access to microphone to record audio</string>
```

### Android Setup

Add microphone permission to your `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

## Usage

### Simple Recording (Recommended)

The easiest way - just start recording and let the library automatically stop when the user finishes speaking:

```js
import AudioRecorder from 'react-native-audio-recorder';

try {
  const result = await AudioRecorder.record();
  
  console.log('Recording completed:', {
    filePath: result.filePath,                    // "/path/to/recording.aac"
    duration: result.duration,                    // 5.2 seconds (total)
    actualSpeechDuration: result.actualSpeechDuration, // 4.1 seconds (without final silence)
    fileSize: result.fileSize,                    // 245760 bytes
    reason: result.reason                         // "silence_detected"
  });
} catch (error) {
  console.error('Recording failed:', error);
}
```

### Preset Configurations

**Voice Messages (optimized for speech):**
```js
const result = await AudioRecorder.recordVoiceMessage();
// 22kHz, 64kbps, 2 minutes max, optimized for voice
```

**High Quality (music/professional):**
```js
const result = await AudioRecorder.recordHighQuality(60); // 60 seconds max
// 48kHz WAV stereo, professional quality
```

### Custom Configuration

```js
const result = await AudioRecorder.record({
  format: 'aac',                        // 'aac' | 'mp3' | 'wav'
  sampleRate: 44100,                    // Sample rate in Hz
  bitRate: 128000,                      // Bit rate for compression
  channels: 1,                          // 1 = mono, 2 = stereo
  
  // Voice Activity Detection
  thinkingPauseThreshold: 1.5,          // Allow 1.5s thinking pauses
  endOfSpeechThreshold: 2.5,            // Stop after 2.5s of silence
  noiseFloorDb: -50,                    // Ignore sounds below -50dB
  voiceActivityThresholdDb: -35,        // Detect voice above -35dB
  
  // Limits
  maxDurationSeconds: 300,              // 5 minutes max
  minRecordingDurationMs: 500,          // Minimum 0.5 seconds
});
```

### Manual Control

If you need manual control over recording:

```js
// Start recording (with auto-detection still active)
AudioRecorder.startRecording({
  format: 'aac',
  endOfSpeechThreshold: 3.0  // Longer silence threshold
});

// Check if currently recording
const isRecording = AudioRecorder.isRecording();

// Stop manually
const result = await AudioRecorder.stopRecording();

// Cancel recording (deletes file)
await AudioRecorder.cancelRecording();
```

### Permission Handling

The library handles permissions automatically, but you can also check manually:

```js
// Check current permission status
const hasPermission = await AudioRecorder.checkMicrophonePermission();

// Request permission if needed
const granted = await AudioRecorder.requestMicrophonePermission();
```

## How It Works

### Voice Activity Detection

The library uses real-time audio level monitoring to intelligently detect:

1. **Voice Start**: When audio levels rise above the noise floor and voice threshold
2. **Thinking Pauses**: Brief silences (1-2s) are ignored - keep talking!
3. **End of Speech**: Sustained silence (2.5s+) triggers automatic stop
4. **Noise Filtering**: Background noise below the noise floor is ignored

### Recording Flow

```
User starts speaking → Voice detected → Recording begins
User pauses briefly → Thinking pause → Continue recording  
User stops speaking → Silence detected → Wait for end-of-speech threshold
Still silent after threshold → Auto-stop → Return result
```

### Result Reasons

- `"silence_detected"` - Automatically stopped after detecting end of speech
- `"manual_stop"` - User called `stopRecording()` manually  
- `"max_duration_reached"` - Hit the maximum duration limit
- `"error"` - An error occurred during recording

## API Reference

### AudioRecorder

#### Methods

- `record(config?)` - Start recording with automatic voice detection
- `recordVoiceMessage()` - Quick voice message recording (optimized)
- `recordHighQuality(maxDuration?)` - High quality recording
- `startRecording(config)` - Start recording (manual control)
- `stopRecording()` - Stop recording manually
- `cancelRecording()` - Cancel and delete recording
- `isRecording()` - Check if currently recording
- `checkMicrophonePermission()` - Check permission status
- `requestMicrophonePermission()` - Request microphone permission

#### Types

```typescript
interface RecordingResult {
  filePath: string;                    // Absolute path to recorded file
  duration: number;                    // Total recording duration (seconds)
  actualSpeechDuration: number;        // Speech duration without final silence
  fileSize: number;                    // File size in bytes
  reason: 'silence_detected' | 'manual_stop' | 'max_duration_reached' | 'error';
  error?: string;                      // Error message if reason is 'error'
}

interface SimpleRecordingConfig {
  format?: 'aac' | 'mp3' | 'wav';
  sampleRate?: number;                 // Default: 44100
  bitRate?: number;                    // Default: 128000
  channels?: 1 | 2;                    // Default: 1 (mono)
  thinkingPauseThreshold?: number;     // Default: 1.5 seconds
  endOfSpeechThreshold?: number;       // Default: 2.5 seconds  
  noiseFloorDb?: number;               // Default: -50 dB
  voiceActivityThresholdDb?: number;   // Default: -35 dB
  maxDurationSeconds?: number;         // Default: 300 (5 minutes)
  minRecordingDurationMs?: number;     // Default: 500 ms
}
```

## Comparison with Other Libraries

| Feature | react-native-audio-recorder | react-native-audio-recorder-player | Others |
|---------|----------------------------|-----------------------------------|---------|
| Voice Activity Detection | ✅ Built-in | ❌ Manual JS handling | ❌ Manual |
| Automatic stopping | ✅ Smart silence detection | ❌ Manual | ❌ Manual |
| Thinking pauses | ✅ Intelligent | ❌ Manual | ❌ Manual |
| Clean API | ✅ Promise-based | ❌ Event-based | Mixed |
| TypeScript | ✅ Full support | Partial | Mixed |
| Size | Small | Large | Varies |
| Focus | Recording only | Recording + Playing | Varies |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and guidelines.

## License

MIT

---

Made with ❤️ by [Ananas](https://github.com/ananasGit)
