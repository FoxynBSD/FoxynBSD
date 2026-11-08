/* Exercise Objective-C unwinding and ordinary process finalization. */
#import <Foundation/Foundation.h>
#include <unistd.h>

int
main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  int caught = 0;

  @try
    {
      [NSException raise: @"FoxynProbe" format: @"expected"];
    }
  @catch (NSException *exception)
    {
      caught = [[exception name] isEqualToString: @"FoxynProbe"];
    }
  if (caught)
    (void)write(1, "EXCEPTION_CAUGHT\n", 17);
  [pool drain];
  return caught ? 0 : 1;
}
