#import "AudioRecorder.h"
#import <AVFoundation/AVFoundation.h>

@interface AudioRecorder () <AVAudioRecorderDelegate>
@property (nonatomic, strong) AVAudioRecorder *audioRecorder;
@property (nonatomic, strong) NSTimer *levelTimer;
@property (nonatomic, strong) NSTimer *silenceTimer;
@property (nonatomic) double thinkingPauseThreshold;
@property (nonatomic) double endOfSpeechThreshold;
@property (nonatomic) double noiseFloorDb;
@property (nonatomic) double voiceActivityThresholdDb;
@property (nonatomic) double maxDurationSeconds;
@property (nonatomic) double minRecordingDurationMs;
@property (nonatomic) NSTimeInterval recordingStartTime;
@property (nonatomic) NSTimeInterval lastVoiceActivityTime;
@property (nonatomic) NSTimeInterval actualSpeechStartTime;
@property (nonatomic) NSTimeInterval totalSpeechDuration;
@property (nonatomic) BOOL hasDetectedVoice;
@property (nonatomic) BOOL isInThinkingPause;
@property (nonatomic, strong) RCTPromiseResolveBlock currentPromiseResolve;
@property (nonatomic, strong) RCTPromiseRejectBlock currentPromiseReject;
@end

@implementation AudioRecorder
RCT_EXPORT_MODULE()

- (void)startRecording:(JS::NativeAudioRecorder::RecordingConfig &)config
               resolve:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject {
    
    if (self.audioRecorder && self.audioRecorder.isRecording) {
        reject(@"recording_in_progress", @"Recording is already in progress", nil);
        return;
    }
    
    // Store config
    self.thinkingPauseThreshold = config.thinkingPauseThreshold();
    self.endOfSpeechThreshold = config.endOfSpeechThreshold();
    self.noiseFloorDb = config.noiseFloorDb();
    self.voiceActivityThresholdDb = config.voiceActivityThresholdDb();
    self.maxDurationSeconds = config.maxDurationSeconds();
    self.minRecordingDurationMs = config.minRecordingDurationMs();
    
    // Adjust thresholds for iOS AVAudioRecorder range (-160 to 0 dB)
    [self adjustThresholdsForIOS];
    
    NSLog(@"[AudioRecorder] Config - Original NoiseFloor: %.1fdB, VoiceThreshold: %.1fdB, ThinkingThreshold: %.1fs, EndThreshold: %.1fs", 
          self.noiseFloorDb, self.voiceActivityThresholdDb, self.thinkingPauseThreshold, self.endOfSpeechThreshold);
    
    // Reset state
    self.recordingStartTime = 0;
    self.lastVoiceActivityTime = 0;
    self.actualSpeechStartTime = 0;
    self.totalSpeechDuration = 0;
    self.hasDetectedVoice = NO;
    self.isInThinkingPause = NO;
    self.currentPromiseResolve = resolve;
    self.currentPromiseReject = reject;
    
    // Setup audio session with proper category for recording
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    
    // Use Record category for better recording performance and noise reduction
    [session setCategory:AVAudioSessionCategoryRecord
                    mode:AVAudioSessionModeMeasurement  // Better for voice recording
                 options:AVAudioSessionCategoryOptionAllowBluetooth
                   error:&error];
    if (error) {
        reject(@"audio_session_error", @"Failed to setup audio session", error);
        return;
    }
    
    // Set preferred sample rate and buffer duration for better VAD
    [session setPreferredSampleRate:config.sampleRate() error:&error];
    if (error) {
        NSLog(@"[AudioRecorder] Warning: Could not set preferred sample rate: %@", error.localizedDescription);
    }
    
    [session setPreferredIOBufferDuration:0.01 error:&error]; // 10ms for responsive VAD
    if (error) {
        NSLog(@"[AudioRecorder] Warning: Could not set buffer duration: %@", error.localizedDescription);
    }
    
    [session setActive:YES error:&error];
    if (error) {
        reject(@"audio_session_error", @"Failed to activate audio session", error);
        return;
    }
    
    // Validate configuration
    if (config.sampleRate() < 8000 || config.sampleRate() > 48000) {
        reject(@"invalid_config", @"Sample rate must be between 8000 and 48000 Hz", nil);
        return;
    }
    if (config.channels() < 1 || config.channels() > 2) {
        reject(@"invalid_config", @"Channels must be 1 (mono) or 2 (stereo)", nil);
        return;
    }
    if (config.bitRate() < 8000 || config.bitRate() > 320000) {
        reject(@"invalid_config", @"Bit rate must be between 8000 and 320000 bps", nil);
        return;
    }
    
    // Setup recording settings with proper format handling
    NSMutableDictionary *settings = [[NSMutableDictionary alloc] init];
    NSString *actualFormat = config.format();
    
    // Handle format compatibility - iOS doesn't support MP3 encoding
    if ([config.format() isEqualToString:@"mp3"]) {
        actualFormat = @"m4a"; // Use M4A instead
        settings[AVFormatIDKey] = @(kAudioFormatMPEG4AAC);
        NSLog(@"[AudioRecorder] MP3 format not supported on iOS, using M4A/AAC instead");
    } else if ([config.format() isEqualToString:@"aac"]) {
        settings[AVFormatIDKey] = @(kAudioFormatMPEG4AAC);
    } else if ([config.format() isEqualToString:@"wav"]) {
        settings[AVFormatIDKey] = @(kAudioFormatLinearPCM);
        // WAV-specific settings
        settings[AVLinearPCMBitDepthKey] = @(16);
        settings[AVLinearPCMIsBigEndianKey] = @(NO);
        settings[AVLinearPCMIsFloatKey] = @(NO);
    } else {
        // Default to AAC for unknown formats
        actualFormat = @"aac";
        settings[AVFormatIDKey] = @(kAudioFormatMPEG4AAC);
        NSLog(@"[AudioRecorder] Unknown format '%@', defaulting to AAC", config.format());
    }
    
    settings[AVSampleRateKey] = @(config.sampleRate());
    settings[AVNumberOfChannelsKey] = @(config.channels());
    settings[AVEncoderBitRateKey] = @(config.bitRate());
    settings[AVEncoderAudioQualityKey] = @(AVAudioQualityHigh);
    
    // Create output file path with corrected format
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *fileName = [NSString stringWithFormat:@"recording_%f.%@", [[NSDate date] timeIntervalSince1970], actualFormat];
    NSURL *outputFileURL = [NSURL fileURLWithPath:[documentsDirectory stringByAppendingPathComponent:fileName]];
    
    NSLog(@"[AudioRecorder] Creating recording file: %@ (requested: %@, actual: %@)", 
          fileName, config.format(), actualFormat);
    
    // Create recorder
    self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:outputFileURL settings:settings error:&error];
    if (error) {
        reject(@"recorder_creation_error", @"Failed to create audio recorder", error);
        return;
    }
    
    self.audioRecorder.delegate = self;
    self.audioRecorder.meteringEnabled = YES;
    
    // Start recording
    BOOL success = [self.audioRecorder record];
    if (!success) {
        reject(@"recording_start_error", @"Failed to start recording", nil);
        return;
    }
    
    self.recordingStartTime = [[NSDate date] timeIntervalSince1970];
    
    NSLog(@"[AudioRecorder] Recording started successfully at %.3f", self.recordingStartTime);
    
    // Start level monitoring
    [self startLevelMonitoring];
    
    // Don't resolve here - let finishRecordingWithReason handle the promise
    NSLog(@"[AudioRecorder] Recording setup complete, waiting for voice activity detection");
}

- (void)adjustThresholdsForIOS {
    // CRITICAL: AVAudioRecorder uses different dB range (-160 to 0) than Android
    // Android MediaRecorder uses 0-32767 amplitude converted to dB
    // We need to map our Android-compatible thresholds to iOS range
    
    // If thresholds seem to be in Android range (negative values closer to 0), adjust them
    if (self.noiseFloorDb > -100) {
        // Likely Android-style threshold, map to iOS range
        // Android -50dB noise floor -> iOS -80dB noise floor
        // Android -35dB voice threshold -> iOS -40dB voice threshold
        self.noiseFloorDb = self.noiseFloorDb - 30.0;  // Make more negative for iOS
        self.voiceActivityThresholdDb = self.voiceActivityThresholdDb - 5.0;  // Adjust voice threshold
        
        NSLog(@"[AudioRecorder] Adjusted thresholds for iOS: NoiseFloor: %.1fdB, VoiceThreshold: %.1fdB", 
              self.noiseFloorDb, self.voiceActivityThresholdDb);
    }
    
    // Ensure values are within iOS range
    self.noiseFloorDb = MAX(-160.0, MIN(0.0, self.noiseFloorDb));
    self.voiceActivityThresholdDb = MAX(-160.0, MIN(0.0, self.voiceActivityThresholdDb));
    
    // Ensure voice threshold is higher than noise floor
    if (self.voiceActivityThresholdDb <= self.noiseFloorDb) {
        self.voiceActivityThresholdDb = self.noiseFloorDb + 10.0;
    }
}

- (void)startLevelMonitoring {
    self.levelTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                       target:self
                                                     selector:@selector(updateAudioLevels)
                                                     userInfo:nil
                                                      repeats:YES];
}

- (void)updateAudioLevels {
    if (!self.audioRecorder || !self.audioRecorder.isRecording) {
        [self.levelTimer invalidate];
        return;
    }
    
    [self.audioRecorder updateMeters];
    float averagePower = [self.audioRecorder averagePowerForChannel:0]; // This is already in dB
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    // Add detailed logging with proper AVAudioRecorder range understanding
    NSLog(@"[AudioRecorder] Audio Level - Raw dB: %.1f (Range: -160 to 0), ConfigNoiseFloor: %.1f, ConfigVoiceThreshold: %.1f", 
          averagePower, self.noiseFloorDb, self.voiceActivityThresholdDb);
    
    // Check if we've reached max duration
    if (currentTime - self.recordingStartTime >= self.maxDurationSeconds) {
        NSLog(@"[AudioRecorder] FINISHING RECORDING - Reason: max_duration_reached");
        [self finishRecordingWithReason:@"max_duration_reached"];
        return;
    }
    
    [self processVoiceActivity:averagePower currentTime:currentTime];
}

- (void)processVoiceActivity:(float)dbLevel currentTime:(NSTimeInterval)currentTime {
    // Voice activity detection using pre-adjusted thresholds for iOS range (-160 to 0 dB)
    BOOL isVoice = (dbLevel > self.noiseFloorDb) && (dbLevel > self.voiceActivityThresholdDb);
    
    NSLog(@"[AudioRecorder] Voice Activity - dB: %.1f, NoiseFloor: %.1f, VoiceThreshold: %.1f, isVoice: %@, hasDetectedVoice: %@", 
          dbLevel, self.noiseFloorDb, self.voiceActivityThresholdDb, isVoice ? @"YES" : @"NO", self.hasDetectedVoice ? @"YES" : @"NO");
    
    if (isVoice) {
        // Voice detected
        if (!self.hasDetectedVoice) {
            self.hasDetectedVoice = YES;
            self.actualSpeechStartTime = currentTime;
            NSTimeInterval timeSinceStart = (currentTime - self.recordingStartTime) * 1000; // Convert to ms
            NSLog(@"[AudioRecorder] VOICE STARTED - First voice detected at %.0fms", timeSinceStart);
        }
        
        self.lastVoiceActivityTime = currentTime;
        self.isInThinkingPause = NO;
        
        // Cancel any pending silence timer
        [self.silenceTimer invalidate];
        self.silenceTimer = nil;
        
    } else if (self.hasDetectedVoice) {
        // Silence detected after voice
        NSTimeInterval silenceDuration = currentTime - self.lastVoiceActivityTime;
        
        NSLog(@"[AudioRecorder] SILENCE - Duration: %.1fs, ThinkingThreshold: %.1fs, EndThreshold: %.1fs", 
              silenceDuration, self.thinkingPauseThreshold, self.endOfSpeechThreshold);
        
        if (silenceDuration >= self.thinkingPauseThreshold && !self.isInThinkingPause) {
            // Entered thinking pause
            self.isInThinkingPause = YES;
            NSLog(@"[AudioRecorder] THINKING PAUSE - Entered at %.1fs", silenceDuration);
            
            // Schedule end-of-speech detection with calculated remaining time
            NSTimeInterval remainingTime = self.endOfSpeechThreshold - self.thinkingPauseThreshold;
            self.silenceTimer = [NSTimer scheduledTimerWithTimeInterval:remainingTime
                                                                 target:self
                                                               selector:@selector(handleEndOfSpeech)
                                                               userInfo:nil
                                                                repeats:NO];
        }
    }
}

- (void)handleEndOfSpeech {
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval totalSilence = currentTime - self.lastVoiceActivityTime;
    NSTimeInterval totalRecordingDuration = (currentTime - self.recordingStartTime) * 1000; // Convert to ms
    
    NSLog(@"[AudioRecorder] END OF SPEECH CHECK - TotalSilence: %.1fs, Threshold: %.1fs, RecordingDuration: %.0fms, MinDuration: %.0fms", 
          totalSilence, self.endOfSpeechThreshold, totalRecordingDuration, self.minRecordingDurationMs);
    
    if (totalSilence >= self.endOfSpeechThreshold) {
        // Calculate actual speech duration (excluding final silence)
        self.totalSpeechDuration = self.lastVoiceActivityTime - self.actualSpeechStartTime;
        
        NSLog(@"[AudioRecorder] SILENCE THRESHOLD MET - SpeechDuration: %.1fs", self.totalSpeechDuration);
        
        // Only finish if we have minimum recording duration
        if (totalRecordingDuration >= self.minRecordingDurationMs) {
            NSLog(@"[AudioRecorder] FINISHING RECORDING - Reason: silence_detected");
            [self finishRecordingWithReason:@"silence_detected"];
        } else {
            NSLog(@"[AudioRecorder] Recording too short - Need %.0fms, have %.0fms", 
                  self.minRecordingDurationMs, totalRecordingDuration);
        }
    } else {
        NSLog(@"[AudioRecorder] Silence not long enough yet - %.1fs < %.1fs", 
              totalSilence, self.endOfSpeechThreshold);
    }
}

- (void)finishRecordingWithReason:(NSString *)reason {
    NSLog(@"[AudioRecorder] finishRecordingWithReason called with reason: %@", reason);
    
    [self.levelTimer invalidate];
    [self.silenceTimer invalidate];
    self.levelTimer = nil;
    self.silenceTimer = nil;
    
    if (!self.audioRecorder) {
        NSLog(@"[AudioRecorder] finishRecordingWithReason - No audio recorder available");
        return;
    }
    
    [self.audioRecorder stop];
    NSLog(@"[AudioRecorder] Audio recorder stopped");
    
    NSTimeInterval endTime = [[NSDate date] timeIntervalSince1970];
    double totalDuration = endTime - self.recordingStartTime;
    
    NSLog(@"[AudioRecorder] Recording finished - TotalDuration: %.1fs, SpeechDuration: %.1fs, Reason: %@", 
          totalDuration, self.totalSpeechDuration, reason);
    
    // Get file info
    NSURL *fileURL = self.audioRecorder.url;
    NSString *filePath = [fileURL path];
    
    NSError *error;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];
    unsigned long long fileSize = error ? 0 : [fileAttributes fileSize];
    
    NSLog(@"[AudioRecorder] File info - Path: %@, Size: %llu bytes", filePath, fileSize);
    
    // Ensure we have a valid file
    if (fileSize == 0 && !error) {
        error = [NSError errorWithDomain:@"AudioRecorderError" code:1001 userInfo:@{NSLocalizedDescriptionKey: @"Recording file is empty"}];
        NSLog(@"[AudioRecorder] Error: Recording file is empty");
    }
    
    if (self.currentPromiseResolve) {
        if (error && [reason isEqualToString:@"error"]) {
            self.currentPromiseReject(@"recording_error", error.localizedDescription, error);
        } else {
            NSDictionary *result = @{
                @"filePath": filePath ?: @"",
                @"duration": @(totalDuration),
                @"actualSpeechDuration": @(self.totalSpeechDuration),
                @"fileSize": @(fileSize),
                @"reason": reason
            };
            
            self.currentPromiseResolve(result);
        }
        
        self.currentPromiseResolve = nil;
        self.currentPromiseReject = nil;
    }
    
    self.audioRecorder = nil;
}

- (void)stopRecording:(RCTPromiseResolveBlock)resolve
               reject:(RCTPromiseRejectBlock)reject {
    
    NSLog(@"[AudioRecorder] stopRecording called, isRecording: %@", self.audioRecorder.isRecording ? @"YES" : @"NO");
    
    if (!self.audioRecorder || !self.audioRecorder.isRecording) {
        NSLog(@"[AudioRecorder] stopRecording failed - No recording in progress");
        reject(@"not_recording", @"No recording in progress", nil);
        return;
    }
    
    // Update promise handlers for manual stop
    self.currentPromiseResolve = resolve;
    self.currentPromiseReject = reject;
    
    // Calculate speech duration up to now
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (self.hasDetectedVoice) {
        self.totalSpeechDuration = currentTime - self.actualSpeechStartTime;
        NSLog(@"[AudioRecorder] Manual stop - calculated speech duration: %.1fs", self.totalSpeechDuration);
    }
    
    NSLog(@"[AudioRecorder] FINISHING RECORDING - Reason: manual_stop");
    [self finishRecordingWithReason:@"manual_stop"];
}

- (void)cancelRecording:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject {
    
    NSLog(@"[AudioRecorder] cancelRecording called, isRecording: %@", self.audioRecorder.isRecording ? @"YES" : @"NO");
    
    [self.levelTimer invalidate];
    [self.silenceTimer invalidate];
    
    if (self.audioRecorder) {
        [self.audioRecorder stop];
        NSLog(@"[AudioRecorder] Recording stopped for cancellation");
        
        // Delete the file
        NSError *error;
        NSURL *fileURL = self.audioRecorder.url;
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:&error];
        
        if (error) {
            NSLog(@"[AudioRecorder] Error deleting recording file: %@", error.localizedDescription);
        } else {
            NSLog(@"[AudioRecorder] Recording file deleted successfully");
        }
        
        self.audioRecorder = nil;
    }
    
    self.currentPromiseResolve = nil;
    self.currentPromiseReject = nil;
    
    NSLog(@"[AudioRecorder] Recording cancelled successfully");
    resolve(nil);
}

- (BOOL)isRecording {
    return self.audioRecorder != nil && self.audioRecorder.isRecording;
}

- (void)checkMicrophonePermission:(RCTPromiseResolveBlock)resolve
                          reject:(RCTPromiseRejectBlock)reject {
    
    AVAudioSessionRecordPermission permission = [[AVAudioSession sharedInstance] recordPermission];
    resolve(@(permission == AVAudioSessionRecordPermissionGranted));
}

- (void)requestMicrophonePermission:(RCTPromiseResolveBlock)resolve
                            reject:(RCTPromiseRejectBlock)reject {
    
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
        resolve(@(granted));
    }];
}

- (void)addListener:(NSString *)eventName {
    // No-op for now, required by TurboModule
}

- (void)removeListeners:(double)count {
    // No-op for now, required by TurboModule
}

#pragma mark - AVAudioRecorderDelegate

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag {
    if (!flag && self.currentPromiseReject) {
        self.currentPromiseReject(@"recording_failed", @"Recording failed", nil);
        self.currentPromiseResolve = nil;
        self.currentPromiseReject = nil;
    }
}

- (void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder *)recorder error:(NSError *)error {
    if (self.currentPromiseReject) {
        self.currentPromiseReject(@"encoding_error", @"Recording encoding error", error);
        self.currentPromiseResolve = nil;
        self.currentPromiseReject = nil;
    }
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeAudioRecorderSpecJSI>(params);
}

@end
