//
//  AudioSimpleSession.m
//

#import "AudioSimpleSession.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

// NSUserDefaults keys — kept identical to the audiofocus R21 layout so a
// build that upgrades from audiofocus@1.8.0 to audio-simple@0.3.0 carries
// the visitor's resume snapshot across the plugin migration.
static NSString* const kResumeKeyStepId    = @"flanerie_resume_stepId";
static NSString* const kResumeKeySeekPos   = @"flanerie_resume_seekPosSec";
static NSString* const kResumeKeyPID       = @"flanerie_resume_pID";
static NSString* const kResumeKeySavedAt   = @"flanerie_resume_savedAtMs";

@interface AudioSimpleSession ()
@property (nonatomic, assign) BOOL sessionActive;
@property (nonatomic, assign) BOOL nowPlayingActive;
@end

@implementation AudioSimpleSession

+ (instancetype) sharedSession {
    static AudioSimpleSession* instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[AudioSimpleSession alloc] init]; });
    return instance;
}

#pragma mark - AVAudioSession lifecycle

- (BOOL) activate:(NSError**)error {
    AVAudioSession* session = [AVAudioSession sharedInstance];

    NSError* setCatErr = nil;
    [session setCategory:AVAudioSessionCategoryPlayback error:&setCatErr];
    if (setCatErr) {
        if (error) *error = setCatErr;
        NSLog(@"[AudioSimpleSession] setCategory failed: %@", setCatErr.localizedDescription);
        return NO;
    }

    NSError* setActiveErr = nil;
    [session setActive:YES error:&setActiveErr];
    if (setActiveErr) {
        if (error) *error = setActiveErr;
        NSLog(@"[AudioSimpleSession] setActive:YES failed: %@", setActiveErr.localizedDescription);
        return NO;
    }

    self.sessionActive = YES;
    return YES;
}

- (BOOL) deactivateNotifyOthers:(BOOL)notifyOthers error:(NSError**)error {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    AVAudioSessionSetActiveOptions options = notifyOthers ? AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation : 0;
    NSError* err = nil;
    [session setActive:NO withOptions:options error:&err];
    self.sessionActive = NO;
    if (err) {
        if (error) *error = err;
        NSLog(@"[AudioSimpleSession] setActive:NO failed: %@", err.localizedDescription);
        return NO;
    }
    return YES;
}

- (BOOL) reset:(NSError**)error {
    NSError* deactErr = nil;
    [self deactivateNotifyOthers:NO error:&deactErr];
    // Brief settle delay — mirrors the audiofocus Round 22 path that the field
    // tests proved fixes the "fail once stay poisoned" AVAudioSession state.
    [NSThread sleepForTimeInterval:0.1];
    return [self activate:error];
}

- (BOOL) isActive {
    return self.sessionActive;
}

#pragma mark - MPNowPlayingInfoCenter + MPRemoteCommandCenter

- (void) setupNowPlaying:(NSDictionary*)options {
    if (![options isKindOfClass:[NSDictionary class]]) options = @{};
    NSString* title      = options[@"title"]      ?: @"Flânerie";
    NSString* artist     = options[@"artist"]     ?: @"";
    NSString* albumTitle = options[@"albumTitle"] ?: @"";

    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary* info = [NSMutableDictionary dictionary];
        info[MPMediaItemPropertyTitle] = title;
        if (artist.length     > 0) info[MPMediaItemPropertyArtist]     = artist;
        if (albumTitle.length > 0) info[MPMediaItemPropertyAlbumTitle] = albumTitle;
        info[MPNowPlayingInfoPropertyPlaybackRate] = @(1.0);
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;

        if (self.nowPlayingActive) {
            NSLog(@"[AudioSimpleSession] NowPlaying refreshed (commands already locked)");
            return;
        }

        MPRemoteCommandCenter* cc = [MPRemoteCommandCenter sharedCommandCenter];

        cc.playCommand.enabled                       = NO;
        cc.pauseCommand.enabled                      = NO;
        cc.togglePlayPauseCommand.enabled            = NO;
        cc.stopCommand.enabled                       = NO;
        cc.nextTrackCommand.enabled                  = NO;
        cc.previousTrackCommand.enabled              = NO;
        cc.skipForwardCommand.enabled                = NO;
        cc.skipBackwardCommand.enabled               = NO;
        cc.seekForwardCommand.enabled                = NO;
        cc.seekBackwardCommand.enabled               = NO;
        cc.changePlaybackPositionCommand.enabled     = NO;
        cc.changePlaybackRateCommand.enabled         = NO;
        cc.changeRepeatModeCommand.enabled           = NO;
        cc.changeShuffleModeCommand.enabled          = NO;
        cc.ratingCommand.enabled                     = NO;
        cc.likeCommand.enabled                       = NO;
        cc.dislikeCommand.enabled                    = NO;
        cc.bookmarkCommand.enabled                   = NO;

        MPRemoteCommandHandlerStatus (^noop)(MPRemoteCommandEvent*) = ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent* _) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        };
        [cc.playCommand                   addTargetWithHandler:noop];
        [cc.pauseCommand                  addTargetWithHandler:noop];
        [cc.togglePlayPauseCommand        addTargetWithHandler:noop];
        [cc.stopCommand                   addTargetWithHandler:noop];
        [cc.nextTrackCommand              addTargetWithHandler:noop];
        [cc.previousTrackCommand          addTargetWithHandler:noop];
        [cc.skipForwardCommand            addTargetWithHandler:noop];
        [cc.skipBackwardCommand           addTargetWithHandler:noop];
        [cc.seekForwardCommand            addTargetWithHandler:noop];
        [cc.seekBackwardCommand           addTargetWithHandler:noop];
        [cc.changePlaybackPositionCommand addTargetWithHandler:noop];
        [cc.changePlaybackRateCommand     addTargetWithHandler:noop];

        self.nowPlayingActive = YES;
        NSLog(@"[AudioSimpleSession] NowPlaying setup: title=%@ commands all disabled", title);
    });
}

- (void) clearNowPlaying {
    dispatch_async(dispatch_get_main_queue(), ^{
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
        if (!self.nowPlayingActive) return;

        MPRemoteCommandCenter* cc = [MPRemoteCommandCenter sharedCommandCenter];
        [cc.playCommand                   removeTarget:nil];
        [cc.pauseCommand                  removeTarget:nil];
        [cc.togglePlayPauseCommand        removeTarget:nil];
        [cc.stopCommand                   removeTarget:nil];
        [cc.nextTrackCommand              removeTarget:nil];
        [cc.previousTrackCommand          removeTarget:nil];
        [cc.skipForwardCommand            removeTarget:nil];
        [cc.skipBackwardCommand           removeTarget:nil];
        [cc.seekForwardCommand            removeTarget:nil];
        [cc.seekBackwardCommand           removeTarget:nil];
        [cc.changePlaybackPositionCommand removeTarget:nil];
        [cc.changePlaybackRateCommand     removeTarget:nil];
        self.nowPlayingActive = NO;
        NSLog(@"[AudioSimpleSession] NowPlaying cleared");
    });
}

#pragma mark - NSUserDefaults step-state cache

- (void) setResumeSnapshot:(NSDictionary*)snapshot {
    if (![snapshot isKindOfClass:[NSDictionary class]]) return;

    NSNumber* stepId  = snapshot[@"stepId"];
    NSNumber* seekPos = snapshot[@"seekPosSec"];
    NSString* pID     = snapshot[@"pID"];

    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([stepId  isKindOfClass:[NSNumber class]]) [defaults setObject:stepId  forKey:kResumeKeyStepId];
    if ([seekPos isKindOfClass:[NSNumber class]]) [defaults setObject:seekPos forKey:kResumeKeySeekPos];
    if ([pID     isKindOfClass:[NSString class]]) [defaults setObject:pID     forKey:kResumeKeyPID];
    NSNumber* savedAt = @((long long)([[NSDate date] timeIntervalSince1970] * 1000.0));
    [defaults setObject:savedAt forKey:kResumeKeySavedAt];
}

- (NSDictionary*) getResumeSnapshot {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSNumber* stepId  = [defaults objectForKey:kResumeKeyStepId];
    NSNumber* seekPos = [defaults objectForKey:kResumeKeySeekPos];
    NSString* pID     = [defaults objectForKey:kResumeKeyPID];
    NSNumber* savedAt = [defaults objectForKey:kResumeKeySavedAt];

    BOOL found = (stepId != nil && seekPos != nil && savedAt != nil);
    double ageMs = -1;
    if (found) {
        ageMs = ([[NSDate date] timeIntervalSince1970] * 1000.0) - [savedAt doubleValue];
    }

    return @{
        @"found":      @(found),
        @"stepId":     stepId  ?: [NSNull null],
        @"seekPosSec": seekPos ?: [NSNull null],
        @"pID":        pID     ?: [NSNull null],
        @"savedAtMs":  savedAt ?: [NSNull null],
        @"ageMs":      @(ageMs),
    };
}

- (void) clearResumeSnapshot {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kResumeKeyStepId];
    [defaults removeObjectForKey:kResumeKeySeekPos];
    [defaults removeObjectForKey:kResumeKeyPID];
    [defaults removeObjectForKey:kResumeKeySavedAt];
}

#pragma mark - state snapshot

- (NSDictionary*) snapshotState {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    NSString* portType = (session.currentRoute.outputs.count > 0)
        ? session.currentRoute.outputs[0].portType : @"";
    NSString* portName = (session.currentRoute.outputs.count > 0)
        ? session.currentRoute.outputs[0].portName : @"";

    return @{
        @"outputVolume":                  @(session.outputVolume),
        @"currentPort":                   portType,
        @"currentPortName":               portName,
        @"currentCategory":               session.category ?: @"",
        @"secondaryAudioShouldBeSilenced": @(session.secondaryAudioShouldBeSilencedHint),
        @"sessionActive":                 @(self.sessionActive),
        @"nowPlayingActive":              @(self.nowPlayingActive),
    };
}

@end
