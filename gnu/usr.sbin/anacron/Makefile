# anacron(8): Cronie's anacron, from the contrib/cronie submodule (see
# contrib/cronie.README.DRAGONFLY).  It is GPL (anacron, version 2 or
# later; obstack, LGPL 2.1 or later), so it is built here, under gnu/,
# apart from cron(8) and crontab(1) (ISC and BSD, usr.sbin/cron).
# cron(8) runs it every hour from /etc/crontab; /etc/anacrontab runs
# periodic(8) daily, weekly and monthly, also after the machine was off.

CRONIE=	${.CURDIR}/../../../contrib/cronie

.if !exists(${CRONIE}/anacron/main.c)
.error contrib/cronie is a git submodule and is not checked out: run "git submodule update --init contrib/cronie"
.endif

PROG=	anacron
SRCS=	gregor.c lock.c log.c main.c matchrx.c readtab.c runjob.c \
	cronie_common.c obstack.c
CRONIE_MAN= anacron.8 anacrontab.5
MAN=	${CRONIE_MAN}

.PATH:	${CRONIE}/anacron ${CRONIE}/obstack ${CRONIE}

# Cronie's config.h (usr.sbin/cron/include) and this directory's
# anacron-paths.h; obstack.h is Cronie's own copy, this libc has none.
CFLAGS+=	-I${.CURDIR} -I${.CURDIR}/../../../usr.sbin/cron/include \
		-I${CRONIE}/anacron -I${CRONIE}/obstack -I${CRONIE}

WARNS?=	2

# The manual pages, with this system's ways (see anacron-man.sed).
.for _m in ${CRONIE_MAN}
${_m}: ${CRONIE}/man/${_m} ${.CURDIR}/anacron-man.sed
	sed -f ${.CURDIR}/anacron-man.sed ${CRONIE}/man/${_m} > ${.TARGET}
CLEANFILES+=	${_m}
.endfor

.include <bsd.prog.mk>
