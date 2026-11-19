// What macOS says is playing (Control Center's Now Playing), cover included, written on stdout as
// one line of JSON each time it changes.
//
// Since macOS 15.4 only Apple's own programs may read it. This library is loaded by /usr/bin/perl,
// which is one, and never by Yumi itself:
//   perl -e 'use DynaLoader; ...dl_install_xsub("main::watch", dl_find_symbol($lib, "yumi_now_playing_watch")); watch()' lib.dylib
// It ends when Yumi does (its parent becomes launchd). It reads, it never commands.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

typedef void (*GetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClient)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*ClientString)(id);
typedef void (*Register)(dispatch_queue_t);

static GetInfo getInfo;
static GetIsPlaying getIsPlaying;
static GetClient getClient;
static ClientString clientBundle, clientParent;
static NSString *last;

static id orNull(id value) { return value ?: [NSNull null]; }

static void write_line(NSDictionary *info, BOOL playing, id client) {
    NSString *(^text)(NSString *) = ^NSString *(NSString *key) {
        id value = info[key];
        return [value isKindOfClass:[NSString class]] ? value : nil;
    };
    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    NSDictionary *line = @{
        @"bundle": orNull(client && clientBundle ? (__bridge NSString *)clientBundle(client) : nil),
        @"parent": orNull(client && clientParent ? (__bridge NSString *)clientParent(client) : nil),
        @"playing": @(playing),
        @"title": orNull(text(@"kMRMediaRemoteNowPlayingInfoTitle")),
        @"artist": orNull(text(@"kMRMediaRemoteNowPlayingInfoArtist")),
        @"album": orNull(text(@"kMRMediaRemoteNowPlayingInfoAlbum")),
        @"duration": orNull(info[@"kMRMediaRemoteNowPlayingInfoDuration"]),
        @"elapsed": orNull(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]),
        @"timestamp": [stamp isKindOfClass:[NSDate class]] ? @(stamp.timeIntervalSince1970) : [NSNull null],
        @"artwork": [artwork isKindOfClass:[NSData class]] ? [artwork base64EncodedStringWithOptions:0] : [NSNull null],
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:line options:0 error:nil];
    NSString *string = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
    if (!string || [string isEqualToString:last]) return;
    last = string;
    printf("%s\n", string.UTF8String);
    fflush(stdout);
}

static void report(void) {
    dispatch_queue_t main = dispatch_get_main_queue();
    getInfo(main, ^(CFDictionaryRef info) {
        NSDictionary *copy = [(__bridge NSDictionary *)info copy] ?: @{};
        getIsPlaying(main, ^(Boolean playing) {
            if (!getClient) return write_line(copy, playing, nil);
            getClient(main, ^(id client) { write_line(copy, playing, client); });
        });
    });
}

// Called by perl as an XSUB: its two arguments (the interpreter and the sub) are not used.
void yumi_now_playing_watch(void *unusedInterpreter, void *unusedSub) {
    void *remote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = (GetInfo)dlsym(remote, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (GetIsPlaying)dlsym(remote, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = (GetClient)dlsym(remote, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = (ClientString)dlsym(remote, "MRNowPlayingClientGetBundleIdentifier");
    clientParent = (ClientString)dlsym(remote, "MRNowPlayingClientGetParentAppBundleIdentifier");
    Register registerForNotifications = (Register)dlsym(remote, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !registerForNotifications) exit(1);

    registerForNotifications(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        CFStringRef *constant = (CFStringRef *)dlsym(remote, name.UTF8String);
        NSString *posted = constant ? (__bridge NSString *)*constant : name;
        [NSNotificationCenter.defaultCenter addObserverForName:posted object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { report(); }];
    }
    report();
    // Yumi gone: nobody reads any more
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        if (getppid() == 1) exit(0);
    }];
    CFRunLoopRun();
    exit(0);
}
