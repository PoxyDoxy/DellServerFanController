#!/bin/sh

# Dell server fan speed controller, for use as a systemd service.
# Mainly for the 11th Generation Dells, dem some chunky bois.
#
# v1.0 - Poxydoxy 13/10/2022
# - Created base script
#
# Confirmed working on:
# - Dell R710
# - Dell R610
#

# REQUIRES IPMITOOL, apt install iptmitool 
#ipmitool/stable
#  utility for IPMI control with kernel driver or LAN interface (daemon)

# REQUIRES SENSORS, apt install lm-sensors
#lm-sensors/stable,now 1:3.6.0-7 amd64 [installed]
#  utilities to read temperature/voltage/fan sensors

# For SystemD entry, use the following
# /etc/systemd/system/fancontroller.service
# ==========================================
#[Unit]
#Description=Dell Server IPMI Fan Controller
#After=multi-user.target
#
#[Service]
#ExecStart=/usr/local/scripts/dell_server_fan_controller.sh
#ExecStop=/bin/kill -s 2 $MAINPID
#
#[Install]
#WantedBy=multi-user.target
# ========================================

# Required tool binary location (or just name, if it's in your path)
IPMI_TOOL="ipmitool"
SENSORS_TOOL="sensors"

# Echo stats 
DEBUG=1

# Time between polls, in seconds
DELAY=1

# Amount of polls before changing up/down fan speed
CHANGE_UP_DELAY=10
CHANGE_DOWN_DELAY=5

# Temp Levels
CPU_LEVEL1=38
CPU_LEVEL2=44
CPU_LEVEL3=50
CPU_LEVEL4=57
CPU_LEVEL5=65

# Fan RPM levels
# Ensure there is at least 'auto' to fall back on
FAN_LEVEL0=0x06
FAN_LEVEL1=0x07
FAN_LEVEL2=0x08
FAN_LEVEL3=0x09
FAN_LEVEL4=0x15
FAN_LEVEL5=auto

# Other known values
# 0x09 = 2100
# 0x10 = 2800
# 0x13 = 3240
# 0x22 = 4680
# 0x32 = 6600
# 0x38 = 7440
# auto = controlled by iDRAC firmware (default Dell bahaviour)

# DO NOT TOUCH
# DO NOT TOUCH
# DO NOT TOUCH

# Check if ipmitool is installed
if ! [ -x "$(command -v $IPMI_TOOL)" ]; then
  echo 'Error: ipmitool is not installed.' >&2
  echo 'apt install ipmitool you baka' >&2
  exit 1
fi

# Check if sensors is installed
if ! [ -x "$(command -v $SENSORS_TOOL)" ]; then
  echo 'Error: lm-sensors is not installed.' >&2
  echo 'apt install lm-sensors you baka' >&2
  exit 1
fi

# Init variables
OLD_LEVEL=5
FAN_IS_AUTO=1
CMD_FAN_AUTO=0
POLLS_DOWN_REMAINING=0
POLLS_UP_REMAINING=0
previous_temp=0

# Catch sigint/ctrlC and sigexit
exit_graceful() {
        echo "Shutting down FanController"
        echo "FAN->iDRAC controlled"
        `$IPMI_TOOL raw 0x30 0x30 0x01 0x01`
        exit 0
}
trap exit_graceful INT
trap exit_graceful EXIT

# Fetch CPU temps
poll_core_temps() {
	high_core_temp=0
	cpu_list=`$SENSORS_TOOL | grep Core | awk '{print $3}' | cut -d '+' -f2 | cut -d '.' -f1`
	cpu_count=`echo "$cpu_list" | wc -l`
	cpu_avg=`echo $cpu_list | awk '{s+=$1}END{print s/NR}' RS=" " | awk '{print int($1+0.5)}'`

	if [ $DEBUG -gt 0 ]; then
		if [ $previous_temp -ne $cpu_avg ]; then
			echo "CPU[$cpu_avg]"
		fi
	fi
	previous_temp=$cpu_avg
}

# Compare CPU temps
level_test() {
	if [ $cpu_avg -lt $CPU_LEVEL1 ]; then
		NEW_LEVEL=0
		if [ "$FAN_LEVEL0" = "auto" ]; then CMD_FAN_AUTO=1; else IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL0"; fi
	elif [ $cpu_avg -lt $CPU_LEVEL2 ]; then
		NEW_LEVEL=1
		if [ "$FAN_LEVEL1" = "auto" ]; then CMD_FAN_AUTO=1; else IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL1"; fi
	elif [ $cpu_avg -lt $CPU_LEVEL3 ]; then
		NEW_LEVEL=2
		if [ "$FAN_LEVEL2" = "auto" ]; then CMD_FAN_AUTO=1; else IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL2"; fi
	elif [ $cpu_avg -lt $CPU_LEVEL4 ]; then
		NEW_LEVEL=3
		if [ "$FAN_LEVEL3" = "auto" ]; then CMD_FAN_AUTO=1; else IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL3"; fi
	elif [ $cpu_avg -lt $CPU_LEVEL5 ]; then
		NEW_LEVEL=4
		if [ "$FAN_LEVEL4" = "auto" ]; then CMD_FAN_AUTO=1; else IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL4"; fi
	else
		NEW_LEVEL=5
		if [ "$FAN_LEVEL5" = "auto" ]; then CMD_FAN_AUTO=1; else IPMI_CMD="raw 0x30 0x30 0x02 0xff $FAN_LEVEL5"; fi
	fi
}

# Compare new/old fan levels
level_compare() {
	if [ $OLD_LEVEL -eq $NEW_LEVEL ]; then
		# No change, nothing to do
		POLLS_DOWN_REMAINING=$CHANGE_DOWN_DELAY
		POLLS_UP_REMAINING=$CHANGE_UP_DELAY
	elif [ $OLD_LEVEL -gt $NEW_LEVEL ] && [ $POLLS_DOWN_REMAINING -gt 0 ]; then
		# Changing down
		if [ $DEBUG -gt 0 ]; then
			echo "FAN->Down $POLLS_DOWN_REMAINING/$CHANGE_DOWN_DELAY"
		fi
		POLLS_DOWN_REMAINING=`expr $POLLS_DOWN_REMAINING - 1`
	elif [ $OLD_LEVEL -lt $NEW_LEVEL ] && [ $POLLS_UP_REMAINING -gt 0 ]; then
		# Changing up
		if [ $DEBUG -gt 0 ]; then
			echo "FAN->Up $POLLS_UP_REMAINING/$CHANGE_UP_DELAY"
		fi
		POLLS_UP_REMAINING=`expr $POLLS_UP_REMAINING - 1`
	else
		# Polls satisfied, do the change
		level_change
		POLLS_DOWN_REMAINING=$CHANGE_DOWN_DELAY
		POLLS_UP_REMAINING=$CHANGE_UP_DELAY
	fi
}

# Perform fan level change
level_change() {
	if [ $CMD_FAN_AUTO -eq 1 ] && [ $FAN_IS_AUTO -ne 1 ]; then
		if [ $DEBUG -gt 0 ]; then
			echo "FAN->Auto"
		fi
		`$IPMI_TOOL raw 0x30 0x30 0x01 0x01`
		FAN_IS_AUTO=1
		CMD_FAN_AUTO=0
	elif [ $CMD_FAN_AUTO -eq 1 ] && [ $FAN_IS_AUTO -eq 1 ]; then
		CMD_FAN_AUTO=0
	elif [ $CMD_FAN_AUTO -eq 0 ] && [ $FAN_IS_AUTO -eq 1 ]; then
		if [ $DEBUG -gt 0 ]; then
			echo "FAN->Manual"
		fi
		`$IPMI_TOOL raw 0x30 0x30 0x01 0x00`
		FAN_IS_AUTO=0
		CMD_FAN_AUTO=0
	fi
	if [ $DEBUG -gt 0 ]; then echo "FAN->$NEW_LEVEL"; fi
	`$IPMI_TOOL $IPMI_CMD`
	OLD_LEVEL=$NEW_LEVEL
}

# Main Loop
echo "Starting Fan Controller"
while true; do
	poll_core_temps
	level_test
	level_compare
	sleep $DELAY
done

exit 0
