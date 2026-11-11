/*
 * GNUstep clicks and keys (desktop-session clicks): a window with a text
 * view at x 900-1200, y 300-500 (X coordinates) that logs, with times,
 * when its -mouseDown: is entered and returns and each -keyDown:.  A
 * mouse-down whose button release was lost leaves -mouseDown: in its
 * tracking loop, and the key events wait until the next click.
 */
#import <AppKit/AppKit.h>
#include <sys/time.h>

static double
now(void)
{
	struct timeval t;

	gettimeofday(&t, 0);
	return t.tv_sec + t.tv_usec / 1e6;
}

@interface ProbeView : NSTextView
@end

@implementation ProbeView
- (void) mouseDown: (NSEvent *)e
{
	printf("clickprobe: %.3f mouseDown enter\n", now());
	fflush(stdout);
	[super mouseDown: e];
	printf("clickprobe: %.3f mouseDown return\n", now());
	fflush(stdout);
}

- (void) keyDown: (NSEvent *)e
{
	printf("clickprobe: %.3f keyDown %s\n", now(), [[e characters] UTF8String]);
	fflush(stdout);
	[super keyDown: e];
}
@end

int
main(void)
{
	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	NSWindow *w;
	ProbeView *v;

	[NSApplication sharedApplication];
	w = [[NSWindow alloc] initWithContentRect: NSMakeRect(900, 300, 300, 200)
	    styleMask: NSTitledWindowMask backing: NSBackingStoreBuffered defer: NO];
	[w setTitle: @"clickprobe"];
	v = [[ProbeView alloc] initWithFrame: NSMakeRect(0, 0, 300, 200)];
	[w setContentView: v];
	[w makeFirstResponder: v];
	[w makeKeyAndOrderFront: nil];
	[NSApp run];
	[pool release];
	return 0;
}
