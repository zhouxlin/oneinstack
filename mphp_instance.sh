#!/bin/bash
# Author: temporary helper (not part of upstream OneinStack)
# BLOG:  https://linuxeye.com
#
# Notes: Compile an extra PHP-FPM instance into its own directory without running
#        install.sh. It reuses include/php-X.X.sh, so the configure options are
#        identical to the normal installer. Use it when the regular flow cannot
#        help, e.g. a 3rd copy of the same version, a custom suffix, or a rebuild
#        after an interrupted install.
#
# Usage:
#   ./mphp_instance.sh --ver 74                  # /usr/local/php74   (same as install.sh --mphp_ver 74)
#   ./mphp_instance.sh --ver 74 --name b         # /usr/local/php74b
#   ./mphp_instance.sh 74 b                      # same as above
#   ./mphp_instance.sh --ver 74 --name b --no-opcache
#
# Result:
#   PATH    /usr/local/php74b
#   service php74b-fpm
#   socket  /dev/shm/php74b-cgi.sock
#
# Delete this file when you no longer need it.

export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

# PHP's Makefile link rule references $(ZEND_EXTRA_LIBS) and make imports it from the
# environment. Some older include/php-x.x.sh forget to pass it, which then fails at the
# final link with "undefined reference to libiconv_*" when PHP uses a standalone libiconv.
iconv_libdir=''
for d in /usr/local/lib /usr/local/lib64 /usr/lib64 /usr/lib; do
  if [ -e "${d}/libiconv.la" ] || [ -e "${d}/libiconv.so" ] || [ -e "${d}/libiconv.a" ]; then
    iconv_libdir=${d}
    break
  fi
done
if [ -n "${iconv_libdir}" ]; then
  export ZEND_EXTRA_LIBS="-L${iconv_libdir} -liconv"
fi

set -o pipefail

oneinstack_dir=$(dirname "`readlink -f $0`")
self=$(readlink -f "$0")
pushd ${oneinstack_dir} > /dev/null

. ./versions.txt
. ./options.conf
. ./include/color.sh

###############################################################################
# child mode: source the per-version build function and compile only.
# It runs in its own bash process, so a `kill -9 $$` from a failed build cannot
# take down the parent (which still has to restore the default PHP unit).
###############################################################################
if [ "${1:-}" == '--build-only' ]; then
  [ $(id -u) != "0" ] && { echo "Error: You must be root to run this script"; exit 1; }
  ver=$2
  name=$3
  phpcache_option=${4:-1}

  . ./include/check_os.sh
  . ./include/download.sh
  . ./include/openssl.sh
  . ./include/memory.sh

  mphp_ver=${ver}
  mphp_name=${name}
  php_option=
  apache_mode_option=
  php_install_dir=${php_install_dir}${mphp_ver}${mphp_name}

  # older include/php-x.x.sh may fail to pushd into src/ on some trees; start there so
  # tar/configure/patch still work even if that pushd fails
  cd "${oneinstack_dir}/src" || { echo "Error: ${oneinstack_dir}/src not found"; exit 1; }

  . "${oneinstack_dir}/include/php-${ver:0:1}.${ver:1:1}.sh"
  Install_PHP${mphp_ver}
  exit $?
fi

Show_Help() {
  echo "Usage: $0 --ver [53~85] [--name name] [--extensions list] [--no-opcache] [--base-dir dir]"
  echo "  --ver,  -v [53~85]   PHP version code, e.g. 74 for PHP 7.4"
  echo "  --name, -n [name]    instance suffix, e.g. b => ${php_install_dir}74b"
  echo "                       (default: no suffix, same as install.sh --mphp_ver)"
  echo "  --extensions, -e     extra PHP extensions to build into the instance,"
  echo "                       comma or space separated, same names as install.sh"
  echo "                       --php_extensions: fileinfo,ldap,redis,zstd,..."
  echo "  --base-dir, -b       existing php-fpm prefix (auto-detected by default);"
  echo "                       it is only used to preserve its systemd unit"
  echo "  --no-opcache         build without opcache (default: opcache enabled)"
  echo "  --help, -h           show this help"
  echo
  echo "Examples:"
  echo "  $0 --ver 74 --name b        # 2nd 7.4 => ${php_install_dir}74b + php74b-fpm"
  echo "  $0 74 c                     # 3rd 7.4 => ${php_install_dir}74c + php74c-fpm"
  echo "  $0 --ver 74 --name b --no-opcache --extensions fileinfo,ldap"
  echo "                              # exact same module set as a default-instance build"
  echo "  $0 --ver 74 --name b --base-dir /www/server/php/74"
  echo "                              # PHP installed outside ${php_install_dir}"
}

ver=''
name=''
extensions=''
base_dir=''
phpcache_option=1

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      Show_Help
      exit 0
      ;;
    --ver | -v)
      ver=$2
      shift 2
      ;;
    --name | -n)
      name=$2
      shift 2
      ;;
    --extensions | -e)
      extensions=$2
      shift 2
      ;;
    --base-dir | -b)
      base_dir=$2
      shift 2
      ;;
    --no-opcache)
      phpcache_option=0
      shift 1
      ;;
    -*)
      echo "${CWARNING}ERROR: unknown argument: $1${CEND}"
      Show_Help
      exit 1
      ;;
    *)
      if [ -z "${ver}" ]; then
        ver=$1
      elif [ -z "${name}" ]; then
        name=$1
      fi
      shift 1
      ;;
  esac
done

[ -z "${ver}" ] && { echo "${CWARNING}ERROR: --ver is required${CEND}"; Show_Help; exit 1; }
[[ ! "${ver}" =~ ^5[3-6]$|^7[0-4]$|^8[0-5]$ ]] && { echo "${CWARNING}ERROR: ver only supports 53~85${CEND}"; exit 1; }
if [ -n "${name}" ]; then
  [[ ! "${name}" =~ ^[A-Za-z][A-Za-z0-9_]{0,15}$ ]] && {
    echo "${CWARNING}ERROR: name must start with a letter, only letters/numbers/underscore, max 16 chars${CEND}"
    exit 1
  }
fi

# extra PHP extensions (same names as install.sh --php_extensions)
extensions=$(echo "${extensions}" | tr ',' ' ')
for ext in ${extensions}; do
  case "${ext}" in
    zendguardloader) ext_sh=ZendGuardLoader.sh ;;
    ioncube) ext_sh=ioncube.sh ;;
    sourceguardian) ext_sh=sourceguardian.sh ;;
    imagick) ext_sh=ImageMagick.sh ;;
    gmagick) ext_sh=GraphicsMagick.sh ;;
    fileinfo) ext_sh=pecl_fileinfo.sh ;;
    imap) ext_sh=pecl_imap.sh ;;
    ldap) ext_sh=pecl_ldap.sh ;;
    calendar) ext_sh=pecl_calendar.sh ;;
    phalcon) ext_sh=pecl_phalcon.sh ;;
    yaf) ext_sh=pecl_yaf.sh ;;
    yar) ext_sh=pecl_yar.sh ;;
    redis) ext_sh=redis.sh ;;
    memcached | memcache) ext_sh=memcached.sh ;;
    mongodb) ext_sh=pecl_mongodb.sh ;;
    swoole) ext_sh=pecl_swoole.sh ;;
    xdebug) ext_sh=pecl_xdebug.sh ;;
    xlswriter) ext_sh=pecl_xlswriter.sh ;;
    grpc) ext_sh=pecl_grpc.sh ;;
    igbinary) ext_sh=pecl_igbinary.sh ;;
    msgpack) ext_sh=pecl_msgpack.sh ;;
    zstd) ext_sh=pecl_zstd.sh ;;
    *) echo "${CWARNING}ERROR: unsupported extension: ${ext}${CEND}"; exit 1 ;;
  esac
  [ -f "${oneinstack_dir}/include/${ext_sh}" ] || {
    echo "${CFAILURE}Error: include/${ext_sh} not found, this tree does not support --extensions ${ext}${CEND}"
    exit 1
  }
done
php_extensions="${extensions}"
[ -n "$(echo ${php_extensions} | grep -w zendguardloader)" ] && pecl_zendguardloader=1
[ -n "$(echo ${php_extensions} | grep -w ioncube)" ] && pecl_ioncube=1
[ -n "$(echo ${php_extensions} | grep -w sourceguardian)" ] && pecl_sourceguardian=1
[ -n "$(echo ${php_extensions} | grep -w imagick)" ] && pecl_imagick=1
[ -n "$(echo ${php_extensions} | grep -w gmagick)" ] && pecl_gmagick=1
[ -n "$(echo ${php_extensions} | grep -w fileinfo)" ] && pecl_fileinfo=1
[ -n "$(echo ${php_extensions} | grep -w imap)" ] && pecl_imap=1
[ -n "$(echo ${php_extensions} | grep -w ldap)" ] && pecl_ldap=1
[ -n "$(echo ${php_extensions} | grep -w calendar)" ] && pecl_calendar=1
[ -n "$(echo ${php_extensions} | grep -w phalcon)" ] && pecl_phalcon=1
[ -n "$(echo ${php_extensions} | grep -w yaf)" ] && pecl_yaf=1
[ -n "$(echo ${php_extensions} | grep -w yar)" ] && pecl_yar=1
[ -n "$(echo ${php_extensions} | grep -w redis)" ] && pecl_redis=1
[ -n "$(echo ${php_extensions} | grep -w memcached)" ] && pecl_memcached=1
[ -n "$(echo ${php_extensions} | grep -w memcache)" ] && pecl_memcache=1
[ -n "$(echo ${php_extensions} | grep -w mongodb)" ] && pecl_mongodb=1
[ -n "$(echo ${php_extensions} | grep -w swoole)" ] && pecl_swoole=1
[ -n "$(echo ${php_extensions} | grep -w xdebug)" ] && pecl_xdebug=1
[ -n "$(echo ${php_extensions} | grep -w xlswriter)" ] && pecl_xlswriter=1
[ -n "$(echo ${php_extensions} | grep -w grpc)" ] && pecl_grpc=1
[ -n "$(echo ${php_extensions} | grep -w igbinary)" ] && pecl_igbinary=1
[ -n "$(echo ${php_extensions} | grep -w msgpack)" ] && pecl_msgpack=1
[ -n "$(echo ${php_extensions} | grep -w zstd)" ] && pecl_zstd=1

# Check if user is root
[ $(id -u) != "0" ] && { echo "${CFAILURE}Error: You must be root to run this script${CEND}"; exit 1; }

mphp_ver=${ver}
mphp_name=${name}
mphp_inst=${mphp_ver}${mphp_name}
php_default_install_dir=${php_install_dir}
mphp_install_dir=${php_default_install_dir}${mphp_inst}

# locate the already installed php-fpm (if any). It is only needed to preserve its
# systemd unit while the build temporarily borrows php-fpm.service, so a missing
# default instance is not a hard error.
base_php_dir=''
if [ -n "${base_dir}" ]; then
  if [ -x "${base_dir}/sbin/php-fpm" ]; then
    base_php_dir=${base_dir}
  else
    echo "${CFAILURE}Error: ${base_dir}/sbin/php-fpm not found.${CEND}"
    exit 1
  fi
else
  for d in "${php_default_install_dir}" /usr/local/php /usr/local/php[0-9]*; do
    [ -x "${d}/sbin/php-fpm" ] && { base_php_dir=${d}; break; }
  done
fi

[ -e "${mphp_install_dir}/bin/phpize" ] && {
  echo "${CFAILURE}Error: ${mphp_install_dir} already exists.${CEND}"
  echo "${CWARNING}Use another --name, or remove it with: ./uninstall.sh --mphp_ver ${mphp_ver}${mphp_name:+ --mphp_name ${mphp_name}}${CEND}"
  exit 1
}

if [ -n "${base_php_dir}" ]; then
  echo "${CMSG}Existing php-fpm: ${base_php_dir}${CEND}"
else
  echo "${CWARNING}Warning: no existing php-fpm found (${php_default_install_dir}/sbin/php-fpm).${CEND}"
  echo "${CWARNING}         Continuing in standalone mode: PHP${mphp_inst} is self-contained.${CEND}"
fi

# make sure this OneinStack tree really ships a build function for the requested version
php_include="${oneinstack_dir}/include/php-${ver:0:1}.${ver:1:1}.sh"
if [ ! -f "${php_include}" ]; then
  echo "${CFAILURE}Error: ${php_include} not found.${CEND}"
  echo "${CWARNING}This tree has no build script for PHP ${ver}, update include/ (and versions.txt) first.${CEND}"
  exit 1
fi

. ./include/check_os.sh
. ./include/download.sh
. ./include/get_char.sh
. ./include/openssl.sh
. ./include/memory.sh
. ./include/check_download.sh

# CentOS 7 / RHEL 7 is EOL: check_os.sh already repoints yum at vault.centos.org,
# but extension builds (openldap-devel etc.) still need working yum repos
if [ "${Family}" == 'rhel' ] && [ "${RHEL_ver}" == '7' ]; then
  if ! yum -q repolist > /dev/null 2>&1; then
    echo "${CWARNING}Warning: 'yum repolist' failed. CentOS 7 is EOL, fix the vault repos first,${CEND}"
    echo "${CWARNING}         otherwise extensions that need devel packages (e.g. ldap) will fail.${CEND}"
  fi
fi

# build tools used by the PHP / extension builds
missing=''
for cmd in gcc make patch tar gzip bzip2 xz wget curl; do
  command -v ${cmd} > /dev/null 2>&1 || missing="${missing} ${cmd}"
done
if [ -n "${missing}" ]; then
  echo "${CFAILURE}Error: missing build tools:${missing}${CEND}"
  [ "${PM}" == 'yum' ] && echo "${CWARNING}yum -y install gcc gcc-c++ make patch tar gzip bzip2 xz wget curl${CEND}"
  exit 1
fi

# libzip >= 1.10 needs CMake >= 3.14; CentOS 7 ships 2.8 and the build function
# only knows about /usr/bin/cmake3 (EPEL), so fail fast instead of at configure time
if [ ! -e "/usr/local/lib/libzip.la" ] && [ ! -e "/usr/local/lib/libzip.so" ]; then
  if [ ! -e /usr/bin/cmake3 ] && ! cmake --version 2>/dev/null | head -n1 | grep -qE 'version (3\.(1[4-9]|[2-9][0-9])|[4-9]\.)'; then
    echo "${CFAILURE}Error: libzip needs CMake >= 3.14, but: $(cmake --version 2>/dev/null | head -n1 || echo 'cmake not installed')${CEND}"
    [ "${PM}" == 'yum' ] && echo "${CWARNING}yum -y install cmake3   # then re-run this script${CEND}"
    exit 1
  fi
fi

# get the build dependencies (PHP tarball, patches, libs) the same way install.sh does
export oneinstack_dir
src_dir=${oneinstack_dir}/src
[ ! -d "${src_dir}" ] && mkdir -p "${src_dir}"
# some (older) include/check_download.sh pushd "${oneinstack_dir}/src" themselves and
# break when oneinstack_dir is not visible; run from src/ so downloads still land there
cd "${src_dir}"

# Pre-fetch the PHP tarball. CentOS 7's wget (OpenSSL 1.0.2) cannot complete the TLS
# handshake with secure.php.net/php.net, so try curl and the OneinStack mirror first.
php_ver_var="php${mphp_ver}_ver"
php_detail_ver=${!php_ver_var}
php_tar="php-${php_detail_ver}.tar.gz"
Fetch_src() {
  local file=$1
  shift
  local url
  [ -s "${src_dir}/${file}" ] && return 0
  for url in "$@"; do
    [ -z "${url}" ] && continue
    echo "${CMSG}Downloading ${file} from ${url}${CEND}"
    if command -v curl > /dev/null 2>&1; then
      curl -fsSLk --connect-timeout 15 --retry 2 -o "${src_dir}/${file}" "${url}" && [ -s "${src_dir}/${file}" ] && return 0
    fi
    if command -v wget > /dev/null 2>&1; then
      wget -q --no-check-certificate --secure-protocol=TLSv1_2 -t 2 -T 30 -O "${src_dir}/${file}" "${url}" && [ -s "${src_dir}/${file}" ] && return 0
    fi
    rm -f "${src_dir}/${file}"
  done
  return 1
}

if ! Fetch_src "${php_tar}" "${mirror_link}/oneinstack/src/${php_tar}" "https://www.php.net/distributions/${php_tar}" "https://museum.php.net/php5/${php_tar}"; then
  echo "${CFAILURE}Error: cannot download ${php_tar}${CEND}"
  echo "${CWARNING}Download it manually into ${src_dir}/ and re-run this script.${CEND}"
  exit 1
fi
if ! gzip -t "${src_dir}/${php_tar}" > /dev/null 2>&1; then
  echo "${CFAILURE}Error: ${src_dir}/${php_tar} is corrupted, delete it and re-run.${CEND}"
  rm -f "${src_dir}/${php_tar}"
  exit 1
fi

# optional CVE patch for this version. Older include/php-7.x.sh looks for it without
# the "php-" prefix, so keep both names around (same content)
cve_patch=''
case "${mphp_ver}" in
  74) cve_patch=php-7.4-CVE-2026-109618-109619.patch ;;
  81) cve_patch=php-8.1-CVE-2026-109618-109619.patch ;;
esac
if [ -n "${cve_patch}" ]; then
  Fetch_src "${cve_patch}" "${mirror_link}/oneinstack/src/${cve_patch}" || true
  cve_alt=${cve_patch#php-}
  if [ -s "${src_dir}/${cve_patch}" ] && [ ! -e "${src_dir}/${cve_alt}" ]; then
    cp -f "${src_dir}/${cve_patch}" "${src_dir}/${cve_alt}"
  fi
fi

echo "${CMSG}Checking source packages for PHP${mphp_inst}...${CEND}"
checkDownload 2>&1 | tee -a ${oneinstack_dir}/mphp_install.log
[ "${PIPESTATUS[0]}" -ne 0 ] && { echo "${CFAILURE}Download failed, see ${oneinstack_dir}/mphp_install.log${CEND}"; exit 1; }
cd "${oneinstack_dir}"

# a failed download can leave an HTML file named *.patch; `patch -p1 < ...` would then
# silently skip the fix, so validate the patches for this version before building
php_series="${ver:0:1}.${ver:1:1}"
for pf in ${oneinstack_dir}/src/php-${php_series}-*.patch ${oneinstack_dir}/src/${php_series}-*.patch; do
  [ -e "${pf}" ] || continue
  grep -qE '^(diff |--- )' "${pf}" || {
    echo "${CFAILURE}Error: ${pf##*/} is not a valid patch (broken download).${CEND}"
    echo "${CWARNING}Remove it and re-run: rm -f ${pf}${CEND}"
    exit 1
  }
done

# PHP 8.4/8.5 link against a private OpenSSL, build it when it is missing
openssl_arg_var="php${mphp_ver}_with_openssl"
openssl_arg=${!openssl_arg_var}
if [[ "${openssl_arg}" == *"${openssl_install_dir}"* ]] && [ ! -x "${openssl_install_dir}/bin/openssl" ]; then
  echo "${CMSG}Building openSSL for PHP${mphp_inst}...${CEND}"
  cd "${src_dir}"
  Install_openSSL 2>&1 | tee -a ${oneinstack_dir}/mphp_install.log
  cd "${oneinstack_dir}"
fi

# the build function always writes /lib/systemd/system/php-fpm.service, so park the
# default instance unit first; it is restored by restore_default_unit no matter what
base_unit_was_present=''
if [ -e "/lib/systemd/system/php-fpm.service" ]; then
  /bin/mv /lib/systemd/system/php-fpm.service{,_bk}
  base_unit_was_present=y
fi

restore_default_unit() {
  if [ -e "/lib/systemd/system/php-fpm.service_bk" ]; then
    rm -f /lib/systemd/system/php-fpm.service
    /bin/mv -f /lib/systemd/system/php-fpm.service_bk /lib/systemd/system/php-fpm.service
  elif [ "${base_unit_was_present}" != 'y' ]; then
    # standalone build: this unit was created by the build, drop it
    rm -f /lib/systemd/system/php-fpm.service
  fi
  systemctl daemon-reload > /dev/null 2>&1
}
trap restore_default_unit EXIT
trap 'exit 130' INT TERM

echo "${CMSG}Compiling PHP${mphp_inst} into ${mphp_install_dir} (this takes a while)...${CEND}"
[ -n "${ZEND_EXTRA_LIBS}" ] && echo "${CMSG}Link flags: ZEND_EXTRA_LIBS=${ZEND_EXTRA_LIBS}${CEND}"
build_log=$(mktemp /tmp/mphp_build.XXXXXX 2>/dev/null || echo /tmp/mphp_build.log)
bash "${self}" --build-only "${mphp_ver}" "${mphp_name}" "${phpcache_option}" 2>&1 | tee -a ${oneinstack_dir}/mphp_install.log "${build_log}"

# `patch` prints "patching file <name>" for every hunk file; make sure the CVE patch ran
if [ -e "${oneinstack_dir}/src/php-${php_series}-CVE-2026-109618-109619.patch" ] && ! grep -q 'patching file' "${build_log}"; then
  echo "${CWARNING}Warning: the CVE patch was not applied, check ${oneinstack_dir}/mphp_install.log${CEND}"
fi
rm -f "${build_log}"

if [ ! -e "${mphp_install_dir}/sbin/php-fpm" ]; then
  echo "${CFAILURE}PHP${mphp_inst} build failed! See ${oneinstack_dir}/mphp_install.log${CEND}"
  exit 1
fi

# stop whatever the build started, then give the instance its own unit/socket
systemctl stop php-fpm > /dev/null 2>&1
command -v pkill > /dev/null 2>&1 && pkill -QUIT -f "${mphp_install_dir}/sbin/php-fpm" 2>/dev/null
sed -i "s@/dev/shm/php-cgi.sock@/dev/shm/php${mphp_inst}-cgi.sock@" ${mphp_install_dir}/etc/php-fpm.conf

cat > /lib/systemd/system/php${mphp_inst}-fpm.service <<EOF
[Unit]
Description=The PHP FastCGI Process Manager (PHP${mphp_inst})
Documentation=http://php.net/docs.php
After=network.target

[Service]
Type=simple
PIDFile=${mphp_install_dir}/var/run/php-fpm.pid
ExecStart=${mphp_install_dir}/sbin/php-fpm --nodaemonize --fpm-config ${mphp_install_dir}/etc/php-fpm.conf
ExecReload=/bin/kill -USR2 \$MAINPID
LimitNOFILE=1000000
LimitNPROC=1000000
LimitCORE=1000000

[Install]
WantedBy=multi-user.target
EOF

restore_default_unit
systemctl daemon-reload
systemctl enable php${mphp_inst}-fpm > /dev/null 2>&1
systemctl start php${mphp_inst}-fpm
[ -e "/lib/systemd/system/php-fpm.service" ] && {
  systemctl enable php-fpm > /dev/null 2>&1
  systemctl start php-fpm > /dev/null 2>&1
}

# do not keep the extra instance in the global PATH
sed -i "s@${mphp_install_dir}/bin:@@" /etc/profile

# extra extensions requested on the command line: build them into the new instance only
if [ -n "${extensions}" ]; then
  php_install_dir=${mphp_install_dir}
  ext_requested=" ${extensions} "
  echo "${CMSG}Installing extensions into ${mphp_install_dir}: ${extensions}${CEND}"
  for ext in zendguardloader ioncube sourceguardian imagick gmagick fileinfo imap ldap calendar phalcon yaf yar igbinary msgpack zstd memcached memcache redis mongodb swoole xdebug xlswriter grpc; do
    [[ "${ext_requested}" == *" ${ext} "* ]] || continue
    case "${ext}" in
      zendguardloader) . "${oneinstack_dir}/include/ZendGuardLoader.sh"; Install_ZendGuardLoader ;;
      ioncube) . "${oneinstack_dir}/include/ioncube.sh"; Install_ionCube ;;
      sourceguardian) . "${oneinstack_dir}/include/sourceguardian.sh"; Install_SourceGuardian ;;
      imagick) . "${oneinstack_dir}/include/ImageMagick.sh"; Install_ImageMagick; Install_pecl_imagick ;;
      gmagick) . "${oneinstack_dir}/include/GraphicsMagick.sh"; Install_GraphicsMagick; Install_pecl_gmagick ;;
      fileinfo) . "${oneinstack_dir}/include/pecl_fileinfo.sh"; Install_pecl_fileinfo ;;
      imap) . "${oneinstack_dir}/include/pecl_imap.sh"; Install_pecl_imap ;;
      ldap) . "${oneinstack_dir}/include/pecl_ldap.sh"; Install_pecl_ldap ;;
      calendar) . "${oneinstack_dir}/include/pecl_calendar.sh"; Install_pecl_calendar ;;
      phalcon) . "${oneinstack_dir}/include/pecl_phalcon.sh"; Install_pecl_phalcon ;;
      yaf) . "${oneinstack_dir}/include/pecl_yaf.sh"; Install_pecl_yaf ;;
      yar) . "${oneinstack_dir}/include/pecl_yar.sh"; Install_pecl_yar ;;
      igbinary) . "${oneinstack_dir}/include/pecl_igbinary.sh"; Install_pecl_igbinary ;;
      msgpack) . "${oneinstack_dir}/include/pecl_msgpack.sh"; Install_pecl_msgpack ;;
      zstd) . "${oneinstack_dir}/include/pecl_zstd.sh"; Install_pecl_zstd ;;
      memcached) . "${oneinstack_dir}/include/memcached.sh"; Install_pecl_memcached ;;
      memcache) . "${oneinstack_dir}/include/memcached.sh"; Install_pecl_memcache ;;
      redis) . "${oneinstack_dir}/include/redis.sh"; Install_pecl_redis ;;
      mongodb) . "${oneinstack_dir}/include/pecl_mongodb.sh"; Install_pecl_mongodb ;;
      swoole) . "${oneinstack_dir}/include/pecl_swoole.sh"; Install_pecl_swoole ;;
      xdebug) . "${oneinstack_dir}/include/pecl_xdebug.sh"; Install_pecl_xdebug ;;
      xlswriter) . "${oneinstack_dir}/include/pecl_xlswriter.sh"; Install_pecl_xlswriter ;;
      grpc) . "${oneinstack_dir}/include/pecl_grpc.sh"; Install_pecl_grpc ;;
    esac
  done
  systemctl reload php${mphp_inst}-fpm > /dev/null 2>&1 || true
fi
[ -n "${mphp_name}" ] && name_arg=" --mphp_name ${mphp_name}" || name_arg=''

# CentOS 7 usually runs SELinux in enforcing mode; the new prefix needs the right label
if command -v getenforce > /dev/null 2>&1 && [ "`getenforce 2>/dev/null`" == 'Enforcing' ]; then
  echo "${CWARNING}SELinux is Enforcing. If php${mphp_inst}-fpm failed to start, run:${CEND}"
  echo "${CWARNING}  restorecon -Rv ${mphp_install_dir} && systemctl restart php${mphp_inst}-fpm${CEND}"
fi

cat <<EOF

${CSUCCESS}PHP${mphp_inst} installed.${CEND}

  install dir : ${mphp_install_dir}
  service     : php${mphp_inst}-fpm
  socket      : /dev/shm/php${mphp_inst}-cgi.sock
  version     : $(${mphp_install_dir}/bin/php -v 2>/dev/null | head -n1)
  extensions  : ${extensions:-none}
  opcache     : $([ "${phpcache_option}" == '1' ] && echo enabled || echo disabled)
  modules     : $(${mphp_install_dir}/bin/php -m 2>/dev/null | wc -l) loaded

Next steps:
  1. Add more extensions to it:
       ./install.sh --mphp_ver ${mphp_ver}${name_arg} --mphp_addons --php_extensions redis,zstd
  2. Bind a site to it:
       ./vhost.sh            # choose: PHP instance ${mphp_inst}
     or
       ./vhost.sh --add --mphp_ver ${mphp_ver}${name_arg}
  3. Remove it:
       ./uninstall.sh --mphp_ver ${mphp_ver}${name_arg}

Log: ${oneinstack_dir}/mphp_install.log
EOF
