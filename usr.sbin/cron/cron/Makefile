# cron(8): Cronie's crond, installed as /usr/sbin/cron (rc.d/cron) and,
# as its manual page calls it, /usr/sbin/crond.

PROG=	cron
SRCS=	cron.c database.c do_command.c job.c popen.c security.c user.c \
	cronie_common.c entry.c env.c misc.c pw_dup.c compat.c
CRONIE_MAN= cron.8
MAN=	${CRONIE_MAN}
MLINKS=	cron.8 crond.8
LINKS=	${BINDIR}/cron ${BINDIR}/crond

DPADD=	${LIBPAM}
LDADD=	${MINUSLPAM}
LDFLAGS+= ${LDFLAGSPAM}

.include <bsd.prog.mk>
