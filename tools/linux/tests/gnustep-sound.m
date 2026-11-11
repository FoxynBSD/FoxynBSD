/*
 * gnustep-sound FILE: play FILE with AppKit's NSSound, as a GNUstep
 * application does, and wait for -sound:didFinishPlaying:.  Exit 0 when
 * it finished playing, 1 when it could not start, 2 when it did not
 * finish within 30 seconds.  Built and run by desktop-session's `sound`
 * test.
 */
#import <AppKit/AppKit.h>

@interface Probe : NSObject
{
@public
	BOOL done, finished;
}
@end

@implementation Probe
- (void)sound:(NSSound *)sound didFinishPlaying:(BOOL)ok
{
	done = YES;
	finished = ok;
}
@end

int
main(int argc, char **argv)
{
	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	NSSound *sound;
	Probe *probe;
	NSDate *start, *limit;

	if (argc != 2) {
		fprintf(stderr, "usage: gnustep-sound FILE\n");
		return 1;
	}
	[NSApplication sharedApplication];
	sound = [[NSSound alloc] initWithContentsOfFile:
	    [NSString stringWithUTF8String:argv[1]] byReference: NO];
	if (sound == nil) {
		printf("NSSound cannot read %s\n", argv[1]);
		return 1;
	}
	printf("NSSound: %.1f s\n", [sound duration]);
	probe = [Probe new];
	[sound setDelegate: probe];
	start = [NSDate date];
	if (![sound play]) {
		printf("NSSound -play failed\n");
		return 1;
	}
	limit = [NSDate dateWithTimeIntervalSinceNow: 30];
	while (!probe->done && [limit timeIntervalSinceNow] > 0)
		[[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
		    beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.2]];
	if (!probe->done) {
		printf("NSSound did not finish within 30 s\n");
		return 2;
	}
	printf("NSSound finished (%s) after %.1f s\n",
	    probe->finished ? "played" : "stopped",
	    -[start timeIntervalSinceNow]);
	[pool release];
	return probe->finished ? 0 : 2;
}
