# This version of libressl is from LibreSSL
.include "../librecrypto/Makefile.inc"

LIB=		private_ssl
# etc/libmap.conf maps DragonFly's older version to this one: update it too.
SHLIB_MAJOR=	60
PRIVATELIB=	shpub

SHLIBDIR?=	/lib
WARNS?=		2

# The include path of vendor ssl/Makefile.am: the hidden/ wrappers first.
CFLAGS:=	-I${LSSL_SRC}/hidden ${CFLAGS}
CFLAGS+=	-I${LCRYPTO_SRC}/bio -I${LCRYPTO_SRC}/arch/amd64
CFLAGS+=	-DLIBRESSL_INTERNAL

# from vendor ssl/Makefile.am: libssl_la_SOURCES and libbs_la_SOURCES
SRCS=	bio_ssl.c d1_both.c d1_lib.c d1_pkt.c d1_srtp.c pqueue.c s3_cbc.c \
	s3_lib.c ssl_asn1.c ssl_both.c ssl_cert.c ssl_ciph.c ssl_ciphers.c \
	ssl_clnt.c ssl_err.c ssl_init.c ssl_kex.c ssl_lib.c ssl_methods.c \
	ssl_pkt.c ssl_rsa.c ssl_seclevel.c ssl_sess.c ssl_sigalgs.c \
	ssl_srvr.c ssl_stat.c ssl_tlsext.c ssl_transcript.c ssl_txt.c \
	ssl_versions.c t1_enc.c t1_lib.c tls_buffer.c tls_content.c \
	tls_key_share.c tls_lib.c tls12_key_schedule.c tls12_lib.c \
	tls12_record_layer.c tls13_client.c tls13_error.c \
	tls13_handshake.c tls13_handshake_msg.c tls13_key_schedule.c \
	tls13_legacy.c tls13_lib.c tls13_quic.c tls13_record.c \
	tls13_record_layer.c tls13_server.c
SRCS+=	bs_ber.c bs_cbb.c bs_cbs.c

INCS=	dtls1.h srtp.h ssl.h ssl3.h tls1.h
INCSDIR=	${INCLUDEDIR}/priv/openssl
# The public headers: crypto/ has internal ones of the same names.
INCS:=		${INCS:S|^|${LIBRESSL_SRC}/include/openssl/|}

LDADD=		-lprivate_crypto
DPADD=		${LIBCRYPTO}
LDFLAGS+=	${PRIVATELIB_LDFLAGS}

.PATH:	${LSSL_SRC} ${LIBRESSL_SRC}/include/openssl

.include <bsd.lib.mk>
