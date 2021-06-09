#!/bin/bash
# version 1.5 < 2021/06/03: Use encoded credentials for mysql access
# version 1.4 < 2014/03/18: Last version for cPanel legacy backups 
# version 1.3 < 2013/09/30: Apache & Network configuration for restoring account on Ubuntu Vagrant-VM >
# version 1.2 < 2013/07/09: /homedir/ no longuer tared in cpanel daily backups >
# version 1.1 < 2012/09/29: keep complete account homedir content for handling external webtree content (e.g. data dir) >

###################################################################################
#  This script is optimized for restoration of a cPanel backup on an Ubuntu VM.
#
# (c) Meridium Technologies, 2012-2021
#
#  WARNING: DO NOT USE THIS SCRIPT ON A CPANEL SERVER OR A PRODUCTION SERVER.#
#
###################################################################################

# NOTE: Use the following command to encode your mysql credentials on your vm
#   mysql_config_editor set --login-path=local --host=localhost --user=root --password

#### Settings ####
archive_name=$1        	  # pass cPanel archive_name to variable
archive_dir='' # no trailing slash
tld=''		          # local domain on VM
fileown='user:group' 	  # owner.group
conn='--login-path=local' # credentials to access mysql engine
httpdconfpath='/etc/apache2'

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

# Extract cPanel account name
# check if manual/automated cPanel backup
if [[ "$archive_name" == *backup* ]]
then
		uncompressedDir=${archive_name%%.tar.gz}
        accountname=$(echo $uncompressedDir | cut -d'_' -f3)
		echo "Launching cPanel Account Name => $accountname"
else
		accountname=${archive_name%%.tar.gz}
        uncompressedDir=$accountname
		echo "Launching cPanel Account Name => $accountname"
fi

### SANITY CHECKS ###

# make sure that file exists
if [ ! -f $archive_dir/$archive_name ]; then
  usage "Invalid argument! (the file $archive_dir/$archive_name does not exist in this directory)"
fi

# Make sure this is a true cPanel archive (skipped because taking to long)
# tar -tzf $archive_name | grep 'version'

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
	databases=(`echo 'show databases;' | mysql $conn | grep $accountname\_`)
	count=(`echo ${#databases[@]}`)
	if [ $count -gt 0 ]; then
		echo "=> Deleting existing account databases ($count found!): "
		for d in "${databases[@]}"; do
			mysqladmin $conn -f drop ${d}
		done
	else
		echo "No local database found for the account $accountname."
	 fi
	# Delete local mysql users
	dbusers=(`echo "SELECT CONCAT(User,'@',Host) FROM mysql.user WHERE User LIKE '%$accountname%';" | mysql $conn | grep $accountname`)  
	ucount=(`echo ${#dbusers[@]}`)
	if [ $ucount -gt 0 ]; then
		echo "=> Dropping local mysql users & privileges ($ucount found!): "
		for u in "${dbusers[@]}"; do
			mysql $conn -e "DROP USER $u;"
			echo "user $u dropped!"
		done
	mysql $conn -e "FLUSH PRIVILEGES;"
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
tar -C /tmp/ -xzf /home/seb/$archive_dir/$archive_name $uncompressedDir/homedir $uncompressedDir/mysql.sql $uncompressedDir/mysql
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
 mysql $conn -e "$CMD1"
 mysql $conn $DB < $filename
 echo " Done!"
done

#restore mysql users
echo -n "=> Creating mysql users & manage privileges..."
GRANT1=$(cat /tmp/$uncompressedDir/mysql.sql | grep 'localhost')
mysql $conn -e "$GRANT1"
echo " Done!"

echo -n "=> Removing temp account files ("
echo -n "/tmp/$uncompressedDir)..."
rm -rf  /tmp/$uncompressedDir/
echo " Done!"

# Configure apache ( ubuntu )
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
