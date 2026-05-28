//
//  AudioSimplePlayer.m
//

#import "AudioSimplePlayer.h"
#import "AudioSimpleSession.h"

@interface AudioSimplePlayer ()
@property (nonatomic, assign) NSInteger handle;
@property (nonatomic, copy)   NSString* src;
@property (nonatomic, assign) BOOL loop;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) float volume;
@property (nonatomic, strong, nullable) AVAudioPlayer* avPlayer;
@property (nonatomic, strong, nullable) NSTimer* fadeTimer;
@property (nonatomic, assign) float fadeStart;
@property (nonatomic, assign) float fadeEnd;
@property (nonatomic, assign) NSInteger fadeStep;
@property (nonatomic, assign) NSInteger fadeTotalSteps;
@property (nonatomic, assign) BOOL unloaded;
@end

@implementation AudioSimplePlayer

- (instancetype) initWithHandle:(NSInteger)handle
                            src:(NSString*)src
                           loop:(BOOL)loop
                         volume:(float)volume
{
    self = [super init];
    if (self) {
        _handle  = handle;
        _src     = [src copy];
        _loop    = loop;
        _volume  = MAX(0.0f, MIN(1.0f, volume));
        _loaded  = NO;
        _loading = NO;
        _playing = NO;
    }
    return self;
}

#pragma mark - URI resolution

// Resolve cordova:// / http://localhost / file:// / plain paths to an NSURL
// AVAudioPlayer can consume. The webapp already prefers httpToNativePath()
// on iOS (cordova.file.applicationDirectory + relative path → file://) so by
// the time we get here, src is almost always a file:// URL — but accept the
// other forms defensively.
- (NSURL*) resolveURL {
    if (self.src.length == 0) return nil;

    if ([self.src hasPrefix:@"file://"]) {
        return [NSURL URLWithString:self.src];
    }
    if ([self.src hasPrefix:@"http://"] || [self.src hasPrefix:@"https://"]) {
        // AVAudioPlayer doesn't support streaming. webapp should have already
        // converted to file://; emit loaderror for diagnostics.
        return nil;
    }
    if ([self.src hasPrefix:@"/"]) {
        return [NSURL fileURLWithPath:self.src];
    }
    // Treat as bundle-relative path
    NSString* p = [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent:self.src];
    return [NSURL fileURLWithPath:p];
}

#pragma mark - lifecycle

- (void) load {
    if (self.unloaded) return;
    if (self.loaded || self.loading) return;
    self.loading = YES;

    NSURL* url = [self resolveURL];
    if (url == nil) {
        self.loading = NO;
        [self emit:@"loaderror" payload:@{@"error": @"unresolvable_src"}];
        return;
    }

    // AVAudioPlayer initWithContentsOfURL is synchronous; on success the
    // file is parsed and the player is ready to prepareToPlay.
    NSError* err = nil;
    AVAudioPlayer* p = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
    if (p == nil || err != nil) {
        self.loading = NO;
        [self emit:@"loaderror" payload:@{@"error": err.localizedDescription ?: @"avaudioplayer_init_failed"}];
        return;
    }

    p.delegate = self;
    p.volume = self.volume;
    p.numberOfLoops = self.loop ? -1 : 0;  // -1 = infinite; matches cordova-plugin-media (P3.4)
    [p prepareToPlay];

    self.avPlayer = p;
    self.loaded = YES;
    self.loading = NO;
    [self emit:@"load" payload:nil];
}

- (void) prewarm {
    if (self.unloaded) return;
    if (self.loaded) {
        [self.avPlayer prepareToPlay];
        return;
    }
    [self load];
}

- (void) play {
    if (self.unloaded) return;

    // Lazy-load if play() was called before load() — Howler shape allows this.
    if (!self.loaded && !self.loading) {
        [self load];
    }
    if (!self.loaded) {
        // load() emitted loaderror; do not flip to playing
        return;
    }

    // Ensure the AVAudioSession is active before pressing play. The session
    // singleton is owned here; activate is idempotent.
    NSError* sessErr = nil;
    if (![[AudioSimpleSession sharedSession] activate:&sessErr]) {
        [self emit:@"playerror" payload:@{@"error": sessErr.localizedDescription ?: @"session_activate_failed"}];
        return;
    }

    BOOL ok = [self.avPlayer play];
    if (!ok) {
        [self emit:@"playerror" payload:@{@"error": @"avaudioplayer_play_returned_false"}];
        return;
    }
    self.playing = YES;
    [self emit:@"play" payload:nil];
}

- (void) pause {
    if (self.unloaded || self.avPlayer == nil) return;
    if (!self.playing) return;
    [self.avPlayer pause];
    self.playing = NO;
    [self emit:@"pause" payload:nil];
}

- (void) stop {
    if (self.unloaded || self.avPlayer == nil) return;
    [self.avPlayer stop];
    self.avPlayer.currentTime = 0;
    self.playing = NO;
    [self emit:@"stop" payload:nil];
}

- (void) seekTo:(NSTimeInterval)seconds {
    if (self.unloaded || self.avPlayer == nil) return;
    if (seconds < 0) seconds = 0;
    self.avPlayer.currentTime = seconds;
}

- (NSTimeInterval) currentPosition {
    if (self.unloaded || self.avPlayer == nil) return 0;
    return self.avPlayer.currentTime;
}

- (void) setVolume:(float)volume {
    [self stopFade];
    _volume = MAX(0.0f, MIN(1.0f, volume));
    if (self.avPlayer) self.avPlayer.volume = _volume;
}

#pragma mark - fade

- (void) fadeFrom:(float)from to:(float)to durationMs:(NSInteger)ms {
    if (self.unloaded || self.avPlayer == nil) return;
    [self stopFade];

    from = MAX(0.0f, MIN(1.0f, from));
    to   = MAX(0.0f, MIN(1.0f, to));
    _volume = to;
    self.avPlayer.volume = from;

    if (ms <= 0) {
        self.avPlayer.volume = to;
        return;
    }

    // ~50 fps ramp. Mirrors NativeMediaPlayer.fade() that we are replacing.
    self.fadeStart = from;
    self.fadeEnd = to;
    self.fadeStep = 0;
    self.fadeTotalSteps = MAX(1, (NSInteger)(ms / 20));
    NSTimeInterval interval = (NSTimeInterval)ms / (NSTimeInterval)self.fadeTotalSteps / 1000.0;

    self.fadeTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                      target:self
                                                    selector:@selector(_fadeTick)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void) _fadeTick {
    if (self.unloaded || self.avPlayer == nil) {
        [self stopFade];
        return;
    }
    self.fadeStep++;
    if (self.fadeStep >= self.fadeTotalSteps) {
        self.avPlayer.volume = self.fadeEnd;
        [self stopFade];
        return;
    }
    float t = (float)self.fadeStep / (float)self.fadeTotalSteps;
    self.avPlayer.volume = self.fadeStart + (self.fadeEnd - self.fadeStart) * t;
}

- (void) stopFade {
    if (self.fadeTimer) {
        [self.fadeTimer invalidate];
        self.fadeTimer = nil;
    }
}

#pragma mark - loop / unload

- (void) setLoopFlag:(BOOL)loop {
    _loop = loop;
    if (self.avPlayer) self.avPlayer.numberOfLoops = loop ? -1 : 0;
}

- (void) unload {
    if (self.unloaded) return;
    self.unloaded = YES;
    [self stopFade];
    if (self.avPlayer) {
        [self.avPlayer stop];
        self.avPlayer.delegate = nil;
        self.avPlayer = nil;
    }
    self.loaded = NO;
    self.loading = NO;
    self.playing = NO;
}

#pragma mark - AVAudioPlayerDelegate

- (void) audioPlayerDidFinishPlaying:(AVAudioPlayer*)player successfully:(BOOL)flag {
    if (self.unloaded || player != self.avPlayer) return;
    self.playing = NO;
    if (flag) {
        [self emit:@"end" payload:nil];
    } else {
        [self emit:@"playerror" payload:@{@"error": @"didFinishPlaying_not_successful"}];
    }
}

- (void) audioPlayerDecodeErrorDidOccur:(AVAudioPlayer*)player error:(NSError*)error {
    if (self.unloaded || player != self.avPlayer) return;
    self.playing = NO;
    [self emit:@"playerror" payload:@{@"error": error.localizedDescription ?: @"decode_error"}];
}

#pragma mark - emit helper

- (void) emit:(NSString*)event payload:(NSDictionary*)payload {
    id<AudioSimplePlayerDelegate> d = self.delegate;
    if (d) [d player:self emitEvent:event payload:payload];
}

@end
