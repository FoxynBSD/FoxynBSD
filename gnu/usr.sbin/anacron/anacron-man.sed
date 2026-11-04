# anacron(8) and anacrontab(5) as this system runs anacron (Makefile).
# Disabling it: the anacron line of /etc/crontab, not cron.hourly.
/^In case you want to disable Anacron, add a line with$/,/^file\.$/c\
To stop running Anacron, comment out its line in\
.IR /etc/crontab ;\
.BR periodic (8)\
then needs its own daily, weekly and monthly lines there again.
# The example: periodic(8), not run-parts.
s|^1\t\t5\tcron\.daily\t\tnice run-parts /etc/cron\.daily$|1\t\t5\tperiodic.daily\t\tnice periodic daily|
s|^7\t\t0\tcron\.weekly\t\tnice run-parts /etc/cron\.weekly$|7\t\t0\tperiodic.weekly\t\tnice periodic weekly|
s|^@monthly\t0\tcron\.monthly\t\tnice run-parts /etc/cron\.monthly$|@monthly\t0\tperiodic.monthly\tnice periodic monthly|
s|^# delay will be 5 minutes + RANDOM_DELAY for cron\.daily$|# delay will be 5 minutes + RANDOM_DELAY for periodic.daily|
