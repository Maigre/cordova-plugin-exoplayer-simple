//
//  AudioSimplePlayer.h
//  cordova-plugin-audio-simple — iOS
//
//  One AVAudioPlayer instance per JS-side handle. Mirrors the Howler-subset
//  API used by FlanerieAudioMap's PlayerSimple wrapper. Native fade timer
//  for sub-frame volume ramping; native infinite loop via numberOfLoops=-1
//  so voice→afterplay seams (P3.4 lessons from cordova-plugin-media migration)
//  carry over.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioSimplePlayer;

@protocol AudioSimplePlayerDelegate <NSObject>
// Fan-out for the long-lived event channel. `event` ∈ {load, play, pause,
// stop, end, loaderror, playerror}. Payload may carry an `error` string for
// the *error events.
- (void) player:(AudioSimplePlayer*)player emitEvent:(NSString*)event payload:(nullable NSDictionary*)payload;
@end

@interface AudioSimplePlayer : NSObject <AVAudioPlayerDelegate>

@property (nonatomic, readonly) NSInteger handle;
@property (nonatomic, readonly, copy) NSString* src;
@property (nonatomic, readonly) BOOL loop;
@property (nonatomic, readonly) BOOL loaded;
@property (nonatomic, readonly) BOOL loading;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, weak, nullable) id<AudioSimplePlayerDelegate> delegate;

- (instancetype) initWithHandle:(NSInteger)handle
                            src:(NSString*)src
                           loop:(BOOL)loop
                         volume:(float)volume;

// Load the file backing self.src. Resolves http://localhost:PORT/... URLs to
// file paths the same way the Android side does via UriResolver. Emits 'load'
// on success, 'loaderror' on failure.
- (void) load;

// Prepare without playWhenReady. Idempotent. Closes the iOS analogue of the
// M4 / P9 cold-load race — voice plays immediately when the GPS-triggered
// .play() arrives even on a fresh first walk.
- (void) prewarm;

- (void) play;
- (void) pause;
- (void) stop;
- (void) seekTo:(NSTimeInterval)seconds;
- (NSTimeInterval) currentPosition;
- (void) setVolume:(float)volume;
- (void) fadeFrom:(float)from to:(float)to durationMs:(NSInteger)ms;
- (void) setLoopFlag:(BOOL)loop;
- (void) unload;

@end

NS_ASSUME_NONNULL_END
