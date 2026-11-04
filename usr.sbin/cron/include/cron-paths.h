/*
 * Cronie's paths on FoxynBSD (in place of the cron-paths.h that its
 * makefiles generate).  The users' crontabs and the allow/deny files
 * stay where the BSD cron kept them, /var/cron, which pw(8), rmuser(8)
 * and the mtree files know; the system crontab is /etc/crontab and
 * /etc/cron.d holds more of its kind.
 */

#ifndef _CRON_PATHS_H_
#define _CRON_PATHS_H_

#define SPOOL_DIR	"/var/cron/tabs"	/* the users' crontabs */
#define CRON_HOSTNAME	".cron.hostname"	/* in SPOOL_DIR: cron -c */

/*
 * crontab(1) for users other than root: with an allow file, only those
 * listed in it; else with a deny file, all but those listed; with
 * neither, nobody.  The base installs an empty deny file, so that every
 * user may have a crontab, as with the BSD cron.
 */
#define CRON_ALLOW	"/var/cron/allow"
#define CRON_DENY	"/var/cron/deny"

#define CRON_PID_DIR	"/var/run"		/* crond.pid, cron.reboot */
#define SYSCRONTAB	"/etc/crontab"
#define SYS_CROND_DIR	"/etc/cron.d"
#define SYSCONFDIR	"/etc"

#endif /* !_CRON_PATHS_H_ */
