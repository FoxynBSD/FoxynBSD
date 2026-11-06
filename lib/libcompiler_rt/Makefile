# The compiler runtime from LLVM's compiler-rt (contrib/compiler-rt): the
# builtins as libgcc.a and libgcc_pic.a, and crtbegin/crtend, installed in
# /usr/lib/gcc80 where clang's DragonFly driver looks for them.
#
# This stands in for gnu/lib/gcc80/{libgcc,csu}, which need gcc internals
# and do not build with clang.  It is not part of lib/Makefile's SUBDIR:
# on a native build those gcc directories own /usr/lib/gcc80.  The Linux
# host build (tools/linux/build.sh) builds it before libc.
#
# The source list follows contrib/compiler-rt/lib/builtins/CMakeLists.txt
# for x86_64 (GENERIC_SOURCES, GENERIC_TF_SOURCES, BF16_SOURCES,
# x86_ARCH_SOURCES and x86_80_BIT_SOURCES), with the defaults of a
# standalone build: no atomic.c (COMPILER_RT_EXCLUDE_ATOMIC_BUILTIN), PIC
# objects, hidden symbols.  The crt objects use the CRT_CFLAGS of the same
# file; like upstream, one PIC crtbegin.o serves every link mode.

CRTDIR=		${.CURDIR}/../../contrib/compiler-rt/lib/builtins

# The x86_64 versions first: they replace generic files of the same name
# (filter_builtin_sources in CMakeLists.txt).
.PATH:		${CRTDIR}/x86_64 ${CRTDIR}/i386 ${CRTDIR}/cpu_model ${CRTDIR}

LIB=		gcc
LIBDIR=		/usr/lib/gcc80
# Static archives only; CFLAGS makes every object PIC anyway.
NOPIC=		yes
NOPROFILE=	yes

# GENERIC_SOURCES; x86_64/ and i386/ provide floatdidf, floatdisf,
# floatundidf, floatundisf and fp_mode.
SRCS=	absvdi2.c absvsi2.c absvti2.c adddf3.c addsf3.c addvdi3.c addvsi3.c \
	addvti3.c apple_versioning.c ashldi3.c ashlti3.c ashrdi3.c ashrti3.c \
	bswapdi2.c bswapsi2.c clzdi2.c clzsi2.c clzti2.c cmpdi2.c cmpti2.c \
	comparedf2.c comparesf2.c ctzdi2.c ctzsi2.c ctzti2.c divdc3.c divdf3.c \
	divdi3.c divmoddi4.c divmodsi4.c divmodti4.c divsc3.c divsf3.c divsi3.c \
	divti3.c extendsfdf2.c extendhfsf2.c extendhfdf2.c ffsdi2.c ffssi2.c \
	ffsti2.c fixdfdi.c fixdfsi.c fixdfti.c fixsfdi.c fixsfsi.c fixsfti.c \
	fixunsdfdi.c fixunsdfsi.c fixunsdfti.c fixunssfdi.c fixunssfsi.c \
	fixunssfti.c floatdidf.c floatdisf.c floatsidf.c floatsisf.c \
	floattidf.c floattisf.c floatundidf.S floatundisf.S floatunsidf.c \
	floatunsisf.c floatuntidf.c floatuntisf.c fp_mode.c int_util.c \
	lshrdi3.c lshrti3.c moddi3.c modsi3.c modti3.c muldc3.c muldf3.c \
	muldi3.c mulodi4.c mulosi4.c muloti4.c mulsc3.c mulsf3.c multi3.c \
	mulvdi3.c mulvsi3.c mulvti3.c negdf2.c negdi2.c negsf2.c negti2.c \
	negvdi2.c negvsi2.c negvti2.c os_version_check.c paritydi2.c \
	paritysi2.c parityti2.c popcountdi2.c popcountsi2.c popcountti2.c \
	powidf2.c powisf2.c subdf3.c subsf3.c subvdi3.c subvsi3.c subvti3.c \
	trampoline_setup.c truncdfhf2.c truncdfsf2.c truncsfhf2.c ucmpdi2.c \
	ucmpti2.c udivdi3.c udivmoddi4.c udivmodsi4.c udivmodti4.c udivsi3.c \
	udivti3.c umoddi3.c umodsi3.c umodti3.c
# Hosted targets (not baremetal or GPU), unwind.h, not Fuchsia.
SRCS+=	emutls.c enable_execute_stack.c eprintf.c gcc_personality_v0.c \
	clear_cache.c
# GENERIC_TF_SOURCES (__float128)
SRCS+=	addtf3.c comparetf2.c divtc3.c divtf3.c extenddftf2.c extendhftf2.c \
	extendsftf2.c fixtfdi.c fixtfsi.c fixtfti.c fixunstfdi.c fixunstfsi.c \
	fixunstfti.c floatditf.c floatsitf.c floattitf.c floatunditf.c \
	floatunsitf.c floatuntitf.c multc3.c multf3.c powitf2.c subtf3.c \
	trunctfdf2.c trunctfhf2.c trunctfsf2.c
# BF16_SOURCES (clang has __bf16 on x86_64)
SRCS+=	extendbfsf2.c truncdfbf2.c truncxfbf2.c truncsfbf2.c trunctfbf2.c
# x86_ARCH_SOURCES
SRCS+=	x86.c
# x86_80_BIT_SOURCES (long double is the 80-bit x87 format)
SRCS+=	divxc3.c extendhfxf2.c extendxftf2.c fixxfdi.c fixxfti.c fixunsxfdi.c \
	fixunsxfsi.c fixunsxfti.c floatdixf.c floattixf.c floatundixf.S \
	floatuntixf.c mulxc3.c powixf2.c trunctfxf2.c truncxfhf2.c

# BUILTIN_CFLAGS and BUILTIN_DEFS of a standalone build.  _Float16 is
# passed in SSE registers: without COMPILER_RT_HAS_FLOAT16 the half
# precision functions would take it in integer registers instead.
# -fno-stack-protector is a requirement of the runtime, as for gcc's
# libgcc: __stack_chk_fail lives in libc, and these objects are also
# linked into code that has no libc (rtld before relocation, -nostdlib
# programs).
CFLAGS+=	-std=c11 -fPIC -fno-builtin -fvisibility=hidden \
		-fomit-frame-pointer -DVISIBILITY_HIDDEN \
		-DCOMPILER_RT_HAS_FLOAT16 -fno-stack-protector \
		-Werror=builtin-declaration-mismatch -Wno-c2y-extensions \
		-Wno-unknown-warning-option
CFLAGS+=	-I${CRTDIR}
WARNS=		0

CRTOBJS=	crtbegin.o crtend.o
# CRT_CFLAGS, without EH_USE_FRAME_REGISTRY (upstream's default on Linux).
# DragonFly's unwinder (gnu/lib/gcc80/libgcc_eh) finds the FDEs through
# dl_iterate_phdr and PT_GNU_EH_FRAME, as gcc's own crtstuff.c expects
# there (USE_PT_GNU_EH_FRAME): crtbegin need not register .eh_frame.  It
# also must not: shared libraries that link libgcc_eh statically each
# export a copy of __register_frame_info and __deregister_frame_info, and
# a registration made with one copy and undone with another aborted in
# __deregister_frame_info_bases at exit (libobjc2 from Gershwin).
CRT_CFLAGS=	-std=c11 -DCRT_HAS_INITFINI_ARRAY \
		-fPIC -Wno-pedantic -fno-stack-protector

.for _o in ${CRTOBJS}
${_o}: ${CRTDIR}/${_o:R}.c
	${CC} ${COPTFLAGS:U-O2} ${CRT_CFLAGS} -c ${.ALLSRC} -o ${.TARGET}
.endfor

# Every builtin is already PIC.
libgcc_pic.a: libgcc.a
	cp -f ${.ALLSRC} ${.TARGET}

all: ${CRTOBJS} libgcc_pic.a
CLEANFILES+=	${CRTOBJS} libgcc_pic.a

# crtbeginT.o is the static-link variant, crtbeginS.o and crtendS.o the
# shared/PIE ones: gcc builds them differently, compiler-rt does not.
afterinstall:
	${INSTALL} -o ${LIBOWN} -g ${LIBGRP} -m ${LIBMODE} libgcc_pic.a \
	    ${DESTDIR}${LIBDIR}/
.for _v in crtbegin.o crtbeginS.o crtbeginT.o
	${INSTALL} -o ${LIBOWN} -g ${LIBGRP} -m ${LIBMODE} crtbegin.o \
	    ${DESTDIR}${LIBDIR}/${_v}
.endfor
.for _v in crtend.o crtendS.o
	${INSTALL} -o ${LIBOWN} -g ${LIBGRP} -m ${LIBMODE} crtend.o \
	    ${DESTDIR}${LIBDIR}/${_v}
.endfor

.include <bsd.lib.mk>
