# libyaml, for Ruby's psych (YAML) extension: a private library.
LIBYAML_SRC=	${.CURDIR}/../../contrib/libyaml

LIB=		private_yaml
SHLIB_MAJOR=	2
PRIVATELIB=	shpub

WARNS?=		2

SRCS=		api.c dumper.c emitter.c loader.c parser.c reader.c scanner.c \
		writer.c
INCS=		yaml.h
INCSDIR=	${INCLUDEDIR}/priv

# What vendor configure.ac puts in config.h.
CFLAGS+=	-I${LIBYAML_SRC}/include
CFLAGS+=	-DYAML_VERSION_MAJOR=0 -DYAML_VERSION_MINOR=2
CFLAGS+=	-DYAML_VERSION_PATCH=5 -DYAML_VERSION_STRING=\"0.2.5\"

.PATH:	${LIBYAML_SRC}/src ${LIBYAML_SRC}/include

.include <bsd.lib.mk>
