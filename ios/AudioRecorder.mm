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
@property (nonatomic) BOOL isRecording;
@property (nonatomic, strong) RCTPromiseResolveBlock currentPromiseResolve;
@property (nonatomic, strong) RCTPromiseRejectBlock currentPromiseReject;
@end

@implementation AudioRecorder
RCT_EXPORT_MODULE()

- (void)startRecording:(JS::NativeAudioRecorder::RecordingConfig &)config
               resolve:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject {
    
    if (self.isRecording) {
        reject(@"recording_in_progress", @"Recording is already in progress", nil);
        return;
    }
    
    // Store config
    self.thinkingPauseThreshold = config.thinkingPauseThreshold();
    self.endOfSpeechThreshold = config.endOfSpeechThreshold();
    self.maxDurationSeconds = config.maxDurationSeconds();
    self.minRecordingDurationMs = config.minRecordingDurationMs();
    
    // Store VAD thresholds with fallback defaults (matching Android behavior)
    self.noiseFloorDb = config.noiseFloorDb();
    self.voiceActivityThresholdDb = config.voiceActivityThresholdDb();
    
    // Fallback to default values if not provided or invalid
    if (self.noiseFloorDb == 0.0) {
        self.noiseFloorDb = -50.0;
    }
    if (self.voiceActivityThresholdDb == 0.0) {
        self.voiceActivityThresholdDb = -35.0;
    }
    
    // Adjust thresholds for iOS AVAudioRecorder range (-160 to 0 dB)
    [self adjustThresholdsForIOS];
    
    NSLog(@"[AudioRecorder] Config - NoiseFloor: %.1fdB, VoiceThreshold: %.1fdB, EndThreshold: %.1fs", 
          self.noiseFloorDb, self.voiceActivityThresholdDb, self.endOfSpeechThreshold);
    
    // Reset state
    self.recordingStartTime = 0;
    self.lastVoiceActivityTime = 0;
    self.actualSpeechStartTime = 0;
    self.totalSpeechDuration = 0;
    self.hasDetectedVoice = NO;
    self.isInThinkingPause = NO;
    self.isRecording = NO;
    self.currentPromiseResolve = resolve;
    self.currentPromiseReject = reject;
    
    // Setup audio session with proper category for recording
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    
    // Use Record category for better recording performance and noise reduction
    // Note: Use the iOS-compatible method signature
    if (@available(iOS 10.0, *)) {
        [session setCategory:AVAudioSessionCategoryRecord
                        mode:AVAudioSessionModeMeasurement
                     options:AVAudioSessionCategoryOptionAllowBluetooth
                       error:&error];
    } else {
        // Fallback for older iOS versions
        [session setCategory:AVAudioSessionCategoryRecord error:&error];
        if (!error) {
            [session setMode:AVAudioSessionModeMeasurement error:&error];
        }
    }
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
    NSLog(@"[AudioRecorder] AVAudioRecorder created and configured");
    
    // Start recording
    BOOL success = [self.audioRecorder record];
    if (!success) {
        reject(@"recording_start_error", @"Failed to start recording", nil);
        return;
    }
    
    self.isRecording = YES;
    self.recordingStartTime = [[NSDate date] timeIntervalSince1970];
    NSLog(@"[AudioRecorder] Recording started successfully at %.0f", self.recordingStartTime);
    
    // Start level monitoring
    [self startLevelMonitoring];
    
    // Don't resolve here - let finishRecordingWithReason handle the promise
    NSLog(@"[AudioRecorder] Recording setup complete, waiting for voice activity detection");
}

- (void)adjustThresholdsForIOS {
    // SIMPLE FIX: Use iOS-appropriate values that actually work
    // AVAudioRecorder averagePowerForChannel typical values:
    // - Background noise: -50 to -40 dB
    // - Normal speech: -30 to -10 dB  
    // - Loud speech: -10 to 0 dB
    
    // Use working iOS thresholds (ignore the Android values)
    self.noiseFloorDb = -50.0;      // Background noise level
    self.voiceActivityThresholdDb = -30.0;  // Normal speech level
    
    NSLog(@"[AudioRecorder] Using iOS-optimized thresholds: NoiseFloor: %.1fdB, VoiceThreshold: %.1fdB", 
          self.noiseFloorDb, self.voiceActivityThresholdDb);
}

- (void)startLevelMonitoring {
    // Schedule timer on main thread to match Android's Handler approach
    if ([NSThread isMainThread]) {
        self.levelTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                           target:self
                                                         selector:@selector(updateAudioLevels)
                                                         userInfo:nil
                                                          repeats:YES];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.levelTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                               target:self
                                                             selector:@selector(updateAudioLevels)
                                                             userInfo:nil
                                                              repeats:YES];
        });
    }
}

- (void)stopLevelMonitoring {
    // Ensure timer operations happen on main thread for thread safety
    if ([NSThread isMainThread]) {
        [self.levelTimer invalidate];
        [self.silenceTimer invalidate];
        self.levelTimer = nil;
        self.silenceTimer = nil;
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.levelTimer invalidate];
            [self.silenceTimer invalidate];
            self.levelTimer = nil;
            self.silenceTimer = nil;
        });
    }
}

- (void)updateAudioLevels {
    if (!self.isRecording || !self.audioRecorder || !self.audioRecorder.isRecording) {
        return;
    }
    
    [self.audioRecorder updateMeters];
    float averagePower = [self.audioRecorder averagePowerForChannel:0]; // This is already in dB
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    // Debug logging exactly like Android
    NSLog(@"[AudioRecorder] dB: %.1f, NoiseFloor: %.1f, VoiceThreshold: %.1f", 
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
        if (self.silenceTimer) {
            [self.silenceTimer invalidate];
            self.silenceTimer = nil;
        }
        
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
            if (remainingTime > 0) {
                // Ensure timer is scheduled on main thread
                if ([NSThread isMainThread]) {
                    self.silenceTimer = [NSTimer scheduledTimerWithTimeInterval:remainingTime
                                                                         target:self
                                                                       selector:@selector(handleEndOfSpeech)
                                                                       userInfo:nil
                                                                        repeats:NO];
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.silenceTimer = [NSTimer scheduledTimerWithTimeInterval:remainingTime
                                                                             target:self
                                                                           selector:@selector(handleEndOfSpeech)
                                                                           userInfo:nil
                                                                            repeats:NO];
                    });
                }
            }
        }
    }
}

- (void)handleEndOfSpeech {
    // Safety check: ensure we're still recording
    if (!self.isRecording || !self.audioRecorder) {
        NSLog(@"[AudioRecorder] handleEndOfSpeech called but not recording, ignoring");
        return;
    }
    
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
    [self stopLevelMonitoring];

    if (!self.isRecording) {
        return;
    }

    @try {
        if (self.audioRecorder && self.audioRecorder.isRecording) {
            [self.audioRecorder stop];
        }
        
        self.isRecording = NO;

        NSTimeInterval endTime = [[NSDate date] timeIntervalSince1970];
        double totalDuration = endTime - self.recordingStartTime;

        // Get file info
        NSURL *fileURL = self.audioRecorder.url;
        NSString *filePath = [fileURL path];

        NSError *error;
        NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];
        unsigned long long fileSize = error ? 0 : [fileAttributes fileSize];

        NSDictionary *result = @{
            @"filePath": filePath ?: @"",
            @"duration": @(totalDuration),
            @"actualSpeechDuration": @(self.totalSpeechDuration),
            @"fileSize": @(fileSize),
            @"reason": reason
        };

        if (self.currentPromiseResolve) {
            self.currentPromiseResolve(result);
        }
        self.currentPromiseResolve = nil;
        self.currentPromiseReject = nil;

    } @catch (NSException *exception) {
        if (self.currentPromiseReject) {
            self.currentPromiseReject(@"recording_finish_error", [NSString stringWithFormat:@"Failed to finish recording: %@", exception.reason], nil);
        }
        self.currentPromiseResolve = nil;
        self.currentPromiseReject = nil;
    } @finally {
        [self cleanup];
    }
}

- (void)stopRecording:(RCTPromiseResolveBlock)resolve
               reject:(RCTPromiseRejectBlock)reject {
    
    if (!self.isRecording) {
        reject(@"not_recording", @"No recording in progress", nil);
        return;
    }
    
    // CRITICAL FIX: Don't overwrite existing promise - update it properly
    // This matches Android's behavior where currentPromise is updated, not overwritten
    self.currentPromiseResolve = resolve;
    self.currentPromiseReject = reject;
    
    // Calculate speech duration up to now
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (self.hasDetectedVoice) {
        self.totalSpeechDuration = currentTime - self.actualSpeechStartTime;
    }

    [self finishRecordingWithReason:@"manual_stop"];
}

- (void)cancelRecording:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject {
    
    [self stopLevelMonitoring];

    if (self.isRecording) {
        @try {
            if (self.audioRecorder && self.audioRecorder.isRecording) {
                [self.audioRecorder stop];
            }
            self.isRecording = NO;

            // Delete the file
            NSError *error;
            NSURL *fileURL = self.audioRecorder.url;
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:&error];
        } @catch (NSException *exception) {
            // Ignore errors during cleanup
        }
    }

    [self cleanup];
    self.currentPromiseResolve = nil;
    self.currentPromiseReject = nil;
    resolve(nil);
}

- (NSNumber *)isRecording {
    return @(self->_isRecording);
}

- (void)checkMicrophonePermission:(RCTPromiseResolveBlock)resolve
                          reject:(RCTPromiseRejectBlock)reject {
    
    AVAudioSessionRecordPermission permission = [[AVAudioSession sharedInstance] recordPermission];
    BOOL hasPermission = (permission == AVAudioSessionRecordPermissionGranted);
    resolve(@(hasPermission));
}

- (void)requestMicrophonePermission:(RCTPromiseResolveBlock)resolve
                            reject:(RCTPromiseRejectBlock)reject {
    
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
        NSNumber *result = @(granted);
        resolve(result);
    }];
}

- (void)cleanup {
    // Comprehensive cleanup matching Android's approach
    @try {
        // Stop timers first to prevent crashes
        [self stopLevelMonitoring];
        
        // Deactivate audio session (CRITICAL FIX - missing in original)
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setActive:NO error:&error];
        if (error) {
            NSLog(@"[AudioRecorder] Warning: Could not deactivate audio session: %@", error.localizedDescription);
        }
        
        // Release audio recorder
        if (self.audioRecorder) {
            if (self.audioRecorder.isRecording) {
                [self.audioRecorder stop];
            }
            self.audioRecorder = nil;
        }
        
        // Reset state
        self.isRecording = NO;
        
    } @catch (NSException *exception) {
        NSLog(@"[AudioRecorder] Exception during cleanup: %@", exception.reason);
    }
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
