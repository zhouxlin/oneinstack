#!/bin/bash
# Author:  yeho <lj2007331 AT gmail.com>
# BLOG:  https://linuxeye.com
#
# Notes: OneinStack for CentOS/RedHat 7+ Debian 9+ and Ubuntu 16+
#
# Project home page:
#       https://oneinstack.com
#       https://github.com/oneinstack/oneinstack

Install_MPHP() {
  # mphp_name allows several copies of the same PHP version, e.g.
  # --mphp_ver 74 --mphp_name b => /usr/local/php74b, php74b-fpm, /dev/shm/php74b-cgi.sock
  local mphp_inst="${mphp_ver}${mphp_name}"
  if [ "${apache_mode_option}" == '2' ] || [ -e "${apache_install_dir}/modules/libphp5.so" ] || [ -e "${apache_install_dir}/modules/libphp7.so" ] || [ -e "${apache_install_dir}/modules/libphp.so" ]; then
    echo "${CWARNING}To use the multiple PHP versions, You need to use PHP-FPM! ${CEND}"
  else
    if [ -e "${php_install_dir}${mphp_inst}/bin/phpize" ]; then
      echo "${CWARNING}PHP${mphp_inst} already installed! ${CEND}"
    else
      [ -e "/lib/systemd/system/php-fpm.service" ] && /bin/mv /lib/systemd/system/php-fpm.service{,_bk}
      php_install_dir=${php_install_dir}${mphp_inst}
      case "${mphp_ver}" in
        53)
          . include/php-5.3.sh
          Install_PHP53 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        54)
          . include/php-5.4.sh
          Install_PHP54 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        55)
          . include/php-5.5.sh
          Install_PHP55 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        56)
          . include/php-5.6.sh
          Install_PHP56 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        70)
          . include/php-7.0.sh
          Install_PHP70 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        71)
          . include/php-7.1.sh
          Install_PHP71 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        72)
          . include/php-7.2.sh
          Install_PHP72 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        73)
          . include/php-7.3.sh
          Install_PHP73 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        74)
          . include/php-7.4.sh
          Install_PHP74 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        80)
          . include/php-8.0.sh
          Install_PHP80 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        81)
          . include/php-8.1.sh
          Install_PHP81 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        82)
          . include/php-8.2.sh
          Install_PHP82 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        83)
          . include/php-8.3.sh
          Install_PHP83 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        84)
          . include/php-8.4.sh
          Install_PHP84 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
        85)
          . include/php-8.5.sh
          Install_PHP85 2>&1 | tee -a ${oneinstack_dir}/install.log
          ;;
      esac
      if [ -e "${php_install_dir}/sbin/php-fpm" ]; then
        systemctl stop php-fpm 2>/dev/null || kill `cat ${php_install_dir}/var/run/php-fpm.pid 2>/dev/null` 2>/dev/null || true
        sed -i "s@/dev/shm/php-cgi.sock@/dev/shm/php${mphp_inst}-cgi.sock@" ${php_install_dir}/etc/php-fpm.conf
        [ -e "/lib/systemd/system/php-fpm.service" ] && /bin/mv /lib/systemd/system/php-fpm.service /lib/systemd/system/php${mphp_inst}-fpm.service
        if [ -e "/lib/systemd/system/php-fpm.service_bk" ]; then
          /bin/mv /lib/systemd/system/php-fpm.service{_bk,}
          systemctl enable php-fpm 2>/dev/null || true
          systemctl start php-fpm 2>/dev/null || true
        fi
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable php${mphp_inst}-fpm 2>/dev/null || true
        systemctl start php${mphp_inst}-fpm 2>/dev/null || ${php_install_dir}/sbin/php-fpm
        sed -i "s@${php_install_dir}/bin:@@" /etc/profile
      fi
    fi
  fi
}
