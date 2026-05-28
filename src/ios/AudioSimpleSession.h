//
//  AudioSimpleSession.h
//  cordova-plugin-audio-simple — iOS
//
//  Singleton owner of the app-wide AVAudioSession lifecycle. Replaces the
//  session ownership that cordova-plugin-audiofocus held pre-Round 25.
//  Coexists with audiofocus's interruption-observer-as-telemetry: this class
//  owns setActive/setCategory; audiofocus iOS only listens to interruption
//  notifications to emit AUDIOFOCUS_LOSS / AUDIOFOCUS_GAIN telemetry events.
//
//  Also exposes Now Playing (lock-screen tile) and a NSUserDefaults-backed
//  step-state cache that the webapp dual-writes with localStorage.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioSimpleSession : NSObject

+ (instancetype) sharedSession;

// AVAudioSession lifecycle. activate is idempotent — repeated calls just keep
// the session warm. deactivate notifies other apps so secondary audio can
// resume (used at parcours end / rearm).
- (BOOL) activate:(NSError**)error;
- (BOOL) deactivateNotifyOthers:(BOOL)notifyOthers error:(NSError**)error;

// Reset = deactivate then re-activate. Used by the A2 audio-engine-reset path
// to clear a "fail once stay poisoned" AVAudioSession state.
- (BOOL) reset:(NSError**)error;

- (BOOL) isActive;

// MPNowPlayingInfoCenter + MPRemoteCommandCenter (migrated from audiofocus
// Round 22). Title default "Flânerie" if options missing. All remote-command
// center commands explicitly disabled + no-op handlers — by design the walker
// cannot pause/skip from the lock screen.
- (void) setupNowPlaying:(NSDictionary*)options;
- (void) clearNowPlaying;

// NSUserDefaults step-state cache (migrated from audiofocus Round 21). Mirrors
// the localStorage parcours_store path so a WKWebView cache wipe doesn't lose
// visitor progress mid-walk.
- (void) setResumeSnapshot:(NSDictionary*)snapshot;
- (NSDictionary*) getResumeSnapshot;
- (void) clearResumeSnapshot;

// Read-only state probe — used by AudioSimplePlugin's getSessionState action
// for F-A2 telemetry parity with audiofocus's getAudioSessionState.
- (NSDictionary*) snapshotState;

@end

NS_ASSUME_NONNULL_END
