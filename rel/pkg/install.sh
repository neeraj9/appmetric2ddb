#!/usr/bin/bash

AWK=/usr/bin/awk
SED=/usr/bin/sed

USER=appmetric2ddb
GROUP=$USER

case $2 in
    PRE-INSTALL)
        if grep "^$GROUP:" /etc/group > /dev/null 2>&1
        then
            echo "Group already exists, skipping creation."
        else
            echo Creating appmetric2ddb group ...
            groupadd $GROUP
        fi
        if id $USER > /dev/null 2>&1
        then
            echo "User already exists, skipping creation."
        else
            echo Creating appmetric2ddb user ...
            useradd -g $GROUP -d /data/appmetric2ddb -s /bin/false $USER
            /usr/sbin/usermod -K defaultpriv=basic,net_privaddr $USER
        fi
        echo Creating directories ...
        mkdir -p /data/appmetric2ddb/etc
        mkdir -p /data/appmetric2ddb/db
        mkdir -p /data/appmetric2ddb/log/sasl
        chown -R $USER:$GROUP /data/appmetric2ddb
        if [ -d /tmp/appmetric2ddb ]
        then
            chown -R $USER:$GROUP /tmp/appmetric2ddb
        fi
        ;;
    POST-INSTALL)
        echo Importing service ...
        svccfg import /opt/local/appmetric2ddb/share/appmetric2ddb.xml
        echo Trying to guess configuration ...
        IP=`ifconfig net0 | grep inet | $AWK '{print $2}'`

        CONFFILE=/data/appmetric2ddb/etc/appmetric2ddb.conf
        cp /opt/local/appmetric2ddb/etc/appmetric2ddb.conf.example ${CONFFILE}.example

        if [ ! -f "${CONFFILE}" ]
        then
            echo "Creating new configuration from example file."
            cp ${CONFFILE}.example ${CONFFILE}
            $SED -i bak -e "s/127.0.0.1/${IP}/g" ${CONFFILE}
        else
            echo "Please make sure you update your config according to the update manual!"
        fi
        ;;
esac
