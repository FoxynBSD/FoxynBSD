/*
 * What usr.sbin/makefs needs on a Linux host beyond host-compat.h:
 * build.sh force-includes both (with libbsd's overlay) when it builds
 * makefs for `build.sh disk`.  Never used for FoxynBSD code itself.
 */
#ifndef _FOXYN_MAKEFS_COMPAT_H_
#define _FOXYN_MAKEFS_COMPAT_H_

#include <sys/time.h>
#include <sys/sysmacros.h>	/* major, minor, makedev */
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <stddef.h>
#include <stdint.h>

/* <sys/endian.h> */
#define bswap16(x)	__builtin_bswap16(x)
#define bswap32(x)	__builtin_bswap32(x)
#define bswap64(x)	__builtin_bswap64(x)

/* <sys/param.h>, <machine/param.h>, <sys/limits.h> */
#ifndef MAXFRAG
#define MAXFRAG		8
#endif
#ifndef MAXPHYS
#define MAXPHYS		(128 * 1024)
#endif
#ifndef UID_MAX
#define UID_MAX		UINT_MAX
#endif
#ifndef GID_MAX
#define GID_MAX		UINT_MAX
#endif

/* <sys/cdefs.h> */
#ifndef __printf0like
#define __printf0like(fmt, va)	__attribute__((__format__(__printf__, fmt, va)))
#endif
#define _DIAGASSERT(e)	((void)0)

/* File flags (<sys/stat.h>), for mtree's flags= keyword. */
#define UF_NODUMP	0x00000001
#define UF_IMMUTABLE	0x00000002
#define UF_APPEND	0x00000004
#define UF_OPAQUE	0x00000008
#define UF_NOUNLINK	0x00000010
#define UF_NOHISTORY	0x00000040
#define UF_CACHE	0x00000080
#define UF_XLINK	0x00000100
#define SF_ARCHIVED	0x00010000
#define SF_IMMUTABLE	0x00020000
#define SF_APPEND	0x00040000
#define SF_NOUNLINK	0x00100000
#define SF_NOHISTORY	0x00400000
#define SF_NOCACHE	0x00800000
#define SF_XLINK	0x01000000

/* libutil's efun(3) (lib/libutil/efun.c) and libc's strsuftoll(3). */
char	*estrdup(const char *);
char	*estrndup(const char *, size_t);
void	*ecalloc(size_t, size_t);
void	*emalloc(size_t);
void	*erealloc(void *, size_t);
int	easprintf(char **, const char *, ...);
long long strsuftoll(const char *, const char *, long long, long long);
long long strsuftollx(const char *, const char *, long long, long long,
	    char *, size_t);

/* pwcache(3): glibc has no setgroupent/setpassent, nor -N (pwcache_*db). */
static inline int setgroupent(int stayopen) { (void)stayopen; setgrent(); return 1; }
static inline int setpassent(int stayopen) { (void)stayopen; setpwent(); return 1; }
#define pwcache_groupdb(a, b, c, d)	(-1)
#define pwcache_userdb(a, b, c, d)	(-1)

#endif /* !_FOXYN_MAKEFS_COMPAT_H_ */
