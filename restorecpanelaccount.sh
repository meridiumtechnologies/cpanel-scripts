#!/bin/bash
# version 1.4 < 2014/03/18: Last version for cPanel legacy backups 
# version 1.3 < 2013/09/30: Apache & Network configuration for restoring account on Ubuntu Local/Virtual machine/
# version 1.2 < 2013/07/09: /homedir/ no longuer tared in cpanel daily backups >
# version 1.1 < 2012/09/29: keep complete account homedir content for handling external webtree content (e.g. data dir)
#
# Usefull script to restore cPanel daily or manual backups on a local Ubuntu virtual machine
# in order to test the integrity of the backups from time to time (you never know!) or
# to dump a copy of your website in a local environment for testing purposes.
# The account will be restored to default Apache web root
#
# Usage: ./restorecpanelaccounts.ssh backup-file-name
#
# NOTE: You must be familiar with local/home/office tlds for internal DNS resolution.
#
# WARNING: DO NOT USE THIS SCRIPT ON A CPANEL SERVER OR A PRODUCTION SERVER.
#
# (c) Meridium Technologies, 2012-2019
#
###################################################################################

#### Configuration ####

archive=$1        # pass cPanel archive to variable
mysqluser='xxxxx'  # mysql username to use for restore
mysqlpwd='xxxx' # set MySQL root password
fileown='xxxx.xxxx' # owner.group
tld='xxxx'

#### Do not edit below ###

if [[ $UID -ne 0 ]]; then
    echo "$0 must be run as root"
    exit 1
fi

function usage ()
{
 echo "ERROR=> $1"
 exit 1 #exit shell script
}

# display trailing dot while unpacking homedir.tar
function progress(){
while true
do
     echo -n "."
     sleep 1
done
}

# Extract cPanel account name
# check if manual/automated cPanel backup
if [[ "$archive" == *backup* ]]
then
		uncompressedDir=${archive%%.tar.gz}
        accountname=$(echo $uncompressedDir | cut -d'_' -f3)
		echo "Launching cPanel Account Name => $accountname"
else
		accountname=${archive%%.tar.gz}
        uncompressedDir=$accountname
		echo "Launching cPanel Account Name => $accountname"
fi

### SANITY CHECKS ###

# make sure that file exists
if [ ! -f /home/seb/public/$archive ]; then
  usage "Invalid argument! (the file /home/seb/public/$archive does not exist in this directory)"
fi

# Make sure this is a true cPanel archive (skipped because taking to long)
# tar -tzf $archive | grep 'version'

# check if the account already exists on the local server
if [ -d /var/www/$accountname ]; then
echo -n "The directory /var/www/$accountname already exists. Do you want to overwrite it(Y/N): "
read fanswer  
 if [ $fanswer == 'Y' ]; then
	clear
	echo -e "\E[32m== REMOVING LOCAL ACCOUNT $accountname =="; tput sgr0
	# Delete account dir
	echo -n "=> Deleting account dir /var/www/$accountname..."
	rm -rf /var/www/$accountname
	echo " Done!"

	# Delete local mysql databases if they exist (fresh install)
	databases=(`echo 'show databases;' | mysql -u$mysqluser -p$mysqlpwd | grep $accountname\_`)
	count=(`echo ${#databases[@]}`)
	if [ $count -gt 0 ]; then
		echo "=> Deleting existing account databases ($count found!): "
		for d in "${databases[@]}"; do
			mysqladmin -u$mysqluser -p$mysqlpwd -f drop ${d}
		done
	else
		echo "No local database found for the account $accountname."
	 fi
	# Delete local mysql users
	dbusers=(`echo "SELECT CONCAT(User,'@',Host) FROM mysql.user WHERE User LIKE '%$accountname%';" | mysql -u$mysqluser -p$mysqlpwd | grep $accountname`)  
	ucount=(`echo ${#dbusers[@]}`)
	if [ $ucount -gt 0 ]; then
		echo "=> Dropping local mysql users & privileges ($ucount found!): "
		for u in "${dbusers[@]}"; do
			mysql -u$mysqluser -p$mysqlpwd -e "DROP USER $u;"
			echo "user $u dropped!"
		done
	mysql -u$mysqluser -p$mysqlpwd -e "FLUSH PRIVILEGES;"
	else
		echo "No matching mysql user found!"
	fi
 else 
	 usage "Restore aborted by user!"
 fi
fi

###### UNTAR PACKAGE ######
echo -e "\E[32m== RESTORING ACCOUNT $accountname ON LOCAL SERVER =="; tput sgr0
echo -n "=> Unpacking files and database informations to /tmp/$uncompressedDir. Please wait..."

 # Start it in the background
 #progress &
 # Save PID
 #MYSELF=$!
 # cp /vagrant/src/$archive /tmp/$archive
 tar -C /tmp/ -xzf /home/seb/public/$archive $uncompressedDir/homedir $uncompressedDir/mysql.sql $uncompressedDir/mysql
 # Kill progress
 #kill $MYSELF >/dev/null 2>&1
 echo "...Done!"

echo "=> Creating directory /var/www/$accountname"
mkdir /var/www/$accountname

###### MOVE public_html DIRECTORY TO /home DIR ######
echo -n "=> Moving public_html to /var/www/$accountname ..."
mv /tmp/$uncompressedDir/homedir/* /var/www/$accountname/.
echo " Done!"

echo -n "=> Changing file ownership..."
chown -R $fileown /var/www/$accountname
echo " Done!"

echo -n "=> Changing file attributes..."
find /var/www/$accountname -type d -exec chmod 775 {} \;
find /var/www/$accountname -type f -exec chmod 664 {} \;
echo " Done!"

###### PROCESSING MySQL FILES & USERS ######
#restore mysql databses
for filename in /tmp/$uncompressedDir/mysql/$accountname\_*.sql; do
 DB=$(echo $filename | cut -d'/' -f5 | cut -d'.' -f1)
 echo -n "=> Creating and importing database -> $DB..."
 CMD1="CREATE database IF NOT EXISTS $DB;"
 mysql -u$mysqluser -p$mysqlpwd -e "$CMD1"
 mysql -u$mysqluser -p$mysqlpwd $DB < $filename
 echo " Done!"
done

#restore mysql users
echo -n "=> Creating mysql users & manage privileges..."
GRANT1=$(cat /tmp/$uncompressedDir/mysql.sql | grep 'localhost')
mysql -u$mysqluser -p$mysqlpwd -e "$GRANT1"
echo " Done!"

echo -n "=> Removing temp account files ("
echo -n "/tmp/$uncompressedDir)..."
rm -rf  /tmp/$uncompressedDir/
echo " Done!"

# Configuration de apache
httpdconfpath='/etc/apache2'
httpdvhostconf="$httpdconfpath/sites-available/$accountname.$tld-vhost.conf"
sitesenabled="$httpdconfpath/sites-enabled/$accountname.$tld-vhost.conf"

if [ ! -f $httpdvhostconf ]; then
	echo "
<VirtualHost *:80>
	DocumentRoot \"/var/www/$accountname/public_html\"
	ServerName $accountname.$tld
	<Directory \"/var/www/$accountname/public_html\">
		allow from all
		Options +Indexes
	</Directory>
</VirtualHost>
" > $httpdvhostconf

  ln -s $httpdvhostconf $sitesenabled
  service apache2 restart

fi

# Configure and Restart Network
if ! grep -q "$accountname.$tld" /etc/hosts ; then
	echo "=> Adjusting network configuration..."
	echo "127.0.0.1       $accountname.$tld" >> /etc/hosts
    sudo ifdown eth0 && sudo ifup eth0
fi

now=$(date +"%Y/%m/%d %H:%M:%S")
echo "$now => $accountname" >> restore-log.txt

echo -e '\E[32m== RESTORE COMPLETED! =='; tput sgr0
