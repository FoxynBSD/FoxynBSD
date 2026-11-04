# crontab(1) and crontab(5): Cronie's.

PROG=	crontab
SRCS=	crontab.c security.c entry.c env.c misc.c pw_dup.c
CRONIE_MAN= crontab.1 crontab.5
MAN=	${CRONIE_MAN}

DPADD=	${LIBPAM}
LDADD=	${MINUSLPAM}
LDFLAGS+= ${LDFLAGSPAM}

BINDIR=	/usr/bin
BINOWN=	root
BINMODE=4555
.if !defined(NOFSCHG)
INSTALLFLAGS=-fschg
.endif

.include <bsd.prog.mk>
