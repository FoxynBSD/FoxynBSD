# cron(8) and crontab(1) are Cronie, from the contrib/cronie submodule
# (see contrib/cronie.README.DRAGONFLY).  The configuration Cronie's
# configure script would write is in include/: config.h, cron-paths.h.

CRONIE=	${.CURDIR}/../../../contrib/cronie

.if !exists(${CRONIE}/src/cron.c)
.error contrib/cronie is a git submodule and is not checked out: run "git submodule update --init contrib/cronie"
.endif

.PATH:	${CRONIE}/src ${CRONIE}

CFLAGS+=	-I${.CURDIR}/../include -I${CRONIE}/src -I${CRONIE}

# Cronie's sources, as they are: no warnings flags beyond the defaults.
WARNS?=	2

# The manual pages, with the paths of this system.  They are built in
# the object directory (the submodule is never written to).
.for _m in ${CRONIE_MAN}
${_m}: ${CRONIE}/man/${_m} ${.CURDIR}/../cronie-man.sed
	sed -f ${.CURDIR}/../cronie-man.sed ${CRONIE}/man/${_m} > ${.TARGET}
CLEANFILES+=	${_m}
.endfor

.include "../Makefile.inc"
