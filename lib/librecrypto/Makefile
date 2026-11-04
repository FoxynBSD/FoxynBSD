# This version of librecrypto is from LibreSSL
.include "Makefile.inc"

LIB= 		private_crypto
SHLIB_MAJOR=	57
PRIVATELIB=	shpub

SHLIBDIR?=	/lib
WARNS?=		2
NO_STRICT_ALIASING=

INCS=		aes.h asn1.h asn1t.h bio.h blowfish.h bn.h buffer.h camellia.h
INCS+=		cast.h chacha.h cmac.h cms.h comp.h conf.h crypto.h ct.h
INCS+=		curve25519.h des.h dh.h dsa.h ec.h ecdh.h ecdsa.h engine.h err.h
INCS+=		evp.h hkdf.h hmac.h idea.h kdf.h lhash.h md4.h md5.h mlkem.h
INCS+=		modes.h obj_mac.h objects.h ocsp.h opensslconf.h
INCS+=		opensslfeatures.h opensslv.h ossl_typ.h pem.h pkcs12.h pkcs7.h
INCS+=		poly1305.h posix_time.h rand.h rc2.h rc4.h ripemd.h rsa.h
INCS+=		safestack.h sha.h sm3.h sm4.h stack.h ts.h txt_db.h ui.h x509.h
INCS+=		x509_vfy.h x509v3.h
INCSDIR=	${INCLUDEDIR}/priv/openssl
# The public headers: crypto/ has internal ones of the same names.
INCS:=		${INCS:S|^|${LIBRESSL_SRC}/include/openssl/|}

# The include path of vendor crypto/Makefile.am: the hidden/ wrappers
# first (they give the library's internal calls private names).
CFLAGS:=	-I${LCRYPTO_SRC}/hidden ${CFLAGS}
.for d in aes asn1 bio bn bytestring conf curve25519 dh dsa ec ecdh ecdsa \
    err evp hmac lhash mlkem modes ocsp pkcs12 rsa sha stack x509 \
    arch/amd64 bn/arch/amd64
CFLAGS+=	-I${LCRYPTO_SRC}/${d}
.endfor

CFLAGS+=	-DLIBRESSL_INTERNAL -DLIBRESSL_CRYPTO_INTERNAL
CFLAGS+=	-DOPENSSL_NO_HW_PADLOCK
CFLAGS+=	-DOPENSSLDIR=\"/etc/ssl\"
CFLAGS+=	-DHAVE_GNU_STACK

# The x86_64 assembly, as vendor crypto/Makefile.am enables it for an
# ELF x86_64 host.
CFLAGS+=	-DLIBRESSL_USE_AES_ASSEMBLY -DLIBRESSL_USE_BN_ASSEMBLY
CFLAGS+=	-DLIBRESSL_USE_GCM_ASSEMBLY -DLIBRESSL_USE_RC4_ASSEMBLY
CFLAGS+=	-DLIBRESSL_USE_SHA_ASSEMBLY
CFLAGS+=	-DOPENSSL_BN_ASM_MONT -DOPENSSL_BN_ASM_MONT5

# The sources of vendor libcrypto_la_SOURCES (with the x86_64 ELF
# assembly) and the one compat source DragonFly needs (syslog_r.c),
# grouped by directory and with the directory stripped.  Regenerate
# them as README.DRAGONFLY says.
SRCS_AES=	aes_amd64.c aes-elf-x86_64.S aesni-elf-x86_64.S aes.c \
	aes_core.c
SRCS_BN_ARCH_AMD64=	bn_arch.c bignum_add.S bignum_cmadd.S bignum_cmul.S \
	bignum_modadd.S bignum_modsub.S bignum_mul.S bignum_mul_4_8.S \
	bignum_mul_4_8_alt.S bignum_mul_6_12.S bignum_mul_6_12_alt.S \
	bignum_mul_8_16.S bignum_mul_8_16_alt.S bignum_sqr.S bignum_sqr_4_8.S \
	bignum_sqr_4_8_alt.S bignum_sqr_6_12.S bignum_sqr_6_12_alt.S \
	bignum_sqr_8_16.S bignum_sqr_8_16_alt.S bignum_sub.S word_clz.S
SRCS_MODES=	gcm128_amd64.c ghash-elf-x86_64.S cbc128.c ccm128.c cfb128.c \
	ctr128.c gcm128.c ofb128.c xts128.c
SRCS_SHA=	sha1_amd64.c sha256_amd64.c sha512_amd64.c \
	sha1_amd64_generic.S sha1_amd64_shani.S sha256_amd64_generic.S \
	sha256_amd64_shani.S sha512_amd64_generic.S sha1.c sha256.c sha3.c \
	sha512.c
SRCS_BN=	modexp512-elf-x86_64.S mont-elf-x86_64.S mont5-elf-x86_64.S \
	bn_add.c bn_add_sub.c bn_bpsw.c bn_const.c bn_convert.c bn_ctx.c \
	bn_div.c bn_err.c bn_exp.c bn_gcd.c bn_isqrt.c bn_kron.c bn_lib.c \
	bn_mod.c bn_mod_sqrt.c bn_mod_words.c bn_mont.c bn_mul.c bn_prime.c \
	bn_primitives.c bn_print.c bn_rand.c bn_recp.c bn_shift.c \
	bn_small_primes.c bn_sqr.c bn_word.c
SRCS_RC4=	rc4-elf-x86_64.S rc4.c
SRCS_ARCH_AMD64=	crypto_cpu_caps.c
SRCS_TOP=	crypto_err.c crypto_ex_data.c crypto_init.c crypto_legacy.c \
	crypto_lock.c crypto_memory.c
SRCS_ASN1=	a_bitstr.c a_enum.c a_int.c a_mbstr.c a_object.c a_octet.c \
	a_pkey.c a_print.c a_pubkey.c a_strex.c a_string.c a_strnid.c a_time.c \
	a_time_posix.c a_time_tm.c a_type.c a_utf8.c asn1_err.c asn1_gen.c \
	asn1_item.c asn1_lib.c asn1_old.c asn1_old_lib.c asn1_par.c \
	asn1_types.c asn_mime.c asn_moid.c bio_asn1.c bio_ndef.c p5_pbe.c \
	p5_pbev2.c p8_pkey.c t_crl.c t_req.c t_spki.c t_x509.c t_x509a.c \
	tasn_dec.c tasn_enc.c tasn_fre.c tasn_new.c tasn_prn.c tasn_typ.c \
	tasn_utl.c x_algor.c x_attrib.c x_bignum.c x_crl.c x_exten.c x_long.c \
	x_name.c x_pubkey.c x_req.c x_sig.c x_spki.c x_val.c x_x509.c x_x509a.c
SRCS_BF=	blowfish.c
SRCS_BIO=	b_dump.c b_posix.c b_print.c b_sock.c bf_buff.c bf_nbio.c \
	bf_null.c bio_cb.c bio_err.c bio_lib.c bio_meth.c bss_acpt.c bss_bio.c \
	bss_conn.c bss_dgram.c bss_fd.c bss_file.c bss_mem.c bss_null.c \
	bss_sock.c
SRCS_BUFFER=	buf_err.c buffer.c
SRCS_BYTESTRING=	bs_ber.c bs_cbb.c bs_cbs.c
SRCS_CAMELLIA=	camellia.c
SRCS_CAST=	cast.c
SRCS_CHACHA=	chacha.c
SRCS_CMAC=	cm_ameth.c cm_pmeth.c cmac.c
SRCS_CMS=	cms_asn1.c cms_att.c cms_dd.c cms_enc.c cms_env.c cms_err.c \
	cms_ess.c cms_io.c cms_kari.c cms_lib.c cms_pwri.c cms_sd.c cms_smime.c
SRCS_CONF=	conf_api.c conf_def.c conf_err.c conf_lib.c conf_mod.c \
	conf_sap.c
SRCS_CT=	ct_b64.c ct_err.c ct_log.c ct_oct.c ct_policy.c ct_prn.c \
	ct_sct.c ct_sct_ctx.c ct_vfy.c ct_x509v3.c
SRCS_CURVE25519=	curve25519-generic.c curve25519.c
SRCS_DES=	des.c des_cksum.c des_enc.c des_fcrypt.c des_key.c
SRCS_DH=	dh_ameth.c dh_asn1.c dh_check.c dh_err.c dh_gen.c dh_key.c \
	dh_lib.c dh_pmeth.c
SRCS_DSA=	dsa_ameth.c dsa_asn1.c dsa_err.c dsa_gen.c dsa_key.c dsa_lib.c \
	dsa_meth.c dsa_ossl.c dsa_pmeth.c dsa_prn.c
SRCS_EC=	ec_ameth.c ec_asn1.c ec_convert.c ec_curve.c ec_err.c \
	ec_field.c ec_key.c ec_lib.c ec_mult.c ec_pmeth.c eck_prn.c \
	ecp_hp_methods.c ecp_methods.c ecx_methods.c
SRCS_ECDH=	ecdh.c
SRCS_ECDSA=	ecdsa.c
SRCS_ENGINE=	engine_stubs.c
SRCS_ERR=	err.c err_all.c err_prn.c
SRCS_EVP=	bio_b64.c bio_enc.c bio_md.c e_aes.c e_bf.c e_camellia.c \
	e_cast.c e_chacha.c e_chacha20poly1305.c e_des.c e_des3.c e_idea.c \
	e_null.c e_rc2.c e_rc4.c e_sm4.c e_xcbc_d.c evp_aead.c evp_cipher.c \
	evp_digest.c evp_encode.c evp_err.c evp_key.c evp_names.c evp_pbe.c \
	evp_pkey.c m_md4.c m_md5.c m_md5_sha1.c m_null.c m_ripemd.c m_sha1.c \
	m_sha3.c m_sigver.c m_sm3.c p_legacy.c p_lib.c p_sign.c p_verify.c \
	pmeth_fn.c pmeth_gn.c pmeth_lib.c
SRCS_HKDF=	hkdf.c
SRCS_HMAC=	hm_ameth.c hm_pmeth.c hmac.c
SRCS_IDEA=	idea.c
SRCS_KDF=	hkdf_evp.c kdf_err.c tls1_prf.c
SRCS_LHASH=	lhash.c
SRCS_MD4=	md4.c
SRCS_MD5=	md5.c
SRCS_MLKEM=	mlkem.c mlkem_internal.c mlkem_key.c
SRCS_OBJECTS=	obj_dat.c obj_err.c obj_lib.c obj_xref.c
SRCS_OCSP=	ocsp_asn.c ocsp_cl.c ocsp_err.c ocsp_ext.c ocsp_ht.c \
	ocsp_lib.c ocsp_prn.c ocsp_srv.c ocsp_vfy.c
SRCS_PEM=	pem_all.c pem_err.c pem_info.c pem_lib.c pem_oth.c pem_pk8.c \
	pem_pkey.c pem_sign.c pem_x509.c pem_xaux.c pvkfmt.c
SRCS_PKCS12=	p12_add.c p12_asn.c p12_attr.c p12_crt.c p12_decr.c \
	p12_init.c p12_key.c p12_kiss.c p12_mutl.c p12_npas.c p12_p8d.c \
	p12_p8e.c p12_sbag.c p12_utl.c pk12err.c
SRCS_PKCS7=	pk7_asn1.c pk7_attr.c pk7_doit.c pk7_lib.c pk7_mime.c \
	pk7_smime.c pkcs7err.c
SRCS_POLY1305=	poly1305.c
SRCS_RAND=	rand_err.c rand_lib.c randfile.c
SRCS_RC2=	rc2.c
SRCS_RIPEMD=	ripemd.c
SRCS_RSA=	rsa_ameth.c rsa_asn1.c rsa_blinding.c rsa_chk.c rsa_eay.c \
	rsa_err.c rsa_gen.c rsa_lib.c rsa_meth.c rsa_none.c rsa_oaep.c \
	rsa_pk1.c rsa_pmeth.c rsa_prn.c rsa_pss.c rsa_saos.c rsa_sign.c \
	rsa_x931.c
SRCS_SM3=	sm3.c
SRCS_SM4=	sm4.c
SRCS_STACK=	stack.c
SRCS_TS=	ts_asn1.c ts_conf.c ts_err.c ts_lib.c ts_req_print.c \
	ts_req_utils.c ts_rsp_print.c ts_rsp_sign.c ts_rsp_utils.c \
	ts_rsp_verify.c ts_verify_ctx.c
SRCS_TXT_DB=	txt_db.c
SRCS_UI=	ui_err.c ui_lib.c ui_null.c ui_openssl.c
SRCS_X509=	by_dir.c by_file.c by_mem.c x509_addr.c x509_akey.c \
	x509_akeya.c x509_alt.c x509_att.c x509_asid.c x509_bcons.c \
	x509_bitst.c x509_cmp.c x509_conf.c x509_constraints.c x509_cpols.c \
	x509_crld.c x509_d2.c x509_def.c x509_err.c x509_ext.c x509_extku.c \
	x509_genn.c x509_ia5.c x509_info.c x509_int.c x509_issuer_cache.c \
	x509_lib.c x509_lu.c x509_ncons.c x509_obj.c x509_ocsp.c x509_pcons.c \
	x509_pku.c x509_policy.c x509_pmaps.c x509_prn.c x509_purp.c x509_r2x.c \
	x509_req.c x509_set.c x509_siginfo.c x509_skey.c x509_trs.c x509_txt.c \
	x509_utl.c x509_v3.c x509_verify.c x509_vfy.c x509_vpm.c x509cset.c \
	x509name.c x509rset.c x509spki.c x509type.c x_all.c
SRCS_COMPAT=	syslog_r.c

SRCS=	${SRCS_AES} ${SRCS_BN_ARCH_AMD64} ${SRCS_MODES} ${SRCS_SHA} ${SRCS_BN} ${SRCS_RC4} ${SRCS_ARCH_AMD64} ${SRCS_TOP} ${SRCS_ASN1} ${SRCS_BF} ${SRCS_BIO} ${SRCS_BUFFER} ${SRCS_BYTESTRING} ${SRCS_CAMELLIA} ${SRCS_CAST} ${SRCS_CHACHA} ${SRCS_CMAC} ${SRCS_CMS} ${SRCS_CONF} ${SRCS_CT} ${SRCS_CURVE25519} ${SRCS_DES} ${SRCS_DH} ${SRCS_DSA} ${SRCS_EC} ${SRCS_ECDH} ${SRCS_ECDSA} ${SRCS_ENGINE} ${SRCS_ERR} ${SRCS_EVP} ${SRCS_HKDF} ${SRCS_HMAC} ${SRCS_IDEA} ${SRCS_KDF} ${SRCS_LHASH} ${SRCS_MD4} ${SRCS_MD5} ${SRCS_MLKEM} ${SRCS_OBJECTS} ${SRCS_OCSP} ${SRCS_PEM} ${SRCS_PKCS12} ${SRCS_PKCS7} ${SRCS_POLY1305} ${SRCS_RAND} ${SRCS_RC2} ${SRCS_RIPEMD} ${SRCS_RSA} ${SRCS_SM3} ${SRCS_SM4} ${SRCS_STACK} ${SRCS_TS} ${SRCS_TXT_DB} ${SRCS_UI} ${SRCS_X509} ${SRCS_COMPAT}

.PATH:	${LCRYPTO_SRC}/aes \
	${LCRYPTO_SRC}/bn/arch/amd64 \
	${LCRYPTO_SRC}/modes \
	${LCRYPTO_SRC}/sha \
	${LCRYPTO_SRC}/bn \
	${LCRYPTO_SRC}/rc4 \
	${LCRYPTO_SRC}/arch/amd64 \
	${LCRYPTO_SRC} \
	${LCRYPTO_SRC}/asn1 \
	${LCRYPTO_SRC}/bf \
	${LCRYPTO_SRC}/bio \
	${LCRYPTO_SRC}/buffer \
	${LCRYPTO_SRC}/bytestring \
	${LCRYPTO_SRC}/camellia \
	${LCRYPTO_SRC}/cast \
	${LCRYPTO_SRC}/chacha \
	${LCRYPTO_SRC}/cmac \
	${LCRYPTO_SRC}/cms \
	${LCRYPTO_SRC}/conf \
	${LCRYPTO_SRC}/ct \
	${LCRYPTO_SRC}/curve25519 \
	${LCRYPTO_SRC}/des \
	${LCRYPTO_SRC}/dh \
	${LCRYPTO_SRC}/dsa \
	${LCRYPTO_SRC}/ec \
	${LCRYPTO_SRC}/ecdh \
	${LCRYPTO_SRC}/ecdsa \
	${LCRYPTO_SRC}/engine \
	${LCRYPTO_SRC}/err \
	${LCRYPTO_SRC}/evp \
	${LCRYPTO_SRC}/hkdf \
	${LCRYPTO_SRC}/hmac \
	${LCRYPTO_SRC}/idea \
	${LCRYPTO_SRC}/kdf \
	${LCRYPTO_SRC}/lhash \
	${LCRYPTO_SRC}/md4 \
	${LCRYPTO_SRC}/md5 \
	${LCRYPTO_SRC}/mlkem \
	${LCRYPTO_SRC}/objects \
	${LCRYPTO_SRC}/ocsp \
	${LCRYPTO_SRC}/pem \
	${LCRYPTO_SRC}/pkcs12 \
	${LCRYPTO_SRC}/pkcs7 \
	${LCRYPTO_SRC}/poly1305 \
	${LCRYPTO_SRC}/rand \
	${LCRYPTO_SRC}/rc2 \
	${LCRYPTO_SRC}/ripemd \
	${LCRYPTO_SRC}/rsa \
	${LCRYPTO_SRC}/sm3 \
	${LCRYPTO_SRC}/sm4 \
	${LCRYPTO_SRC}/stack \
	${LCRYPTO_SRC}/ts \
	${LCRYPTO_SRC}/txt_db \
	${LCRYPTO_SRC}/ui \
	${LCRYPTO_SRC}/x509 \
	${LCRYPTO_SRC}/compat \
	${LIBRESSL_SRC}/include/openssl

.include <bsd.lib.mk>
