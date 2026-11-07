/* Isolate the nil-connection path from experimental runtime shutdown. */
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <stdio.h>
@interface StubNameServer : NSObject
@end
@implementation StubNameServer
- (NSPort *)portForName:(NSString *)name onHost:(NSString *)host
{
  (void)name; (void)host;
  return [NSMessagePort port];
}
@end
@interface NullConnection : NSConnection
@end
@implementation NullConnection
+ (NSConnection *)connectionWithReceivePort:(NSPort *)receive sendPort:(NSPort *)send
{
  (void)receive; (void)send;
  return nil;
}
@end
int main(void)
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];
  StubNameServer *server = [StubNameServer new];
  NSConnection *connection = [NullConnection connectionWithRegisteredName:@"synthetic"
                                                                        host:nil
                                                             usingNameServer:(NSPortNameServer *)server];
  int result = connection == nil ? 0 : 1;
  [server release];
  [pool drain];
  fprintf(stderr, "null-result: %d\n", result);
  _exit(result);
}
