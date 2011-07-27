#!/bin/sh

KDUMP_PATH="/var/crash"
CORE_COLLECTOR="makedumpfile -d 31 -c"
DEFAULT_ACTION="reboot -f"

read_kdump_conf()
{
    local conf_file="/etc/kdump.conf"
    if [ -f "$conf_file" ]; then
        while read config_opt config_val;
        do
	    case "$config_opt" in
	    path)
                KDUMP_PATH="$config_val"
	        ;;
            core_collector)
		CORE_COLLECTOR="$config_val"
                ;;
            default)
                case $config_val in
                    shell)
                           DEFAULT_ACTION="emergency_shell"
                           ;;
                    reboot)
                            DEFAULT_ACTION="/usr/bin/reboot -f"
                            ;;
                    halt)
                            DEFAULT_ACTION="/usr/bin/halt -f"
                            ;;
                    poweroff)
                            DEFAULT_ACTION="/usr/bin/poweroff -f"
                            ;;
                esac
	        ;;
	    esac
        done < $conf_file
    fi
}

do_default_action()
{
    $DEFAULT_ACTION
}
