# Cronie's manual pages with the paths of this system (see Makefile.inc).
s|/var/spool/cron|/var/cron/tabs|g
s|/etc/cron\.allow|/var/cron/allow|g
s|/etc/cron\.deny|/var/cron/deny|g
# Anacron is not built: /etc/crontab runs periodic(8).
/^system crontab\.  Nowadays the file is empty/,/^for more details\.$/c\
system crontab: the system's jobs, among them\
.BR periodic (8)\
daily, weekly and monthly.
s|^\.I /etc/anacrontab$|.I /etc/crontab|
# Started by rc(8), not sysvinit or systemd.
/^is started from$/,/^the '&' parameter\.$/c\
is started at boot by\
.I /etc/rc.d/cron\
when\
.I cron_enable\
is set in\
.BR rc.conf (5),\
and puts itself in the background.
