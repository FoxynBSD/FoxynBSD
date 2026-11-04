/*
 * Cronie's config.h for FoxynBSD, written by hand in place of the one
 * its configure script makes (contrib/cronie/configure.ac):
 * crond and crontab with PAM and the system crontab; no SELinux, no
 * Linux audit, no inotify (crond looks at the spool every minute).
 */

#ifndef _CRONIE_CONFIG_H_
#define _CRONIE_CONFIG_H_

/* contrib/cronie is at master after 1.7.2 (cronie.README.DRAGONFLY). */
#define PACKAGE_VERSION		"1.7.2-35-g38773f4"
#define PACKAGE_STRING		"cronie 1.7.2-35-g38773f4"

#define HAVE_FCHOWN		1
#define HAVE_FCNTL		1
#define HAVE_FCNTL_H		1
#define HAVE_FLOCK		1
#define HAVE_LIMITS_H		1
#define HAVE_LOCKF		1
#define HAVE_STRUCT_TM_TM_GMTOFF 1
#define HAVE_SYS_CDEFS_H	1
#define HAVE_UNISTD_H		1

/* PAM (OpenPAM): the "crond" service, /etc/pam.d/crond. */
#define WITH_PAM		1
#define HAVE_SECURITY_PAM_APPL_H 1
#define HAVE_PAM_GETENVLIST	1
#define HAVE_PAM_PUTENV		1

/* /etc/crontab, with the user field, besides the users' crontabs. */
#define ENABLE_SYSCRONTAB	1

#define DEBUGGING		1	/* cron -x */
#define SYSLOG			1	/* log to syslog (cron.*) */
#define CAPITALIZE_FOR_PS	1

#define EDITOR			"/usr/bin/vi"
#define MAILARG			"/usr/sbin/sendmail"
#define MAILFMT			"%s -FCronDaemon -i -odi -oem -oi -t -f %s"

#include "cron-paths.h"

/*
 * What Cronie takes from glibc with _GNU_SOURCE:
 *	environ		declared by <unistd.h> there, not here;
 *	execvpe(3)	not in this libc: compat.c (crond only).
 * <fcntl.h> first, so that externs.h finds the system's LOCK_* (the
 * same values) and does not define its own.
 */
#include <fcntl.h>
extern char **environ;
int execvpe(const char *, char * const *, char * const *);

#endif /* !_CRONIE_CONFIG_H_ */
