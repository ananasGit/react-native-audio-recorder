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
    
    // Reset state
    self.recordingStartTime = 0;
    self.lastVoiceActivityTime = 0;
    self.actualSpeechStartTime = 0;
    self.totalSpeechDuration = 0;
    self.hasDetectedVoice = NO;
    self.isInThinkingPause = NO;
    self.currentPromiseResolve = resolve;
    self.currentPromiseReject = reject;
    
    // Setup audio session
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    
    [session setCategory:AVAudioSessionCategoryPlayAndRecord 
                 options:AVAudioSessionCategoryOptionDefaultToSpeaker 
                   error:&error];
    if (error) {
        reject(@"audio_session_error", @"Failed to setup audio session", error);
        return;
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
    
    // Setup recording settings
    NSMutableDictionary *settings = [[NSMutableDictionary alloc] init];
    
    if ([config.format() isEqualToString:@"aac"]) {
        settings[AVFormatIDKey] = @(kAudioFormatMPEG4AAC);
    } else if ([config.format() isEqualToString:@"mp3"]) {
        settings[AVFormatIDKey] = @(kAudioFormatMPEGLayer3);
    } else {
        settings[AVFormatIDKey] = @(kAudioFormatLinearPCM);
    }
    
    settings[AVSampleRateKey] = @(config.sampleRate());
    settings[AVNumberOfChannelsKey] = @(config.channels());
    settings[AVEncoderBitRateKey] = @(config.bitRate());
    settings[AVEncoderAudioQualityKey] = @(AVAudioQualityHigh);
    
    // Create output file path
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *fileName = [NSString stringWithFormat:@"recording_%f.%@", [[NSDate date] timeIntervalSince1970], config.format()];
    NSURL *outputFileURL = [NSURL fileURLWithPath:[documentsDirectory stringByAppendingPathComponent:fileName]];
    
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
    
    // Start level monitoring
    [self startLevelMonitoring];
    
    // Don't resolve here - let finishRecordingWithReason handle the promise
    NSLog(@"Recording setup complete, waiting for voice activity detection");
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
    float averagePower = [self.audioRecorder averagePowerForChannel:0];
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    // Check if we've reached max duration
    if (currentTime - self.recordingStartTime >= self.maxDurationSeconds) {
        [self finishRecordingWithReason:@"max_duration_reached"];
        return;
    }
    
    // Voice activity detection
    if (averagePower > self.noiseFloorDb && averagePower > self.voiceActivityThresholdDb) {
        // Voice detected
        if (!self.hasDetectedVoice) {
            self.hasDetectedVoice = YES;
            self.actualSpeechStartTime = currentTime;
        }
        
        self.lastVoiceActivityTime = currentTime;
        self.isInThinkingPause = NO;
        
        // Cancel any pending silence timer
        [self.silenceTimer invalidate];
        self.silenceTimer = nil;
        
    } else if (self.hasDetectedVoice) {
        // Silence detected after voice
        NSTimeInterval silenceDuration = currentTime - self.lastVoiceActivityTime;
        
        if (silenceDuration >= self.thinkingPauseThreshold && !self.isInThinkingPause) {
            // Entered thinking pause
            self.isInThinkingPause = YES;
            
            // Schedule end-of-speech detection
            self.silenceTimer = [NSTimer scheduledTimerWithTimeInterval:self.endOfSpeechThreshold - self.thinkingPauseThreshold
                                                                 target:self
                                                               selector:@selector(handleEndOfSpeech)
                                                               userInfo:nil
                                                                repeats:NO];
        }
    }
}

- (void)handleEndOfSpeech {
    // Check if we still haven't detected voice after the end-of-speech threshold
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval totalSilence = currentTime - self.lastVoiceActivityTime;
    
    if (totalSilence >= self.endOfSpeechThreshold) {
        // Calculate actual speech duration (excluding final silence)
        self.totalSpeechDuration = self.lastVoiceActivityTime - self.actualSpeechStartTime;
        
        // Only finish if we have minimum recording duration
        if ((currentTime - self.recordingStartTime) * 1000 >= self.minRecordingDurationMs) {
            [self finishRecordingWithReason:@"silence_detected"];
        }
    }
}

- (void)finishRecordingWithReason:(NSString *)reason {
    [self.levelTimer invalidate];
    [self.silenceTimer invalidate];
    self.levelTimer = nil;
    self.silenceTimer = nil;
    
    if (!self.audioRecorder) {
        return;
    }
    
    [self.audioRecorder stop];
    
    NSTimeInterval endTime = [[NSDate date] timeIntervalSince1970];
    double totalDuration = endTime - self.recordingStartTime;
    
    // Get file info
    NSURL *fileURL = self.audioRecorder.url;
    NSString *filePath = [fileURL path];
    
    NSError *error;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:&error];
    unsigned long long fileSize = error ? 0 : [fileAttributes fileSize];
    
    // Ensure we have a valid file
    if (fileSize == 0 && !error) {
        error = [NSError errorWithDomain:@"AudioRecorderError" code:1001 userInfo:@{NSLocalizedDescriptionKey: @"Recording file is empty"}];
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
    
    if (!self.audioRecorder || !self.audioRecorder.isRecording) {
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
    }
    
    [self finishRecordingWithReason:@"manual_stop"];
}

- (void)cancelRecording:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject {
    
    [self.levelTimer invalidate];
    [self.silenceTimer invalidate];
    
    if (self.audioRecorder) {
        [self.audioRecorder stop];
        
        // Delete the file
        NSError *error;
        [[NSFileManager defaultManager] removeItemAtURL:self.audioRecorder.url error:&error];
        
        self.audioRecorder = nil;
    }
    
    self.currentPromiseResolve = nil;
    self.currentPromiseReject = nil;
    
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
