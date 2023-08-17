#!/bin/sh
#
# Copyright (C) ZHW
#


mkdir -p /tmp/status/
mkdir -p /var/log/

NETWORK_ID=0
CID=0

APN=iotde.telefonica.com
#COUNTRY=232
#PLMN=23203

logger "Modem init: Start"

at_wan_modem() {
	echo "$1" | /usr/bin/comgt -s /etc/gcom/telit-at
}

onetime_init_wan_modem() {

	#rm -f /dev/ttygcom
	#ln -s /dev/ttyUSB2 /dev/ttygcom

	modem_type=`lsusb -d 1bc7: | awk '{print $6}'`

	case "$modem_type" in
		"1bc7:1201")
			echo "LE910C" > /tmp/status/modem_model
			;;
		"1bc7:0036")
                        echo "LE910EUv1" > /tmp/status/modem_model
                        ;;
                "1bc7:0032")
                        echo "LE910EUv2" > /tmp/status/modem_model
                        ;;
                "1bc7:0021")
                        echo "HE910" > /tmp/status/modem_model
                        ;;
                *)
			echo "ERROR" > /tmp/status/modem_model
                        echo "No compatible modem found $modem_type" | logger -t one_time_init
			;;
	esac

	sleep 1

	# Disable LTE antenna diversity the devices
	at_wan_modem 'at#rxdiv=0,0'
	# Activate the SMS modem functions
	at_wan_modem 'AT#SMSATRUNCFG=3,1,2'
	at_wan_modem 'AT#SMSATRUN=1'
	at_wan_modem 'AT#SMSATWL=0,1,1,"15878159745713601"'
	echo 0 > /tmp/status/modem_sim_inserted
}

# Do the onetime setup of this modem
onetime_init_wan_modem

# move the logs
for i in `seq 4 -1 1`; do
	mv /var/log/telit.log.$i mv /var/log/telit.log.$((i+1)) 2>/dev/null || true
done

mv /var/log/telit.log /var/log/telit.log.1 2>/dev/null || true

echo "Found a new telit device" > /var/log/telit.log

# Disable USB auto suspend:
echo "on" > /sys/class/usbmisc/cdc-wdm0/power/control

# Clean any running instance ...
killall -9 qmicli

# Reconfigure the network interface
ifconfig wwan0 down
if [ -s /tmp/wwan0.udhcpc.pid ]; then
	# Remove the DHCP client
	kill -9 `cat /tmp/wwan0.udhcpc.pid`
fi
ifconfig wwan0 down

# 3. create the configuration
QMICONF=/tmp/qmi-network.conf
echo "APN=$APN" > $QMICONF
echo "PROXY=yes" >> $QMICONF

# we need a raw ip transport for the telit interfaces
echo Y > /sys/class/net/wwan0/qmi/raw_ip

# Make sure to stop any network access for now
echo "disable autoconnect: " >> /var/log/telit.log
qmicli -p -d /dev/cdc-wdm0 --wds-stop-network=disable-autoconnect >> /var/log/telit.log 2>>/var/log/telit.log

echo "set autoconnect setting to disable: " >> /var/log/telit.log
qmicli -p -d /dev/cdc-wdm0 --wds-set-autoconnect-settings=disabled >> /var/log/telit.log 2>>/var/log/telit.log


echo "Found autoroaming for country code ${COUNTRY} with PLMN ${PLMN}" | logger -p info -t LTE 

if [[ ! -z "$PLMN" ]]; then
	# Disable the connection (should have no effect, see the commands above)
	telit-at "AT+COPS=2" >> /var/log/telit.log 2>>/var/log/telit.log
	sleep 1
	telit-at "AT+COPS=4,2,${PLMN}" >> /var/log/telit.log 2>>/var/log/telit.log
	sleep 1
	echo "Setting the modem finished"
fi

# Now connect to the network use the mac as client id
echo "connect to the network: " >> /var/log/telit.log
qmicli -p -d /dev/cdc-wdm0 --wds-start-network="apn=${APN},ip-type=4,autoconnect=yes" --client-no-release-cid --wds-follow-network >> /var/log/telit.log 2>>/var/log/telit.log &

# Wait until we are connected
connected=0
for i in `seq 1 120`; do
	qmicli -p -d /dev/cdc-wdm0 --wds-get-packet-service-status | grep "Connection status: 'connected'"
	if [ $? -eq 0 ]; then
		# we are connected
		connected=1
		break;
	fi

	sleep 1
done

if [ ${connected} -eq 0 ]; then
	echo "No connection to the LTE network in the last 120 seconds" >> /var/log/telit.log

	grep -q 'call-throttled' /var/log/telit.log
	if [ $? -eq 0 ]; then
		COUNT_T30x=$((COUNT_T30x+1))
		echo ${COUNT_T30x} > /tmp/status/lte_t30x_count
		echo "Our call was throttled! This is the ${COUNT_T30x} time this happend" | logger -t telit-init -p info
		/etc/init.d/telit-modem restart
		exit 1
	fi
else
	echo "Connection to the LTE network established, will now start DHCP" >> /var/log/telit.log
fi

# enable the autoconnect feature
echo "reenable the autoconnect feature: " >> /var/log/telit.log
qmicli -p -d /dev/cdc-wdm0 --wds-set-autoconnect-settings=enabled

#udhcpc -p /tmp/wwan0.udhcpc.pid -i wwan0 -A 20 -t 4 -T 6 -S -b
ifdown wwan
sleep 1
ifup wwan

# set the MTU for this interface (TODO: Read from QMI interface)
MTU_WWAN=1400
ifconfig wwan0 mtu $MTU_WWAN

logger "Modem init: End"

exit 0
