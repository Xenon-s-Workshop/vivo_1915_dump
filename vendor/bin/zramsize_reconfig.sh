#!/vendor/bin/sh

# use for mtk and samsung

zRamSizeMB=0
backingDevSizeM=0

function zram_writeback_config(){
	# support zram writeback?
	if [ ! -f /sys/block/zram0/backing_dev ]; then
		return
	fi

	# special project: low memory project to solve low memory ANR problems
	special_project=0
	product_version=`getprop ro.vivo.product.model`
	if [ "$product_version" == "PD1901BF_EX" ]; then
		special_project=1
	fi

	# just >rom_11.5 or special project, support zram writeback
	rom_version=`getprop ro.vivo.os.version`
	if [ `expr $rom_version \< 11.5` -eq 1 ] && [ "$special_project" == "0" ]; then
		return
	fi

	# user choice
	zram_writeback_trigger_user=`getprop persist.vendor.vivo.zramwb.enable`
	if [ "$zram_writeback_trigger_user" == "" ]; then
		zram_writeback_trigger_user=1

		# if upgrade project(except special project), default trigger is 0
		rom_first_version=`getprop ro.vivo.fist.os.version`
		if [ "$rom_first_version" == "" ] || [ `expr $rom_first_version \< 12.0` -eq 1 ]; then
			if [ "$special_project" == "0" ]; then
				zram_writeback_trigger_user=0
			fi
		fi
	fi

	# memory life > 5 then close zram writeback
	zram_writeback_trigger=$zram_writeback_trigger_user
	# for ufs or emmc
	if [ -d /sys/ufs ]; then
		life_time_a=`cat /sys/ufs/life_time_a`
		life_time_b=`cat /sys/ufs/life_time_b`
	else
		life_time_a=`cat /sys/block/mmcblk0/device/dev_left_time_a`
		life_time_b=`cat /sys/block/mmcblk0/device/dev_left_time_b`
	fi
	if [ "$life_time_a" != "0x00" ] && [ "$life_time_a" != "0x01" ] && [ "$life_time_a" != "0x02" ] && [ "$life_time_a" != "0x03" ] && [ "$life_time_a" != "0x04" ] && [ "$life_time_a" != "0x05" ]; then
		zram_writeback_trigger=0
	fi
	if [ "$life_time_b" != "0x00" ] && [ "$life_time_b" != "0x01" ] && [ "$life_time_b" != "0x02" ] && [ "$life_time_b" != "0x03" ] && [ "$life_time_b" != "0x04" ] && [ "$life_time_b" != "0x05" ]; then
		zram_writeback_trigger=0
	fi
	if [ "$special_project" == "1" ]; then
		zram_writeback_trigger_user=$zram_writeback_trigger
	fi

	# size of backing device
	if [ $zRamSizeMB -ge 4096 ]; then
		backingDevSizeM=1536
		bdSizeShow=3072
	elif [ $zRamSizeMB -ge 3072 ]; then
		backingDevSizeM=1024
		bdSizeShow=1024
	elif [ $zRamSizeMB -ge 1536 ]; then
		backingDevSizeM=512
		bdSizeShow=512
	else
		backingDevSizeM=`expr $zRamSizeMB / 3`
		bdSizeShow=$backingDevSizeM
	fi
	if [ "$special_project" == "0" ]; then
		setprop persist.vendor.vivo.zramwb.size $bdSizeShow
	fi

	# TODO: delete
	# bug fix, should re-create once
	created=`getprop persist.vendor.vivo.zramwb.created`
	if [ "$created" == "" ]; then
		rm /data/vendor/swap/zram
		setprop persist.vendor.vivo.zramwb.created 1
	fi

	# create file
	if [ "$zram_writeback_trigger_user" == "1" ] && [ ! -f /data/vendor/swap/zram ]; then
		# remaining space should bigger than the file to create.
		dataSpace=`df -k | grep /data$ | awk '{print $4}'`
		dataSpace=`expr $dataSpace / 1024`
		create_file_success=1
		if [ $dataSpace -lt $bdSizeShow ]; then
			zram_writeback_trigger=0
			create_file_success=0
		else
			# for f2fs or ext4
			is_f2fs1=`df -t f2fs | grep /data$`
			is_f2fs2=`mount -r -t f2fs | grep " /data "`
			if [ "$is_f2fs1" == "" ] && [ "$is_f2fs2" == "" ]; then
				dd if=/dev/zero of=/data/vendor/swap/zram bs=1m count=$bdSizeShow
				if [ $? -ne 0 ]; then
					zram_writeback_trigger=0
					create_file_success=0
				fi
				bdSizeShow=`expr $bdSizeShow \* 1048576`
			else
				bdSizeShow=`expr $bdSizeShow \* 1048576`
				touch /data/vendor/swap/zram
				f2fs_io pinfile set /data/vendor/swap/zram
				fallocate -l $bdSizeShow -o 0 /data/vendor/swap/zram
				if [ $? -ne 0 ]; then
					zram_writeback_trigger=0
					create_file_success=0
				fi
			fi

			fileSize=`ls -la /data/vendor/swap/zram | awk '{print $5}'`
			# overflow, cannot use lt or gt, use equal
			if [ $fileSize -ne $bdSizeShow ]; then
				zram_writeback_trigger=0
				create_file_success=0
			fi
		fi

		# if create file failed, delete the file
		if [ "$create_file_success" == "0" ]; then
			rm /data/vendor/swap/zram
		fi
	elif [ "$zram_writeback_trigger_user" == "0" ]; then
		rm /data/vendor/swap/zram
	fi

	# init for zram writeback
	if [ "$zram_writeback_trigger" == "1" ]; then
		zRamSizeMB=`expr $backingDevSizeM + $zRamSizeMB`
		echo /data/vendor/swap/zram > /sys/block/zram0/backing_dev
	fi
}

function zram_writeback_parameter_config(){
	if [ -f /sys/block/zram0/zram_wb/bd_size_limit  ]; then
		backingDevSizeLimit=`expr $backingDevSizeM \* 256`
		echo $backingDevSizeLimit > /sys/block/zram0/zram_wb/bd_size_limit
	fi
}

function zramsize_reconfig() {
	swapoff /dev/block/zram0
	echo 1 > /sys/block/zram0/reset

	zram_writeback_config
	echo "$zRamSizeMB""M" > /sys/block/zram0/disksize
	zram_writeback_parameter_config

	mkswap /dev/block/zram0
	swapon /dev/block/zram0

	echo 60 > /proc/sys/vm/swappiness
	echo 120 > /proc/sys/vm/rsc_swappiness
}

if [ ! -d /sys/block/zram0 ];then
	exit
fi

mem_size=`cat /proc/meminfo | awk '/MemTotal/ {print $2}'`

if [ "$mem_size" -lt "3145728" ];then
	zRamSizeMB=1536
elif [ "$mem_size" -lt "4194304" ];then
	zRamSizeMB=2048
elif [ "$mem_size" -lt "6291456" ];then
	zRamSizeMB=3072
else
	zRamSizeMB=4096
fi
zramsize_reconfig

