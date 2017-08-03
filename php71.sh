#!/bin/bash

if [[ $EUID -ne 0 ]]; then
  echo "You must be a root user" 2>&1
  exit 1
fi

case `uname` in
	Linux )
		LINUX=1
		which yum 2>/dev/null >/dev/null && OS=centos
		which apt-get 2>/dev/null >/dev/null && OS=debian
	;;
esac

# Задаємо змінні
PREFIX='/opt/php71/'
TPL_NAME='php71'
PHP_URL='http://nl1.php.net/get/php-7.1.7.tar.gz/from/this/mirror'
PHP_INSTALL_DIR='php-7.1.7'
FPM_PORT='9071'
case ${OS} in
        centos ) 
		TPL_DIR=${VESTA}/data/templates/web/httpd/
	        for FILE in $(grep -R -l --color -E "proxy_.*_?module" $(find /etc/httpd/ -name "*.conf"))
	        do
	                sed -i '/^#.* proxy_module /s/^#//' $FILE
	                sed -i '/^#.* proxy_http_module /s/^#//' $FILE
	                sed -i '/^#.* proxy_fcgi_module /s/^#//' $FILE
	        done
        ;;
        debian )
                TPL_DIR=${VESTA}/data/templates/web/apache2/
		a2enmod proxy
		a2enmod proxy_fcgi
		addgroup nobody
        ;;
esac

# перевіряємо чи є папка з шаблонами вести. Нема вести - нема роботи.
if [ ! -d ${TPL_DIR} ]; then
        echo "VestaCP templates dir not found" >&2
        exit 1;
fi

# Вибираємо варсую апача. В них різний синтаксис конфігів.
ISAP22=$(apachectl -v | grep "Apache/2.2")
if [ "$ISAP22" ]; then
	APACHE_INCLUDE="Include"
else
	APACHE_INCLUDE="IncludeOptional"
fi

# ставимо потрібні бібліотеки для збірки
case ${OS} in
	centos ) 
		yum -y install make gcc tar kernel-devel wget libxml2-devel || exit 1
	;;
	debian )
		apt-get update
		apt-get -y install make gcc tar wget libxml2-dev zlib1g-dev || exit 1
	;;
	* )
		echo "Debian or CentOS need"
		exit 1
	;;
esac

# Робимо собі середовище для роботи
mkdir /opt/php71 2>/dev/null
cd /opt/php71

# викачуємо архів з php
wget ${PHP_URL} -O php.tar.gz || exit 1

# розпаковуємо його
tar xvzf php.tar.gz || exit 1

# переходимо в папку з сирцями
cd ${PREFIX}${PHP_INSTALL_DIR}

# Конфігурим і ставим
./configure --prefix=${PREFIX} --enable-fpm --enable-zip --enable-mbstring || exit 1
make || exit 1
make install || exit 1

# Перевіряємо чи потрібна папка з конфігами PHP-FPM існує. Якщо немає - створюємо, бо інсталятор може завтикати шось
if [ ! -d ${PREFIX}etc/php-fpm.d/ ]; then
        mkdir -p ${PREFIX}etc/php-fpm.d/
fi

# Вставляємо головний конфіг PHP-FPM
cat << EOF > ${PREFIX}etc/php-fpm.conf
[global]
pid = run/php-fpm.pid
error_log = log/php-fpm.log
syslog.ident = ${TPL_NAME}-fpm
log_level = notice
include=/opt/php71/etc/php-fpm.d/*.conf
EOF

# Вставляємо конфіг пула PHP-FPM
cat << EOF > ${PREFIX}etc/php-fpm.d/www.conf
[www]
user = nobody
group = nobody

listen = 127.0.0.1:${FPM_PORT}
listen.owner = nobody
listen.group = nobody
listen.mode = 0660
listen.allowed_clients = 127.0.0.1

pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
EOF

cat << EOF > ${TPL_DIR}${TPL_NAME}.tpl
<VirtualHost %ip%:%web_port%>
    ServerName %domain_idn%
    %alias_string%
    ServerAdmin %email%
    DocumentRoot %docroot%
    ScriptAlias /cgi-bin/ %home%/%user%/web/%domain%/cgi-bin/
    Alias /vstats/ %home%/%user%/web/%domain%/stats/
    Alias /error/ %home%/%user%/web/%domain%/document_errors/
    SuexecUserGroup %user% %group%
    CustomLog /var/log/%web_system%/domains/%domain%.bytes bytes
    CustomLog /var/log/%web_system%/domains/%domain%.log combined
    ErrorLog /var/log/%web_system%/domains/%domain%.error.log
    <Directory %docroot%>
        AllowOverride All
        Options +Includes -Indexes +ExecCGI
    </Directory>
    <Directory %home%/%user%/web/%domain%/stats>
	    AllowOverride All
    </Directory>
    ProxyPassMatch ^/(.*.php(/.*)?)$ fcgi://localhost:${FPM_PORT}%docroot%/$1
    ${APACHE_INCLUDE} %home%/%user%/conf/web/%web_system%.%domain_idn%.conf*
</VirtualHost>
EOF

cat << EOF > ${TPL_DIR}${TPL_NAME}.stpl
<VirtualHost %ip%:%web_ssl_port%>
    ServerName %domain_idn%
    %alias_string%
    ServerAdmin %email%
DocumentRoot %sdocroot%
    ScriptAlias /cgi-bin/ %home%/%user%/web/%domain%/cgi-bin/
    Alias /vstats/ %home%/%user%/web/%domain%/stats/
    Alias /error/ %home%/%user%/web/%domain%/document_errors/
    SuexecUserGroup %user% %group%
    CustomLog /var/log/%web_system%/domains/%domain%.bytes bytes
    CustomLog /var/log/%web_system%/domains/%domain%.log combined
    ErrorLog /var/log/%web_system%/domains/%domain%.error.log
    <Directory %sdocroot%>
        SSLRequireSSL
        AllowOverride All
        Options +Includes -Indexes +ExecCGI
    </Directory>
    <Directory %home%/%user%/web/%domain%/stats>
        AllowOverride All
    </Directory>
    ProxyPassMatch ^/(.*.php(/.*)?)$ fcgi://localhost:${FPM_PORT}%docroot%/$1
    SSLEngine on
    SSLVerifyClient none
    SSLCertificateFile %ssl_crt%
    SSLCertificateKeyFile %ssl_key%
    %ssl_ca_str%SSLCertificateChainFile %ssl_ca%
    ${APACHE_INCLUDE} %home%/%user%/conf/web/s%web_system%.%domain_idn%.conf*
</VirtualHost>
EOF

${PREFIX}sbin/php-fpm || exit 1

echo "Done :)"
