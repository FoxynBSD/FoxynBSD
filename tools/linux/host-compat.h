/*
 * BSD definitions that host tools from the FoxynBSD tree expect but glibc
 * does not provide.  build.sh force-includes this (with libbsd's overlay)
 * when it compiles those tools on Linux; it is never used for FoxynBSD
 * code itself.
 */
#ifndef _FOXYN_HOST_COMPAT_H_
#define _FOXYN_HOST_COMPAT_H_

#include <sys/cdefs.h>
#include <sys/param.h>

#ifndef __unused
#define __unused	__attribute__((__unused__))
#endif
#ifndef __dead2
#define __dead2		__attribute__((__noreturn__))
#endif
#ifndef __printflike
#define __printflike(fmt, va) __attribute__((__format__(__printf__, fmt, va)))
#endif
#ifndef __DECONST
#define __DECONST(type, var)	((type)(__uintptr_t)(const void *)(var))
#endif
#ifndef NELEM
#define NELEM(ary)	(sizeof(ary) / sizeof((ary)[0]))
#endif
#ifndef nitems
#define nitems(x)	NELEM(x)
#endif

#endif /* !_FOXYN_HOST_COMPAT_H_ */
