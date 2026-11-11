/*
 * gnustep-fetch URL [TEXT]: load URL as a GNUstep application does, with
 * Foundation's NSURLSession (libcurl) and with -[NSData
 * initWithContentsOfURL:] (GNUstep's own HTTP client), and print what
 * each got.  Exit 0 when both loaded it (and found TEXT in it, when
 * given), 1 when one of them failed, 2 on a usage error.  Built and run
 * by desktop-session's `net` test.
 */
#import <Foundation/Foundation.h>

static int
check(const char *how, NSData *data, NSError *error, NSString *text)
{
	NSString *s;

	if (data == nil) {
		printf("%s: failed: %s\n", how, error ?
		    [[error localizedDescription] UTF8String] : "no data");
		return 1;
	}
	s = [[[NSString alloc] initWithData: data
	    encoding: NSUTF8StringEncoding] autorelease];
	printf("%s: %lu bytes\n", how, (unsigned long)[data length]);
	if (text != nil && (s == nil ||
	    [s rangeOfString: text].location == NSNotFound)) {
		printf("%s: \"%s\" is not in the reply\n", how, [text UTF8String]);
		return 1;
	}
	return 0;
}

int
main(int argc, char **argv)
{
	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	NSURL *url;
	NSString *text = nil;
	NSURLSession *session;
	NSDate *limit;
	__block NSData *got = nil;
	__block NSError *err = nil;
	__block BOOL done = NO;
	int rc = 0;

	if (argc < 2 || argc > 3) {
		fprintf(stderr, "usage: gnustep-fetch URL [TEXT]\n");
		return 2;
	}
	url = [NSURL URLWithString: [NSString stringWithUTF8String: argv[1]]];
	if (argc == 3)
		text = [NSString stringWithUTF8String: argv[2]];

	/* NSURLSession: completion on the delegate queue; wait for it. */
	session = [NSURLSession sessionWithConfiguration:
	    [NSURLSessionConfiguration ephemeralSessionConfiguration]];
	[[session dataTaskWithURL: url completionHandler:
	    ^(NSData *d, NSURLResponse *r, NSError *e) {
		got = [d retain];
		err = [e retain];
		done = YES;
	}] resume];
	limit = [NSDate dateWithTimeIntervalSinceNow: 30];
	while (!done && [limit timeIntervalSinceNow] > 0)
		[[NSRunLoop currentRunLoop] runMode: NSDefaultRunLoopMode
		    beforeDate: [NSDate dateWithTimeIntervalSinceNow: 0.1]];
	if (!done) {
		printf("NSURLSession: no answer in 30 s\n");
		rc = 1;
	} else
		rc |= check("NSURLSession", got, err, text);
	[session invalidateAndCancel];

	/* GNUstep's NSURLHandle, through NSData. */
	rc |= check("NSData", [NSData dataWithContentsOfURL: url], nil, text);

	[pool release];
	return rc;
}
