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
@property (nonatomic) BOOL recordingActive;
@property (nonatomic, strong) RCTPromiseResolveBlock currentPromiseResolve;
@property (nonatomic, strong) RCTPromiseRejectBlock currentPromiseReject;
@end

@implementation AudioRecorder
RCT_EXPORT_MODULE()

- (void)startRecording:(JS::NativeAudioRecorder::RecordingConfig &)config
               resolve:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject {
    
    if (self.recordingActive) {
        reject(@"recording_in_progress", @"Recording is already in progress", nil);
        return;
    }
    
    self.thinkingPauseThreshold = config.thinkingPauseThreshold();
    self.endOfSpeechThreshold = config.endOfSpeechThreshold();
    self.maxDurationSeconds = config.maxDurationSeconds();
    self.minRecordingDurationMs = config.minRecordingDurationMs();
    
    self.noiseFloorDb = config.noiseFloorDb();
    self.voiceActivityThresholdDb = config.voiceActivityThresholdDb();
    
    if (self.noiseFloorDb == 0.0) {
        self.noiseFloorDb = -50.0;
    }
    if (self.voiceActivityThresholdDb == 0.0) {
        self.voiceActivityThresholdDb = -35.0;
    }
    self.recordingStartTime = 0;
    self.lastVoiceActivityTime = 0;
    self.actualSpeechStartTime = 0;
    self.totalSpeechDuration = 0;
    self.hasDetectedVoice = NO;
    self.isInThinkingPause = NO;
    self.recordingActive = NO;
    self.currentPromiseResolve = resolve;
    self.currentPromiseReject = reject;
    
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if (@available(iOS 10.0, *)) {
        [session setCategory:AVAudioSessionCategoryRecord
                        mode:AVAudioSessionModeMeasurement
                     options:AVAudioSessionCategoryOptionAllowBluetooth
                       error:&error];
    } else {
        [session setCategory:AVAudioSessionCategoryRecord error:&error];
        if (!error) {
            [session setMode:AVAudioSessionModeMeasurement error:&error];
        }
    }
    if (error) {
        reject(@"audio_session_error", @"Failed to setup audio session", error);
        return;
    }
    
    [session setPreferredSampleRate:config.sampleRate() error:&error];
    if (error) {
    }
    
    [session setPreferredIOBufferDuration:0.01 error:&error];
    if (error) {
    }
    
    [session setActive:YES error:&error];
    if (error) {
        reject(@"audio_session_error", @"Failed to activate audio session", error);
        return;
    }
    
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
    
    NSMutableDictionary *settings = [[NSMutableDictionary alloc] init];
    NSString *actualFormat = config.format();
    if ([config.format() isEqualToString:@"mp3"]) {
        actualFormat = @"m4a";
        settings[AVFormatIDKey] = @(kAudioFormatMPEG4AAC);
    } else if ([config.format() isEqualToString:@"aac"]) {
        settings[AVFormatIDKey] = @(kAudioFormatMPEG4AAC);
    } else if ([config.format() isEqualToString:@"wav"]) {
        settings[AVFormatIDKey] = @(kAudioFormatLinearPCM);
        settings[AVLinearPCMBitDepthKey] = @(16);
        settings[AVLinearPCMIsBigEndianKey] = @(NO);
        settings[AVLinearPCMIsFloatKey] = @(NO);
    } else {
        actualFormat = @"aac";
        settings[AVFormatIDKey] = @(kAudioFormatMPEG4AAC);
    }
    
    settings[AVSampleRateKey] = @(config.sampleRate());
    settings[AVNumberOfChannelsKey] = @(config.channels());
    settings[AVEncoderBitRateKey] = @(config.bitRate());
    settings[AVEncoderAudioQualityKey] = @(AVAudioQualityHigh);
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *fileName = [NSString stringWithFormat:@"recording_%f.%@", [[NSDate date] timeIntervalSince1970], actualFormat];
    NSURL *outputFileURL = [NSURL fileURLWithPath:[documentsDirectory stringByAppendingPathComponent:fileName]];
    
    
    self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:outputFileURL settings:settings error:&error];
    if (error) {
        reject(@"recorder_creation_error", @"Failed to create audio recorder", error);
        return;
    }
    
    self.audioRecorder.delegate = self;
    self.audioRecorder.meteringEnabled = YES;
    
    BOOL success = [self.audioRecorder record];
    if (!success) {
        reject(@"recording_start_error", @"Failed to start recording", nil);
        return;
    }
    
    self.recordingActive = YES;
    self.recordingStartTime = [[NSDate date] timeIntervalSince1970];
    
    
    [self startLevelMonitoring];
    
    
}

- (void)adjustThresholdsForIOS {
}

- (void)startLevelMonitoring {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.levelTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                           target:self
                                                         selector:@selector(updateAudioLevels)
                                                         userInfo:nil
                                                          repeats:YES];
    });
}

- (void)stopLevelMonitoring {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.levelTimer invalidate];
        [self.silenceTimer invalidate];
        self.levelTimer = nil;
        self.silenceTimer = nil;
    });
}

- (void)updateAudioLevels {
    if (!self.recordingActive || !self.audioRecorder || !self.audioRecorder.isRecording) {
        return;
    }
    
    [self.audioRecorder updateMeters];
    float averagePower = [self.audioRecorder averagePowerForChannel:0];
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    
    if (currentTime - self.recordingStartTime >= self.maxDurationSeconds) {
        [self finishRecordingWithReason:@"max_duration_reached"];
        return;
    }
    
    [self processVoiceActivity:averagePower currentTime:currentTime];
}

- (void)processVoiceActivity:(float)dbLevel currentTime:(NSTimeInterval)currentTime {
    BOOL isVoice = (dbLevel > self.noiseFloorDb) && (dbLevel > self.voiceActivityThresholdDb);
    
    
    if (isVoice) {
        if (!self.hasDetectedVoice) {
            self.hasDetectedVoice = YES;
            self.actualSpeechStartTime = currentTime;
        }
        
        self.lastVoiceActivityTime = currentTime;
        self.isInThinkingPause = NO;
        
        if (self.silenceTimer) {
            [self.silenceTimer invalidate];
            self.silenceTimer = nil;
        }
        
    } else if (self.hasDetectedVoice) {
        NSTimeInterval silenceDuration = currentTime - self.lastVoiceActivityTime;
        
        
        if (silenceDuration >= self.thinkingPauseThreshold && !self.isInThinkingPause) {
            self.isInThinkingPause = YES;
            
            NSTimeInterval remainingTime = self.endOfSpeechThreshold - self.thinkingPauseThreshold;
            if (remainingTime > 0) {
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
    if (!self.recordingActive || !self.audioRecorder) {
        return;
    }
    
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval totalSilence = currentTime - self.lastVoiceActivityTime;
    NSTimeInterval totalRecordingDuration = (currentTime - self.recordingStartTime) * 1000;
    
    if (totalSilence >= self.endOfSpeechThreshold) {
        self.totalSpeechDuration = self.lastVoiceActivityTime - self.actualSpeechStartTime;
        
        if (totalRecordingDuration >= self.minRecordingDurationMs) {
            [self finishRecordingWithReason:@"silence_detected"];
        }
    }
}

- (void)finishRecordingWithReason:(NSString *)reason {
    [self stopLevelMonitoring];

    if (!self.recordingActive) {
        return;
    }

    @try {
        if (self.audioRecorder && self.audioRecorder.isRecording) {
            [self.audioRecorder stop];
        }
        
        self.recordingActive = NO;

        NSTimeInterval endTime = [[NSDate date] timeIntervalSince1970];
        double totalDuration = endTime - self.recordingStartTime;

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
    
    if (!self.recordingActive) {
        reject(@"not_recording", @"No recording in progress", nil);
        return;
    }
    
    self.currentPromiseResolve = resolve;
    self.currentPromiseReject = reject;
    
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (self.hasDetectedVoice) {
        self.totalSpeechDuration = currentTime - self.actualSpeechStartTime;
    }

    [self finishRecordingWithReason:@"manual_stop"];
}

- (void)cancelRecording:(RCTPromiseResolveBlock)resolve
                 reject:(RCTPromiseRejectBlock)reject {
    
    [self stopLevelMonitoring];

    if (self.recordingActive) {
        @try {
            if (self.audioRecorder && self.audioRecorder.isRecording) {
                [self.audioRecorder stop];
            }
            self.recordingActive = NO;

            NSError *error;
            NSURL *fileURL = self.audioRecorder.url;
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:&error];
        } @catch (NSException *exception) {
        }
    }

    [self cleanup];
    self.currentPromiseResolve = nil;
    self.currentPromiseReject = nil;
    resolve(nil);
}

- (NSNumber *)isRecording {
    return @(self.recordingActive);
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
    @try {
        [self stopLevelMonitoring];
        
        NSError *error = nil;
        [[AVAudioSession sharedInstance] setActive:NO error:&error];
        if (error) {
        }
        
        if (self.audioRecorder) {
            if (self.audioRecorder.isRecording) {
                [self.audioRecorder stop];
            }
            self.audioRecorder = nil;
        }
        
        self.recordingActive = NO;
        
    } @catch (NSException *exception) {
    }
}

- (void)addListener:(NSString *)eventName {
}

- (void)removeListeners:(double)count {
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
