// Liland's window into the system's Now Playing, what Control Center shows for any app.
//
// Since macOS 15.4 only Apple's own programs may use the private MediaRemote framework,
// so Liland runs now-playing.pl with /usr/bin/perl, which loads this framework and calls
// one of the two functions below. Apple can close this way in any macOS update.
//
//   liland_stream   Prints one JSON line per change until terminated:
//                   {"state": {...}, "artwork": "<base64>" | null}
//                   "state" is {} when nothing plays; "artwork" is only there when it changed.
//   liland_command  Runs the command that follows "command" in the arguments:
//                   play, pause, nextTrack, previousTrack,
//                   seek SECONDS, shuffle MODE (1 off, 3 on), repeat MODE (1 off, 2 one, 3 all)
//
// Adapted from mediaremote-adapter by Jonas van den Berg and contributors
// (https://github.com/ungive/mediaremote-adapter, BSD 3-Clause, see LICENSE).

#import <AppKit/AppKit.h>

#define EXPORT __attribute__((visibility("default")))

#pragma mark - MediaRemote

typedef void (^InfoCompletion)(NSDictionary *information);
typedef void (^PIDCompletion)(int pid);
typedef void (^IsPlayingCompletion)(bool isPlaying);
typedef void (^ClientCompletion)(id client);

/// The private MRClient class that MediaRemote passes to `ClientCompletion`.
@protocol MRClient <NSObject>
- (NSString *)parentApplicationBundleIdentifier;
@end

static struct {
    void (*registerForNowPlayingNotifications)(dispatch_queue_t queue);
    void (*getNowPlayingInfo)(dispatch_queue_t queue, InfoCompletion completion);
    void (*getNowPlayingApplicationPID)(dispatch_queue_t queue, PIDCompletion completion);
    void (*getNowPlayingApplicationIsPlaying)(dispatch_queue_t queue, IsPlayingCompletion completion);
    void (*getNowPlayingClient)(dispatch_queue_t queue, ClientCompletion completion);
    bool (*sendCommand)(int command, id userInfo);
    void (*setElapsedTime)(double seconds);
    void (*setShuffleMode)(int mode);
    void (*setRepeatMode)(int mode);
} MR;

enum {
    MRPlay = 0,
    MRPause = 1,
    MRNextTrack = 4,
    MRPreviousTrack = 5,
};

static void fail(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String);
    exit(1);
}

static void loadMediaRemote(void) {
    NSURL *url = [NSURL fileURLWithPath:@"/System/Library/PrivateFrameworks/MediaRemote.framework"];
    CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)url);
    if (!bundle) fail(@"MediaRemote.framework not found");

#define LOAD(field, name)                                                   \
    MR.field = (__typeof__(MR.field))CFBundleGetFunctionPointerForName(bundle, CFSTR(name)); \
    if (!MR.field) fail(@"MediaRemote has no " name);

    LOAD(registerForNowPlayingNotifications, "MRMediaRemoteRegisterForNowPlayingNotifications")
    LOAD(getNowPlayingInfo, "MRMediaRemoteGetNowPlayingInfo")
    LOAD(getNowPlayingApplicationPID, "MRMediaRemoteGetNowPlayingApplicationPID")
    LOAD(getNowPlayingApplicationIsPlaying, "MRMediaRemoteGetNowPlayingApplicationIsPlaying")
    LOAD(getNowPlayingClient, "MRMediaRemoteGetNowPlayingClient")
    LOAD(sendCommand, "MRMediaRemoteSendCommand")
    LOAD(setElapsedTime, "MRMediaRemoteSetElapsedTime")
    LOAD(setShuffleMode, "MRMediaRemoteSetShuffleMode")
    LOAD(setRepeatMode, "MRMediaRemoteSetRepeatMode")
#undef LOAD
}

#pragma mark - Stream

static dispatch_queue_t queue;
/// Bumped on every refresh, so that a slow earlier refresh can't overwrite a newer one.
static uint64_t generation;
static BOOL refreshScheduled;
static NSDictionary *lastState;
static NSData *lastArtwork;

static void printLine(NSDictionary *line) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:line options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void copyValue(NSMutableDictionary *state, NSString *key, NSDictionary *info, NSString *infoKey, Class type) {
    id value = info[infoKey];
    if ([value isKindOfClass:type]) state[key] = value;
}

static BOOL isSameTrack(NSDictionary *a, NSDictionary *b) {
    for (NSString *key in @[ @"bundleIdentifier", @"title", @"artist", @"album" ]) {
        id x = a[key], y = b[key];
        if (x != y && ![x isEqual:y]) return NO;
    }
    return YES;
}

static void publish(int pid, BOOL playing, NSString *parentBundleIdentifier, NSDictionary *info) {
    NSString *bundleIdentifier = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    NSData *artwork = nil;

    // Media without a title or an app isn't shown, as in mediaremote-adapter.
    if (pid > 0 && bundleIdentifier && [title isKindOfClass:NSString.class] && title.length > 0) {
        state[@"bundleIdentifier"] = bundleIdentifier;
        if (parentBundleIdentifier) state[@"parentApplicationBundleIdentifier"] = parentBundleIdentifier;
        state[@"playing"] = @(playing);
        state[@"title"] = title;
        copyValue(state, @"artist", info, @"kMRMediaRemoteNowPlayingInfoArtist", NSString.class);
        copyValue(state, @"album", info, @"kMRMediaRemoteNowPlayingInfoAlbum", NSString.class);
        copyValue(state, @"duration", info, @"kMRMediaRemoteNowPlayingInfoDuration", NSNumber.class);
        copyValue(state, @"elapsedTime", info, @"kMRMediaRemoteNowPlayingInfoElapsedTime", NSNumber.class);
        copyValue(state, @"playbackRate", info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate", NSNumber.class);
        copyValue(state, @"shuffleMode", info, @"kMRMediaRemoteNowPlayingInfoShuffleMode", NSNumber.class);
        copyValue(state, @"repeatMode", info, @"kMRMediaRemoteNowPlayingInfoRepeatMode", NSNumber.class);
        NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if ([timestamp isKindOfClass:NSDate.class]) state[@"timestamp"] = @(timestamp.timeIntervalSince1970);

        artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if (![artwork isKindOfClass:NSData.class]) artwork = nil;
        // MediaRemote often drops the artwork for a moment and loads it again.
        if (!artwork && isSameTrack(state, lastState)) artwork = lastArtwork;
    }

    BOOL artworkChanged = artwork != lastArtwork && ![artwork isEqualToData:lastArtwork];
    if (!artworkChanged && [state isEqualToDictionary:lastState]) return;

    NSMutableDictionary *line = [NSMutableDictionary dictionaryWithObject:state forKey:@"state"];
    if (artworkChanged) {
        line[@"artwork"] = artwork ? [artwork base64EncodedStringWithOptions:0] : NSNull.null;
    }
    lastState = state;
    lastArtwork = artwork;
    printLine(line);
}

/// Asks MediaRemote for everything at once and publishes when all answers are in.
static void refresh(void) {
    uint64_t current = ++generation;
    __block int pid = 0;
    __block BOOL playing = NO;
    __block NSString *parentBundleIdentifier = nil;
    __block NSDictionary *info = nil;
    dispatch_group_t group = dispatch_group_create();

    dispatch_group_enter(group);
    MR.getNowPlayingApplicationPID(queue, ^(int value) {
      pid = value;
      dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    MR.getNowPlayingApplicationIsPlaying(queue, ^(bool value) {
      playing = value;
      dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    MR.getNowPlayingClient(queue, ^(id client) {
      // In a browser the media comes from a helper process; this names the browser itself.
      if ([client respondsToSelector:@selector(parentApplicationBundleIdentifier)]) {
          id value = [(id<MRClient>)client parentApplicationBundleIdentifier];
          if ([value isKindOfClass:NSString.class]) parentBundleIdentifier = value;
      }
      dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    MR.getNowPlayingInfo(queue, ^(NSDictionary *value) {
      info = value;
      dispatch_group_leave(group);
    });

    dispatch_group_notify(group, queue, ^{
      if (current == generation) publish(pid, playing, parentBundleIdentifier, info);
    });
}

/// Merges bursts of notifications, e.g. title and artwork arriving separately.
static void scheduleRefresh(void) {
    dispatch_async(queue, ^{
      if (refreshScheduled) return;
      refreshScheduled = YES;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), queue, ^{
        refreshScheduled = NO;
        refresh();
      });
    });
}

EXPORT void liland_stream(void) {
    loadMediaRemote();
    queue = dispatch_queue_create("Liland.NowPlayingHelper", DISPATCH_QUEUE_SERIAL);

    // Quit with Liland, even if it crashes before it can stop the helper.
    pid_t parent = getppid();
    if (parent <= 1) exit(0);
    dispatch_source_t parentExit = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)parent, DISPATCH_PROC_EXIT, queue);
    dispatch_source_set_event_handler(parentExit, ^{ exit(0); });
    dispatch_resume(parentExit);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[
             @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
         ]) {
        [center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
    }
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                                                                object:nil
                                                                 queue:nil
                                                            usingBlock:^(NSNotification *note) { scheduleRefresh(); }];

    MR.registerForNowPlayingNotifications(queue);
    dispatch_async(queue, ^{ refresh(); });
    CFRunLoopRun();
}

#pragma mark - Commands

/// MediaRemote delivers commands asynchronously; one more round trip makes sure
/// this one went out before the process exits.
static void waitForDelivery(void) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MR.getNowPlayingApplicationPID(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(int pid) {
      dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

static int modeArgument(NSString *value) {
    int mode = value.intValue;
    if (mode < 1 || mode > 3) fail([NSString stringWithFormat:@"Invalid mode: %@", value]);
    return mode;
}

EXPORT void liland_command(void) {
    loadMediaRemote();

    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSUInteger index = [arguments indexOfObject:@"command"];
    if (index == NSNotFound || index + 1 >= arguments.count) fail(@"Missing command");
    NSString *name = arguments[index + 1];
    NSString *value = index + 2 < arguments.count ? arguments[index + 2] : nil;

    if ([name isEqualToString:@"play"]) {
        MR.sendCommand(MRPlay, nil);
    } else if ([name isEqualToString:@"pause"]) {
        MR.sendCommand(MRPause, nil);
    } else if ([name isEqualToString:@"nextTrack"]) {
        MR.sendCommand(MRNextTrack, nil);
    } else if ([name isEqualToString:@"previousTrack"]) {
        MR.sendCommand(MRPreviousTrack, nil);
    } else if ([name isEqualToString:@"seek"] && value) {
        MR.setElapsedTime(MAX(value.doubleValue, 0));
    } else if ([name isEqualToString:@"shuffle"] && value) {
        MR.setShuffleMode(modeArgument(value));
    } else if ([name isEqualToString:@"repeat"] && value) {
        MR.setRepeatMode(modeArgument(value));
    } else {
        fail([NSString stringWithFormat:@"Unknown command: %@", name]);
    }
    waitForDelivery();
}
