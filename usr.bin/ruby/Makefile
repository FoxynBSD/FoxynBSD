# Ruby (contrib/ruby), built with its own configure and makefiles: they
# generate a good part of the interpreter (the encodings, rbconfig, the
# extensions' makefiles), and the extensions are configured by running
# Ruby (mkmf).  This makefile drives them from the object directory like
# a bsd.prog.mk directory: all, install, clean, obj, depend.
#
# The extensions link the base's private libraries, which Ruby's
# extconf.rb files look for under their public names: ${.OBJDIR}/deps
# gives them libcrypto, libssl and libyaml (links to libprivate_crypto,
# libprivate_ssl, libprivate_yaml) and their headers.  The programs then
# need libprivate_*.so at run time, as every user of them.
#
# A release has the files that Ruby's tools generate (parse.c, id.h,
# insns.inc, ...), newer than what they are made from.  A git checkout
# gives every file the time of the checkout, in no particular order, and
# make would regenerate some of them in the source tree; so all the
# files get one time before configure (only their times change).
#
# --without-git: contrib/ruby is a release, not a Ruby checkout.  With
# git, the build would fetch the bundled gems' sources into the source
# tree (gems/src); the release has them as .gem files.
#
# RUBY_CONFIGURE_ARGS adds configure options: a cross build passes
# --host, --build and --with-baseruby (tools/linux/build.sh does).
#
# RUBY_BUILTIN_BINARY: a cross build cannot run the miniruby it builds,
# so Ruby's configure leaves out the precompiled core library
# (builtin_binary.rbbin), and the interpreter then works as miniruby
# does: it compiles that code at every start and loads no RubyGems.  The
# file from a native build of the same Ruby on a host with the same word
# size and byte order is the same (the format records only those and
# the version); a cross build names it here and it is used instead.

RUBY_SRC=	${.CURDIR:H:H:tA}/contrib/ruby
DEPS=		${.OBJDIR}/deps
SYSROOTDIR=	${_SHLIBDIRPREFIX}

RUBY_CONFIGURE=	--prefix=/usr --sysconfdir=/etc --localstatedir=/var \
		--mandir=/usr/share/man --enable-shared --disable-rpath \
		--disable-install-doc --disable-yjit --disable-zjit \
		--without-gmp --with-out-ext=fiddle --without-git \
		--with-openssl-dir=${DEPS} --with-libyaml-dir=${DEPS} \
		--disable-close-fds-by-recvmsg-with-peek \
		${RUBY_CONFIGURE_ARGS}

# Ruby sets its own optimisation and warning flags.
RUBY_ENV=	CC="${CC}" CXX="${CXX}" CPPFLAGS="-I${DEPS}/include" \
		LDFLAGS="-L${DEPS}/lib" optflags=-O2 debugflags=

all: ${.OBJDIR}/.ruby_built

${DEPS}/.done:
	rm -rf ${DEPS}
	mkdir -p ${DEPS}/lib ${DEPS}/include
	ln -sf ${SYSROOTDIR}/usr/include/priv/openssl ${DEPS}/include/openssl
	ln -sf ${SYSROOTDIR}/usr/include/priv/yaml.h ${DEPS}/include/yaml.h
.for l in crypto ssl yaml
	ln -sf ${SYSROOTDIR}/usr/lib/priv/libprivate_${l}.so ${DEPS}/lib/lib${l}.so
.endfor
	touch ${.TARGET}

${.OBJDIR}/config.status: ${DEPS}/.done
	find ${RUBY_SRC} -exec touch -h -r ${RUBY_SRC}/version.h {} +
	cd ${.OBJDIR} && env ${RUBY_ENV} ${RUBY_SRC}/configure ${RUBY_CONFIGURE}
.if defined(RUBY_BUILTIN_BINARY) && !empty(RUBY_BUILTIN_BINARY)
	cp ${RUBY_BUILTIN_BINARY} ${.OBJDIR}/builtin_binary.rbbin
.endif

${.OBJDIR}/.ruby_built: ${.OBJDIR}/config.status
	cd ${.OBJDIR} && ${MAKE} -f Makefile all
	touch ${.TARGET}

# rbconfig.rb records how Ruby was built, and on the installed system mkmf
# builds the gems' extensions with it.  So the installed one names the
# system's compilers, install(1) and mkdir(1), not the build's, and not
# ${DEPS}.  RUBY_RBCONFIG_DROP: flags that configure found the build's
# compiler takes and the system's cc does not (a cross build with clang
# sets it: cc is gcc).
RUBY_RBCONFIG_CC?=	cc
RUBY_RBCONFIG_CXX?=	c++
RUBY_RBCONFIG_DROP?=
RBCONFIG_SED=	-e 's| -[IL]${DEPS}/[a-z]*||g' \
		-e 's|"-[IL]${DEPS}/[a-z]* *|"|g' \
		-e 's|^\(  CONFIG\["CC"\] = \).*|\1"${RUBY_RBCONFIG_CC}"|' \
		-e 's|^\(  CONFIG\["CXX"\] = \).*|\1"${RUBY_RBCONFIG_CXX}"|' \
		-e 's|^\(  CONFIG\["INSTALL"\] = \).*|\1'"'"'/usr/bin/install -c'"'"'|' \
		-e 's|^\(  CONFIG\["MKDIR_P"\] = \).*|\1"/bin/mkdir -p"|' \
		-e 's|^\(  CONFIG\["MAKEDIRS"\] = \).*|\1"/bin/mkdir -p"|'
.for f in ${RUBY_RBCONFIG_DROP}
RBCONFIG_SED+=	-e 's|\([" ]\)${f}\([" ]\)|\1\2|g'
.endfor

install: ${.OBJDIR}/.ruby_built
	cd ${.OBJDIR} && ${MAKE} -f Makefile install-nodoc DESTDIR=${DESTDIR}
	for f in ${DESTDIR}/usr/lib/ruby/[0-9]*/*/rbconfig.rb; do \
		sed ${RBCONFIG_SED} "$$f" > "$$f.new" && mv "$$f.new" "$$f"; \
	done

clean cleandir:
	rm -rf ${.OBJDIR}/*

depend:

.include <bsd.obj.mk>
