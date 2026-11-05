/*
 * A counter that processes can share as a file descriptor, for event
 * notification: eventfd(2), compatible with Linux and FreeBSD.
 */
#ifndef _SYS_EVENTFD_H_
#define _SYS_EVENTFD_H_

#include <sys/cdefs.h>
#include <sys/types.h>
#include <sys/fcntl.h>

#define EFD_SEMAPHORE	0x00000001
#define EFD_NONBLOCK	O_NONBLOCK
#define EFD_CLOEXEC	O_CLOEXEC

typedef uint64_t eventfd_t;

#ifndef _KERNEL
__BEGIN_DECLS
int	eventfd(unsigned int, int);
int	eventfd_read(int, eventfd_t *);
int	eventfd_write(int, eventfd_t);
__END_DECLS
#endif

#endif /* !_SYS_EVENTFD_H_ */
