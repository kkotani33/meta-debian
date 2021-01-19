#
# debian-package.bbclass
#

# debian-source.bbclass will generate DEBIAN_SRC_URI information
# in recipes-debian/sources/<source name>.inc

DEBIAN_SRC_URI ?= ""
SRC_URI = "${DEBIAN_SRC_URI}"

DEBIAN_UNPACK_DIR ?= "${WORKDIR}/${BP}"
S = "${DEBIAN_UNPACK_DIR}"
DPV ?= "${PV}"
DEBIAN_USE_SNAPSHOT ?= "0"
DEBIAN_SDO_URL ?= "http://snapshot.debian.org"

# Most of files in Debian repo are in *.xz format.
# Remove dependency xz-native to avoid dependency loop.
python () {
    unpack_deps = d.getVarFlag('do_unpack', 'depends') or ""
    unpack_deps = unpack_deps.replace('xz-native:do_populate_sysroot','')
    d.setVarFlag('do_unpack', 'depends', unpack_deps)
}

###############################################################################
# do_debian_unpack_extra
###############################################################################

# Make "debian" sub folder be inside source code folder
addtask debian_unpack_extra after do_unpack before do_debian_patch
python do_debian_unpack_extra() {
    import shutil, subprocess
    workdir = d.getVar("WORKDIR")
    debian_unpack_dir = d.getVar("DEBIAN_UNPACK_DIR")
    BPN = d.getVar("BPN")
    DPV = d.getVar("DPV")
    if os.path.isdir(workdir + "/debian"):
        shutil.rmtree(debian_unpack_dir + "/debian", ignore_errors=True)
        shutil.move(workdir + "/debian", debian_unpack_dir)
    elif os.path.isfile(workdir + "/" + BPN + "_" + DPV + ".diff"):
        shutil.rmtree(debian_unpack_dir + "/debian", ignore_errors=True)
        os.chdir(debian_unpack_dir)
        subprocess.run("patch -p1 < {}/{}_{}.diff".format(workdir, BPN, DPV), shell=True)
}

EXPORT_FUNCTIONS do_debian_unpack_extra


###############################################################################
# do_debian_patch
###############################################################################

# Check Debian source format and then decide the action.
# The meanings of return values are the follows.
#   0: native package, there is no patch
#   1: 1.0 format or custom format, need to apply patches
#   3: 3.0 quilt format, need to apply patches by quilt
def debian_check_source_format(d):
    format_file = os.path.join(d.getVar("DEBIAN_UNPACK_DIR", True),"debian/source/format")
    if not os.path.isfile(format_file):
        bb.note("Debian source format is not defined, assume '1.0'")
        return 1
    with open(format_file, "r") as f:
        format_val = f.read().rstrip('\n')
    bb.note("Debian source format is '{}'".format(format_val))
    if format_val == "3.0 (native)":
        bb.note("nothing to do")
        return 0
    elif format_val == "3.0 (quilt)":
        return 3
    elif format_val in {"3.0", "2.0"}:
        # FIXME: no information about how to handle
        bb.fatal("unsupported source format")
    return 1

# Some 3.0 formatted source packages have no patch.
# Please set DEBIAN_QUILT_PATCHES = "" for such packages.
DEBIAN_QUILT_PATCHES ?= "${DEBIAN_UNPACK_DIR}/debian/patches"

DEBIAN_QUILT_DIR ?= "${DEBIAN_UNPACK_DIR}/.pc"
DEBIAN_QUILT_DIR_ESC ?= "${DEBIAN_UNPACK_DIR}/.pc.debian"

# apply patches by quilt
def debian_patch_quilt(d):
    # confirm that other patches didn't applied
    debian_quilt_dir = d.getVar("DEBIAN_QUILT_DIR", True)
    debian_quilt_dir_esc = d.getVar("DEBIAN_QUILT_DIR_ESC", True)
    if os.path.isdir(debian_quilt_dir) or os.path.isdir(debian_quilt_dir_esc):
        bb.fatal("unknown quilt patches already applied")

    # Some source packages don't have patch. In such cases,
    # users can intentionally ignore applying patches
    # by setting DEBIAN_QUILT_PATCHES to "".
    debian_quilt_patches = d.getVar("DEBIAN_QUILT_PATCHES", True)
    debian_unpack_dir = d.getVar("DEBIAN_UNPACK_DIR", True)
    debian_find_patches_dir = d.getVar("DEBIAN_FIND_PATCHES_DIR", True)
    if not debian_quilt_patches:
        if os.path.isfile(os.path.join(debian_unpack_dir,"debian/patches/series")) and os.path.getsize(os.path.join(debian_unpack_dir,"debian/patches/series")) > 0:
            bb.error("DEBIAN_QUILT_PATCHES is null, but {}/debian/patches/series exists".format(debian_unpack_dir))
            bb.fatal("Please consider to redefine DEBIAN_QUILT_PATCHES")
        found_patches = debian_find_patches(d)
        if found_patches:
            bb.error("DEBIAN_QUILT_PATCHES is null, but some patches found in {}".format(debian_find_patches_dir))
            bb.fatal("Please consider to redefine DEBIAN_QUILT_PATCHES")

        # no doubt, ignore applying patches
        bb.note("no debian patch exists in the source tree, nothing to do")
        return

    # Confirmations for the following quilt command
    debian_quilt_series = os.path.join(debian_quilt_patches, "series")
    if not os.path.isdir(debian_quilt_patches):
        bb.fatal("{} not found".format(debian_quilt_patches))
    elif not os.path.isfile(debian_quilt_series):
        bb.fatal("{} not found".format(debian_quilt_series))
    # In some limitted packages, series is empty or comments only
    # (too strange...). Need to expressly exit here because
    # quilt command raises an error if no patch is listed in the series.
    with open(debian_quilt_series, "r") as f:
        content = [line for line in f if not line.startswith("#") ]
    if not content:
        bb.note("no patch in series, nothing to do")
        return

    # apply patches
    import subprocess
    subprocess.run("QUILT_PATCHES={} quilt --quiltrc /dev/null push -a".format(debian_quilt_patches), shell=True)
    
    # avoid conflict with "do_patch"
    if os.path.isdir(debian_quilt_dir):
        import shutil
        shutil.move(debian_quilt_dir, debian_quilt_dir_esc)


DEBIAN_DPATCH_PATCHES ?= "${DEBIAN_UNPACK_DIR}/debian/patches"
# apply patches by dpatch
def debian_patch_dpatch(d):
    debian_dpatch_patches = d.getVar("DEBIAN_DPATCH_PATCHES", True)
    # Replace hardcode path in patch files
    for curdir, _, files in os.walk(debian_dpatch_patches):
        for fname in files:
            if os.path.splitext(fname)[1] == ".dpatch":
                file_path = os.path.join(curdir, fname)
                with open(file_path, "r") as f:
                    content = f.read()
                content = content.replace("#! /bin/sh /usr/share/dpatch/dpatch-run",
                                        "#! /usr/bin/env dpatch-run")
                with open(file_path, "w") as f:
                    f.write(content)
    
    os.environ["PATH"] = "{}:{}".format(os.getenv("PATH"), d.getVar("STAGING_DATADIR_NATIVE") + "/debian")
    import subprocess
    subprocess.run(["dpatch", "apply-all"])


DEBIAN_FIND_PATCHES_DIR ?= "${DEBIAN_UNPACK_DIR}/debian"

def debian_find_patches(d):
    debian_find_patches_dir = d.getVar("DEBIAN_FIND_PATCHES_DIR")
    patch_list = []
    for curdir, _, files in os.walk(debian_find_patches_dir):
        for fname in files:
            ext = os.path.splitext(fname)[1]
            if ext == ".patch" or ext == ".dpatch":
                patch_list.append(os.path.join(curdir, fname))
    return patch_list


# used only when DEBIAN_PATCH_TYPE is "abnormal"
# this is very rare case; should not be used except
# the cases that all other types cannot be used
# this function must be overwritten by each recipe
def debian_patch_abnormal():
    bb.fatal("debian_patch_abnormal not defined")


# decide an action to apply patches for the source package
# candidates: quilt, dpatch, nopatch, abnormal
DEBIAN_PATCH_TYPE ?= ""

addtask debian_patch after do_unpack before do_patch
do_debian_patch[dirs] = "${DEBIAN_UNPACK_DIR}"
do_debian_patch[depends] += "${@oe.utils.conditional(\
    'PN', 'quilt-native', '', 'quilt-native:do_populate_sysroot', d)}"
do_debian_patch[depends] += "${@oe.utils.conditional(\
    'DEBIAN_PATCH_TYPE', 'dpatch', 'dpatch-native:do_populate_sysroot', '', d)}"
python do_debian_patch() {
    bb.plain("{}: run debian_patch".format(d.getVar("BPN")))
    format = debian_check_source_format(d)
    if format == 0:
        return 0
    # apply patches according to the source format
    debian_patch_type = d.getVar("DEBIAN_PATCH_TYPE", True)
    if format == 1:
        # DEBIAN_PATCH_TYPE must be set manually to decide
        # an action when Debian source format is not 3.0
        if not debian_patch_type:
            bb.fatal("DEBIAN_PATCH_TYPE not set")

        bb.note("DEBIAN_PATCH_TYPE: {}".format(debian_patch_type))
        if debian_patch_type == "quilt":
            debian_patch_quilt(d)
        elif debian_patch_type == "dpatch":
            debian_patch_dpatch(d)
        elif debian_patch_type == "nopatch":
            # No patch and no function to apply patches in
            # some source packages. In such cases, confirm
            # that really no patch-related file is included
            found_patches = debian_find_patches(d)
            if found_patches:
                bb.error("the following patches found:")
                for patch in found_patches:
                    bb.error(patch)
                bb.fatal("please re-consider DEBIAN_PATCH_TYPE")
        elif debian_patch_type == "abnormal":
            debian_patch_abnormal()
        else:
            bb.fatal("invalid DEBIAN_PATCH_TYPE: {}".format(debian_patch_type))
    elif format == 3:
        debian_patch_quilt(d)
}
EXPORT_FUNCTIONS do_debian_patch


python () {
    import json, os, re

    # get json data from snapshot.d.o
    def _get_sdo_json_data(path):
        import urllib.request

        base_url = d.getVar("DEBIAN_SDO_URL", True)
        try:
            readobj = urllib.request.urlopen(base_url + path)
        except urllib.error.URLError as e:
            bb.fatal('Can not access to %s' % base_url + path)
            print(e.reason)
        else:
            return readobj.read()

    # get json data from snapshot.d.o or files
    def _get_sdo_json (api_path, json_path):
        if os.path.exists(json_path):
            with open(json_path) as f:
                return f.read()
        else:
            _data = _get_sdo_json_data(api_path)
            if _data is not None:
                with open(json_path, mode = 'w') as f:
                    data = _data.decode('utf-8')
                    f.write(data)
                    return data

    # get json data of source files
    def _get_sdo_json_srcfiles (dl_dir, pkgname, pkgver):
        api_path = os.path.join('/mr/package/', pkgname, pkgver, 'srcfiles')
        json_path = os.path.join(dl_dir, pkgname + '_' + pkgver + '_srcfiles.json')

        return _get_sdo_json(api_path, json_path)

    # get json data of pkg info
    def _get_sdo_json_pkginfo (dl_dir, filehash, pkgname, pkgver):
        api_path = os.path.join('/mr/file/', filehash, 'info')
        json_path = os.path.join(dl_dir, pkgname + '_' + pkgver + '_' + filehash +'_info.json')

        return _get_sdo_json(api_path, json_path)

    def _get_sdo_spkgdata (pkgname, filename, fileinfo):
        jsondata = json.loads(fileinfo)

        # result data check
        results = jsondata['result']
        if results is None:
            return

        for i in range(len(results)):
            name = results[i]['name']
            archive_name = results[i]['archive_name']

            # compare file names
            if name == filename:
                p = name.split('_')
                if p[0] in pkgname:
                    archive_path = results[i]['path']
                    first_seen = results[i]['first_seen']

                    return name, archive_path, first_seen, archive_name

    if d.getVar("DEBIAN_USE_SNAPSHOT", True) == "0":
        return

    # check DEBIAN_SRC_URI
    debian_src_uri_orig = d.getVar('DEBIAN_SRC_URI', True).split()
    if len(debian_src_uri_orig) == 0:
        bb.bbfatal('There is no data for DEBIAN_SRC_URI.')
        return

    pkgname = ""
    # Get source package name from original source uri (DEBIAN_SRC_URI)
    for _pkg_uri in debian_src_uri_orig:
        if ".dsc" in _pkg_uri:
            _pkg_file_name = os.path.basename(_pkg_uri)
            pkgname = _pkg_file_name.split(";")[0].split("_")[0]
            break

    if len(pkgname) == 0:
        bb.bbfatal('There is no Debian source package name.')
        return

    pkgver = d.getVar("DPV", True)
    if pkgver is None:
        pkgver = d.getVar("PV", True)
    # get epoch
    pkgepoch = d.getVar("DPV_EPOCH", True)
    if pkgepoch != '':
        pkgver = pkgepoch + ':' + pkgver

    dl_dir = d.getVar('DL_DIR', True)

    # check and create DL_DIR
    if os.path.exists(dl_dir) is not True:
        os.makedirs(dl_dir)

    # get src files from json
    srcfiles = _get_sdo_json_srcfiles(dl_dir, pkgname, pkgver)
    if srcfiles is None:
        return

    jsondata = json.loads(srcfiles)

    # check src package name
    if jsondata['package'] not in pkgname:
        return

    # check src package version
    if jsondata['version'] not in pkgver:
        return

    # check result data
    results = jsondata['result']
    if results is None:
        return

    debfile_urls = ''

    for i in range(len(results)):
        prevent_apply = ""
        filehash = results[i]['hash']
        pkginfo = _get_sdo_json_pkginfo(dl_dir, filehash, pkgname, pkgver)
        if pkginfo is None:
            continue

        for _uri in debian_src_uri_orig:
            # get filename from DEBIAN_SRC_URI
            _match_data = re.search(r"^.*/(\S.*);name=\S.*$", _uri)
            if _match_data:
                # get package infomation form json
                info = _get_sdo_spkgdata(pkgname, _match_data.group(1), pkginfo)
                if info:
                    break
            else:
                continue

        if info is None:
            continue

        base_url = d.getVar("DEBIAN_SDO_URL", True)
        u = "%s/archive/%s/%s/%s" % (base_url, info[3], info[2], info[1])
        if ".diff" in info[0] or ".patch" in info[0]:
            prevent_apply = ";apply=no"
        nametag = info[0].replace('~', '_')
        debfile_urls += '%s/%s;name=%s%s ' % (u, info[0], nametag, prevent_apply)

    if not debfile_urls:
        bb.bbfatal('Can not get URI of debian source packages.')
        return None

    # overwrite DEBIAN_SRC_URI
    d.setVar('DEBIAN_SRC_URI', debfile_urls)
}
