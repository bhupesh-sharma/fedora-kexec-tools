#!/bin/sh

# Normally we can have two variants of the kdump.conf and kdump files:
#   1. The distribution specific one, which is usually located
#      inside /lib/kdump/
#   2. And the user specific one, which is usually located inside
#      /etc/kdump
#
# So, here we need to create the final kdump.conf or kdump file by
# looking at both the distribution provided .conf and the user's copy
# of the .conf file and picking up the various directives such that
# the ones specified in the user's copy always take a precedence on
# those specified in the distribution provided .config

USER_KDUMP_CONFIG_DIR="/etc/kdump"
TMP_KDUMP_CONFIG_DIR="/etc/kdump/tmp"
USER_KDUMP_CONFIG_FILE="/etc/kdump/kdump.conf"
BACKUP_USER_KDUMP_CONFIG_FILE="/etc/kdump/kdump.conf.usrorig"
TMP_KDUMP_CONFIG_FILE="/etc/kdump/tmp-kdump.conf"
DISTRO_KDUMP_CONFIG_FILE="/lib/kdump/kdump.conf"

USER_KDUMP_FILE="/etc/kdump/kdump"
BACKUP_USER_KDUMP_FILE="/etc/kdump/kdump.usrorig"
TMP_KDUMP_FILE="/etc/kdump/tmp-kdump"
DISTRO_KDUMP_FILE="/lib/kdump/kdump"

DEPRECATED_KDUMP_CONFIG_FILE="/etc/kdump.conf"
DEPRECATED_KDUMP_FILE="/etc/sysconfig/kdump"

use_distribution_config_file()
{
	local DISTRO_FILE=$1
	local USER_FILE=$2

	# Check if $USER_KDUMP_CONFIG_DIR exists, if not create it
	[ ! -d $USER_KDUMP_CONFIG_DIR ] && mkdir -p $USER_KDUMP_CONFIG_DIR

	# Check if $USER_KDUMP_CONFIG_FILE exists, if not
	# copy the $DISTRO_KDUMP_CONFIG_FILE over
	[ ! -f $USER_FILE ] && cp -f $DISTRO_FILE $USER_FILE
}

use_deprecated_config_file()
{
	local DEPRECATED_FILE=$1
	local USER_FILE=$2

	# Check if $USER_KDUMP_CONFIG_DIR exists, if not create it
	[ ! -d $USER_KDUMP_CONFIG_DIR ] && mkdir -p $USER_KDUMP_CONFIG_DIR

	# Copy the $DEPRECATED_FILE as $USER_FILE
	cp -f $DEPRECATED_FILE $USER_FILE
}

create_backup_of_user_config_file()
{
	local USER_FILE=$1
	local BACKUP_FILE=$2

	cp -f $USER_FILE $BACKUP_FILE
	echo "$USER_FILE saved as $BACKUP_FILE"
}

is_user_config_file_present()
{
	local USER_FILE=$1
	local DEPRECATED_FILE=$2

	if [ -f $USER_FILE ]; then
		return 1
	else
		# If deprecated config file is present, copy it as the
		# user config file since it does not exist originally.
		if [ -f $DEPRECATED_FILE ]; then
			use_deprecated_config_file $DEPRECATED_FILE $USER_FILE
			return 1
		else
			return 0
		fi
	fi
}

is_distribution_specific_config_file_present()
{
	local DISTRO_FILE=$1

	if [ -f $DISTRO_FILE ]; then
		return 1
	fi

	return 0
}

create_final_config_file_initrd_rebuild_not_reqd()
{
	local DISTRO_FILE=$1
	local USER_FILE=$2
	local TMP_FILE=$3
	local BACKUP_FILE=$4

	# Logic below requires the comments and commands in a .conf
	# file to be seperated via a blank line. If we don't see the
	# same, bail out with a error
	if [ $(grep -c "^$" $DISTRO_FILE) -eq 0 ]; then
		echo "Error! Invalid $DISTRO_FILE format" >&2
		exit 1
	fi

	if [ $(grep -c "^$" $USER_FILE) -eq 0 ]; then
		echo "Error! Invalid $USER_FILE format" >&2
		exit 1
	fi

	# Create TMP directory to hold temporary files
	TMP_KDUMP_CONFIG_DIR=$(mktemp -d)

	# Setup a cleanup in case we trap a signal which is going to
	# kill this script
	trap 'rm -rf $TMP_KDUMP_CONFIG_DIR $TMP_FILE' EXIT

	# Remove leftover tmp files (if any)
	if [ -f $TMP_FILE ]; then
		rm -f $TMP_FILE
	fi

	# Now setup the temporary files
	local USER_CMD_FILE=$TMP_KDUMP_CONFIG_DIR/USER_CMD.$$.tmp
	local DISTRO_CMD_FILE=$TMP_KDUMP_CONFIG_DIR/DISTRO_CMD.$$.tmp
	local CMD_TMP_FILE=$TMP_KDUMP_CONFIG_DIR/CMD_TMP.$$.tmp

	# Final .conf file creation rules:
	# 1. If a unknown/deprecated command was found in user .conf,
	#    ignore it.
	# 2. If a commented command was found in user .conf, preserve it.
	# 3. If a non-commented command was found both in user .conf
	#    and distro .conf, preserve the value specified in user.conf
	# 4. If a new comment or command is found in distro .conf,
	#    preserve it.

	# First copy the comment section (which is seperated by a
	# blankline from the commands) into the new .conf file
	sed -e '/./!Q' $DISTRO_FILE > $TMP_FILE 2>&1

	# Add a blank line
	echo "" >> $TMP_FILE 2>&1

	sed '1,/^$/d' $DISTRO_FILE > $DISTRO_CMD_FILE 2>&1
	sed '1,/^$/d' $USER_FILE > $USER_CMD_FILE 2>&1

	# Check if the rest of the distro and user conf files are exact
	# replicas. If yes, do nothing more and copy the rest of the
	# distro conf file as the new conf file
	cmp -s $DISTRO_CMD_FILE $USER_CMD_FILE
	if [ $? -eq 0 ]; then
		cat $DISTRO_CMD_FILE >> $TMP_FILE
	else
		# Copy common comments and commands specified in both
		# distro and user .conf into the new .conf file
		awk 'NR==FNR{A[$1];next} $1 in A' $USER_CMD_FILE $DISTRO_CMD_FILE >> $TMP_FILE 2>&1

		# Now, copy new comments and commands specified in
		# distro .conf into the new .conf file
		grep -vxFf $USER_CMD_FILE $DISTRO_CMD_FILE >> $TMP_FILE 2>&1

		# If there are any duplicates exisiting, deal with them
		# (prefer those mentioned in user .conf):
		grep -vxFf $DISTRO_CMD_FILE $USER_CMD_FILE >> $CMD_TMP_FILE 2>&1
		sed --in-place "/^#$(awk '{print $1}' $CMD_TMP_FILE)/d" $TMP_FILE 2>&1
		sed --in-place "/^$(awk '{print $1}' $CMD_TMP_FILE)/d" $TMP_FILE 2>&1

		# Finally, copy whats changed in user .conf
		grep -vxFf $DISTRO_CMD_FILE $USER_CMD_FILE >> $TMP_FILE 2>&1
	fi

	# If the newly generated .conf file is the same as the backup
	# copy, do nothing
	cmp -s $TMP_FILE $BACKUP_FILE
	if [ $? -ne 0 ]; then
		# Now finally move this .conf file as the default .conf
		# file
		mv -f $TMP_FILE $USER_FILE
	fi

	# Remove leftover tmp files (if any)
	if [ -f $TMP_FILE ]; then
		rm -f $TMP_FILE
	fi

	rm -rf $TMP_KDUMP_CONFIG_DIR
}

create_final_config_file_initrd_rebuild_reqd()
{
	local DISTRO_FILE=$1
	local USER_FILE=$2
	local TMP_FILE=$3
	local BACKUP_FILE=$4

	# Create TMP directory to hold temporary files
	TMP_KDUMP_CONFIG_DIR=$(mktemp -d)

	# Setup a cleanup in case we trap a signal which is going to
	# kill this script
	trap 'rm -rf $TMP_KDUMP_CONFIG_DIR $TMP_FILE' EXIT

	# Remove existing tmp files (if any)
	if [ -f $TMP_FILE ]; then
		rm -f $TMP_FILE
	fi

	# Now setup the temporary files
	local USER_CMD_FILE=$TMP_KDUMP_CONFIG_DIR/USER.$$.tmp
	local CMD_TMP_FILE=$TMP_KDUMP_CONFIG_DIR/CMD_TMP.$$.tmp
	local FINAL_TMP_FILE=$TMP_KDUMP_CONFIG_DIR/TMP.$$.tmp

	# Copy the distro .conf file to new .conf file
	cp -f $DISTRO_FILE $TMP_FILE

	# Now, handle deprecated or modified commands in user.conf.
	# Remove the deprecated commands and keep the modified commands
	# in the new .conf file
	grep -vxFf $DISTRO_FILE $USER_FILE > $USER_CMD_FILE 2>&1

	# There can be some commands which have been redefined or added
	# in the user .conf and hence do not match the respective distro
	# .conf.
	#
	# Ignore any deprecated command mentioned in the user .conf and
	# return the value of a command (assuming a command is defined
	# as:
	# 	COMMAND=This is my command [i.e. using the '=' separator]
	# so that it can be retained in the new .conf
	#
	# Finally move this new .conf file as the user .conf file
	awk -F '=' '{A[$1];print $1}' $USER_CMD_FILE >> $CMD_TMP_FILE 2>&1

	sed -e "s/$(grep "^$(awk -F '=' 'NR==FNR{A[$1];next} $1 in A' $TMP_FILE $CMD_TMP_FILE)" $TMP_FILE)/$(grep "^$(awk -F '=' 'NR==FNR{A[$1];next} $1 in A' $TMP_FILE $CMD_TMP_FILE)" $USER_CMD_FILE)/" $TMP_FILE > $FINAL_TMP_FILE

	# If the newly generated .conf file is the same as the backup
	# copy, do nothing
	cmp -s $FINAL_TMP_FILE $BACKUP_FILE
	if [ $? -ne 0 ]; then
		# Now finally move this .conf file as the default .conf
		# file
		mv -f $FINAL_TMP_FILE $USER_FILE
	fi

	# Remove leftover tmp files (if any)
	if [ -f $TMP_FILE ]; then
		rm -f $TMP_FILE
	fi

	rm -rf $TMP_KDUMP_CONFIG_DIR
}

create_final_config_file()
{
	local INITRD_REBUILD_REQD=$1
	local DISTRO_FILE=$2
	local USER_FILE=$3
	local TMP_FILE=$4
	local BACKUP_FILE=$5

	if [ $INITRD_REBUILD_REQD -eq 1 ]; then
		create_final_config_file_initrd_rebuild_reqd \
			$DISTRO_FILE $USER_FILE $TMP_FILE $BACKUP_FILE
	else
		create_final_config_file_initrd_rebuild_not_reqd \
			$DISTRO_FILE $USER_FILE $TMP_FILE $BACKUP_FILE
	fi
}

handle_config_files()
{
	local INITRD_REBUILD_REQD=$1
	local DISTRO_FILE=$2
	local USER_FILE=$3
	local TMP_FILE=$4
	local BACKUP_FILE=$5
	local DEPRECATED_FILE=$6

	# Check if the user specified .conf file exists
	is_user_config_file_present $USER_FILE $DEPRECATED_FILE
	if [ $? -eq 1 ]; then
		# Check if the distro specified .conf file exists
		is_distribution_specific_config_file_present $DISTRO_FILE
		if [ $? -eq 1 ]; then
			# Check if the distro and user conf files are
			# exact replicas. If yes, do nothing and copy
			# distro conf file as the user conf file
			cmp -s $DISTRO_FILE $USER_FILE
			if [ $? -eq 0 ]; then
				use_distribution_config_file \
					$DISTRO_FILE $USER_FILE
			else
				# Create a backup copy of the user
				# specified .conf file, so that the
				# user can track changes (if required)
				# later-on
				create_backup_of_user_config_file \
					$USER_FILE $BACKUP_FILE

				# Traverse the user's copy of kdump.conf
				# file and the distro specific version
				# and create a final kdump.conf file
				# which gives precedence to the user
				# specific settings
				create_final_config_file \
					$INITRD_REBUILD_REQD \
					$DISTRO_FILE $USER_FILE \
					$TMP_FILE $BACKUP_FILE
			fi
		fi
	else
		# Check if the distro specified .conf file exists
		# and use the same as the default
		is_distribution_specific_config_file_present $DISTRO_FILE
		if [ $? -eq 1 ]; then
			use_distribution_config_file $DISTRO_FILE \
						     $USER_FILE
		else
			echo "Error! No valid config file found" >&2
			exit 1
		fi
	fi
}

remove_deprecated_config_files()
{
	local DEPRECATED_CONFIG_FILE=$1
	local USER_KDUMP_FILE=$2

	# If everything went ok and the conf files are properly
	# generated, remove the deprecated config files
	if [[ -f $DEPRECATED_CONFIG_FILE && -f $USER_KDUMP_FILE && -s $USER_KDUMP_FILE ]]; then
		rm -f $DEPRECATED_CONFIG_FILE
	fi
}

handle_config_files_initrd_rebuild_not_required()
{
	local INITRD_REBUILD_REQD=0
	handle_config_files $INITRD_REBUILD_REQD		 \
		$DISTRO_KDUMP_CONFIG_FILE $USER_KDUMP_CONFIG_FILE \
		$TMP_KDUMP_CONFIG_FILE $BACKUP_USER_KDUMP_CONFIG_FILE \
		$DEPRECATED_KDUMP_CONFIG_FILE
	remove_deprecated_config_files $DEPRECATED_KDUMP_CONFIG_FILE \
		$USER_KDUMP_CONFIG_FILE
}

handle_config_files_initrd_rebuild_required()
{
	local INITRD_REBUILD_REQD=1
	handle_config_files $INITRD_REBUILD_REQD $DISTRO_KDUMP_FILE \
		$USER_KDUMP_FILE $TMP_KDUMP_FILE \
		$BACKUP_USER_KDUMP_FILE $DEPRECATED_KDUMP_FILE
	remove_deprecated_config_files $DEPRECATED_KDUMP_FILE \
		$USER_KDUMP_FILE
}

handle_dump_config_files()
{
	handle_config_files_initrd_rebuild_not_required
	handle_config_files_initrd_rebuild_required
}
