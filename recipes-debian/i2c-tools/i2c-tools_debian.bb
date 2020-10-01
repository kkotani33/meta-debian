#
# base recipe: meta/recipes-devtools/i2c-tools/i2c-tools_3.1.2.bb
# base branch: jethro
#
SUMMARY = "heterogeneous set of I2C tools for Linux"
DESCRIPTION = "\
	This package contains a heterogeneous set of I2C tools for Linux: a bus \
	probing tool, a chip dumper, register-level access helpers, EEPROM \
	decoding scripts, and more. \
"
HOMEPAGE = "http://www.lm-sensors.org"

PR = "r1"
inherit debian-package pythonnative
PV = "3.1.1"

LICENSE = "GPLv2+"
LIC_FILES_CHKSUM = "\
	file://COPYING;md5=751419260aa954499f7abaabaa882bbe"
inherit autotools-brokensep
DEPENDS += "python"

#export some variable from poky, to use for python command
export STAGING_INCDIR
export STAGING_LIBDIR
export DEB_HOST_MULTIARCH
export LDSHARED="${CCLD} -shared"

do_compile_append() {
	#follow debian/rules
	cd py-smbus && \
		CFLAGS="${CFLAGS} ${HOST_CC_ARCH} -I../include" \
		${STAGING_BINDIR_NATIVE}/${PYTHON_PN}-native/${PYTHON_PN} setup.py build
}

#include/linux/i2c-dev.h file conflict with linux-libc-headers-base
#solve this follow base recipe
do_install() {
	oe_runmake install DESTDIR=${D} prefix=${prefix} sbindir=${sbindir}
	install -d ${D}${includedir}/linux

	install -m 0644 include/linux/i2c-dev.h ${D}${includedir}/linux/i2c-dev-user.h
	rm -f ${D}${includedir}/linux/i2c-dev.h

	#follow debian/rules
	cd py-smbus && \
		CFLAGS="${CFLAGS} -I../include" \
		${STAGING_BINDIR_NATIVE}/${PYTHON_PN}-native/${PYTHON_PN} setup.py install \
		--install-layout=deb --install-lib=${D}/${PYTHON_SITEPACKAGES_DIR}

	install -D -m 0644 ${S}/debian/i2c-tools.udev \
		${D}${nonarch_base_libdir}/udev/rules.d/60-i2c-tools.rules
}

PACKAGES += "python-smbus"

FILES_${PN}-dbg += "${PYTHON_SITEPACKAGES_DIR}/.debug/*"
FILES_python-smbus = "${PYTHON_SITEPACKAGES_DIR}/*"
PKG_${PN}-dev = "libi2c-dev"

BBCLASSEXTEND = "nativesdk"