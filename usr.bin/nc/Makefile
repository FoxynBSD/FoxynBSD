# This version of nc(1) is from LibreSSL
.include "${.CURDIR}/../../lib/librecrypto/Makefile.inc"

.PATH: ${LIBRESSL_SRC}/apps/nc ${LIBRESSL_SRC}/apps/nc/compat
.PATH: ${LIBRESSL_SRC}/tls

PROG=	nc
# from vendor apps/nc/Makefile.am (libc has b64_ntop)
SRCS=	atomicio.c netcat.c socks.c socket.c

# TLS block (no separate libtls.a): vendor tls/Makefile.am
SRCS+=	tls.c tls_client.c tls_bio_cb.c tls_config.c tls_conninfo.c \
	tls_keypair.c tls_server.c tls_signer.c tls_ocsp.c tls_peer.c \
	tls_util.c tls_verify.c

WARNS?=	2

CFLAGS+=	-DLIBRESSL_INTERNAL

DPADD=	${LIBCRYPTO} ${LIBSSL}
LDADD=	-lprivate_ssl -lprivate_crypto
LDFLAGS+=	${PRIVATELIB_LDFLAGS}

.include <bsd.prog.mk>
