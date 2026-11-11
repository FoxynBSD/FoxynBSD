/*
 * GNUstep and libdispatch's main queue (desktop-session gnustep): blocks
 * dispatched to the main queue from another thread, and an operation
 * added to NSOperationQueue's main queue, must run from the main run
 * loop.  Prints "mainqueue: N of 5 blocks, operation ran: 0|1"; exits 0
 * when all ran.
 */
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>

static int count;

int
main(void)
{
	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	NSRunLoop *rl = [NSRunLoop currentRunLoop];
	NSDate *until;
	__block int ran = 0;

	dispatch_async(dispatch_get_global_queue(0, 0), ^{
		for (int i = 0; i < 5; i++)
			dispatch_async(dispatch_get_main_queue(), ^{ count++; });
	});
	until = [NSDate dateWithTimeIntervalSinceNow: 5.0];
	while (count < 5 && [until timeIntervalSinceNow] > 0)
		[rl runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];

	[NSThread detachNewThreadWithBlock: ^{
		[[NSOperationQueue mainQueue] addOperationWithBlock: ^{ ran = 1; }];
	}];
	until = [NSDate dateWithTimeIntervalSinceNow: 5.0];
	while (!ran && [until timeIntervalSinceNow] > 0)
		[rl runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];

	printf("mainqueue: %d of 5 blocks, operation ran: %d\n", count, ran);
	[pool release];
	return (count == 5 && ran) ? 0 : 1;
}
