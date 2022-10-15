# Dell Server Fan Controller
## Bash script / service to control fan speeds in Dell servers (Mainly 11th gen)

### Summary
- Simple bash script with minimum requirements (ipmitool and lm-sensors)
- Has temperature averaging and sudden-change-prevention
- Tested on Debian / Proxmox
- Can be run manually/once-off for when the server's on a workbench, or setup as systemd service.

### Failsafe / Testing
- When testing for the first time, manually run outside of systemd and issue a Ctrl+C (sig-int) if it doesn't work as expected.
- This will stop the script and set the dell server back to auto fan controll.

### Requirements
This script only needs 2 things to work, fan control and temperatures.

> **apt install ipmitool**
`
ipmitool, utility for IPMI control with kernel driver or LAN interface (daemon)
`

> **apt install lm-sensors**
` 
lm-sensors, utilities to read temperature/voltage/fan sensors
`

## Installation

Option A - run the script as a once-off
- `chmod +x dell_server_fan_controller.sh`
- Make sure to check the bash location at the top of the script matches `env`
- `./dell_server_fan_controller.sh`

Option B - run the script as a service
- Choose a home for the script
- Configure systemd to run it

Example systemd configuration file: `/etc/systemd/system/fancontroller.service`
```sh
[Unit]
Description=Dell Server IPMI Fan Controller
After=multi-user.target

[Service]
ExecStart=/usr/local/scripts/dell_server_fan_controller.sh
ExecStop=/bin/kill -s 2 $MAINPID

[Install]
WantedBy=multi-user.target
```

## ToDo

- Vary fan control from ranges instead of fixed values for smoother changes.
- Test on 12th and 13th generation Dells (not that they really need it, their controllers as much more tame).

