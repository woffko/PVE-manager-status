#!/usr/bin/env bash

# version: 2023.9.5
# Disk information toggles. Set a value to false to hide that disk type.
# NVMe disks
sNVMEInfo=true
# SATA SSD and HDD disks
sODisksInfo=true
# Debug mode: show modified snippets.
dmode=false

# Script path
sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)
cd "$sdir"

sname=$(basename "${BASH_SOURCE[0]}")
sap=$sdir/$sname
echo "Script path: $sap"

# Files to modify
np=/usr/share/perl5/PVE/API2/Nodes.pm
pvejs=/usr/share/pve-manager/js/pvemanagerlib.js
plibjs=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

if [ "$(id -u)" -ne 0 ]; then
	echo "This script must be run as root."
	exit 1
fi

if ! command -v sensors > /dev/null; then
	echo "lm-sensors and linux-cpupower are required. The script will try to install them automatically."
	if apt update ; apt install -y lm-sensors; then 
		echo "lm-sensors installed successfully"
		
		echo "Trying to install linux-cpupower for power consumption data"
		if apt install -y linux-cpupower;then
			echo "linux-cpupower installed successfully"
		else
			echo -e "linux-cpupower installation failed. Power consumption data may not work. You can install it manually with: \033[34mapt update ; apt install -y linux-cpupower && modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf && chmod +s /usr/sbin/turbostat && echo Success!\033[0m"
		fi
	else
		echo "Automatic dependency installation failed"
		echo -e "Install dependencies manually with: \033[34mapt update ; apt install -y lm-sensors linux-cpupower && chmod +s /usr/sbin/turbostat && echo Success! \033[0m Then run this script again."
		echo "Script exited"
		exit 1
	fi
fi


# Get PVE version
pvever=$(pveversion | awk -F"/" '{print $2}')
echo "Detected PVE version: $pvever"

restore() {
	[ -e $np.$pvever.bak ]     && mv $np.$pvever.bak $np
	[ -e $pvejs.$pvever.bak ]  && mv $pvejs.$pvever.bak $pvejs
	[ -e $plibjs.$pvever.bak ] && mv $plibjs.$pvever.bak $plibjs
}

fail() {
	echo "Modification failed. This may be incompatible with your PVE version: $pvever. Restoring changes."
	restore
	echo "Restore completed"
	exit 1
}

# Restore changes
case $1 in 
	restore)
		restore
		echo "Changes restored"
		
		if [ "$2" != 'remod' ];then 
			echo -e "Refresh your browser cache: \033[31mShift+F5\033[0m"
			systemctl restart pveproxy
		else 
			echo -----
		fi
		
		exit 0
	;;
	remod)
		echo "Force reapplying modifications"
		echo -----------
		"$sap" restore remod > /dev/null 
		"$sap"
		exit 0
	;;
esac

# Check whether files have already been modified
[ $(grep 'modbyshowtempfreq' $np $pvejs $plibjs | wc -l) -eq 3 ]  && {
	echo -e "
Already modified. Do not apply the patch repeatedly.
If the changes are not visible, or the page keeps loading,
refresh your browser cache with \033[31mShift+F5\033[0m.
If the page is still abnormal, run \033[31m\"$sap\" restore\033[0m to restore the original files.
To force a clean reapply, run \033[31m\"$sap\" remod\033[0m.
"
	exit 1
}


tmpfiles=()
cleanup() {
	[ ${#tmpfiles[@]} -gt 0 ] && rm -f "${tmpfiles[@]}"
}
trap cleanup EXIT

contentfornp=$(mktemp /tmp/showtempfreq.nodes.XXXXXX) || {
	echo "Cannot create a temporary file"
	exit 1
}
tmpfiles+=("$contentfornp")

[ -e /usr/sbin/turbostat ] && {
	modprobe msr
	chmod +s /usr/sbin/turbostat
}
echo msr > /etc/modules-load.d/turbostat-msr.conf

cat > "$contentfornp" << 'EOF'

#modbyshowtempfreq

$res->{thermalstate} = `timeout 2s sensors -A`;
$res->{cpuFreq} = `
	goverf=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
	maxf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq
	minf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq
	
	cat /proc/cpuinfo | grep -i  "cpu mhz"
	echo -n 'gov:'
	[ -f \$goverf ] && cat \$goverf || echo none
	echo -n 'min:'
	[ -f \$minf ] && cat \$minf || echo none
	echo -n 'max:'
	[ -f \$maxf ] && cat \$maxf || echo none
	echo -n 'pkgwatt:'
	[ -e /usr/sbin/turbostat ] && timeout 2s turbostat --quiet --cpu package --show "PkgWatt" -S sleep 0.25 2>&1 | tail -n1

`;
EOF



contentforpvejs=$(mktemp /tmp/showtempfreq.pvejs.XXXXXX) || {
	echo "Cannot create a temporary file"
	exit 1
}
tmpfiles+=("$contentforpvejs")

cat > "$contentforpvejs" << 'EOF'
//modbyshowtempfreq
	{
		itemId: 'thermal',
		colspan: 2,
		printBar: false,
		title: gettext('Temperature (°C)'),
		textField: 'thermalstate',
		renderer:function(value){
			let htmlEncode = value => String(value ?? '').replace(/[&<>"']/g, ch => ({
				'&': '&amp;',
				'<': '&lt;',
				'>': '&gt;',
				'"': '&quot;',
				"'": '&#39;',
			}[ch]));
			// The incoming value contains line breaks.
			console.log(value)
			let b = value.trim().split(/\s+(?=^\w+-)/m).sort();
			let c = b.map(function (v){
				// Fan speed data can be returned directly.
				let fandata = v.match(/(?<=:\s+)[1-9]\d*(?=\s+RPM\s+)/ig)
				if ( fandata ) {
					return 'Fan: ' + fandata.join(';')
				}
			
				let name = v.match(/^[^-]+/)[0].toUpperCase();
				
				let temp = v.match(/(?<=:\s+)[+-][\d.]+(?=.?°C)/g);
				// Some sensors do not contain temperature data.
				if ( temp ) {
					temp = temp.map(v => Number(v).toFixed(0))
					
					if (/coretemp/i.test(name)) {
						name = 'CPU';
						temp = temp[0] + ( temp.length > 1 ? ' ( ' +   temp.slice(1).join(' | ') + ' )' : '');
					} else {
						temp = temp[0];
					}
					
					let crit = v.match(/(?<=\bcrit\b[^+]+\+)\d+/);
					
					
					return htmlEncode(name) + ': ' + temp + ( crit? ` ,crit: ${crit[0]}` : '');
					
				} else {
					return 'null'
				}
				

			});
			console.log(c);
			// Remove null values.
			c=c.filter( v => ! /^null$/.test(v) )
			//console.log(c);
			// Put CPU temperature first.
			let cpuIdx = c.findIndex(v => /CPU/i.test(v) );
			if (cpuIdx > 0) {
				c.unshift(c.splice(cpuIdx, 1)[0]);
			}
			
			console.log(c)
			c = c.join(' | ');
			return c;
		 }
	},
	{
		  itemId: 'cpumhz',
		  colspan: 2,
		  printBar: false,
		  title: gettext('CPU Frequency (GHz)'),
		  textField: 'cpuFreq',
		  renderer:function(v){
			//return v;
			console.log(v);
			let m = v.match(/(?<=^cpu[^\d]+)\d+/img);
			let m2 = m.map( e => ( e / 1000 ).toFixed(1) );
			m2 = m2.join(' | ');
			
			let gov = v.match(/(?<=^gov:).+/im)[0].toUpperCase();
			
			let min = (v.match(/(?<=^min:).+/im)[0]);
			if ( min !== 'none' ) {
				min=(min/1000000).toFixed(1);
			}
			
			let max = (v.match(/(?<=^max:).+/im)[0])
			if ( max !== 'none' ) {
				max=(max/1000000).toFixed(1);
			}
			
			let watt= v.match(/(?<=^pkgwatt:)[\d.]+$/im);
			watt = watt? " | Power: " + (watt[0]/1).toFixed(1) + 'W' : '';
			
			return `${m2} | MAX: ${max} | MIN: ${min}${watt} | Governor: ${gov}`
		 }
	},
EOF


# Detect NVMe disks
echo "Detecting NVMe disks"
nvi=0
if $sNVMEInfo;then
	for nvme in $(ls /dev/nvme[0-9] 2> /dev/null); do
		chmod +s /usr/sbin/smartctl

		cat >> "$contentfornp" << EOF
	\$res->{nvme$nvi} = \`timeout 4s smartctl $nvme -a -j\`;
EOF
		
		
		cat >> "$contentforpvejs" << EOF
		{
			  itemId: 'nvme${nvi}0',
			  colspan: 2,
			  printBar: false,
			  title: gettext('NVME${nvi}'),
			  textField: 'nvme${nvi}',
			  renderer:function(value){
				let htmlEncode = value => String(value ?? '').replace(/[&<>"']/g, ch => ({
					'&': '&amp;',
					'<': '&lt;',
					'>': '&gt;',
					'"': '&quot;',
					"'": '&#39;',
				}[ch]));
				//return value;
				try{
					let  v = JSON.parse(value);
					// Name
					let model = htmlEncode(v.model_name);
					if (! model) {
						return 'Disk not found, passed through, or unmounted';
					}
					// Temperature
					let temp = v.temperature?.current;
					temp = ( temp !== undefined ) ? " | " + temp + '°C' : '' ;
					
					// Power-on time
					let pot = v.power_on_time?.hours;
					let poth = v.power_cycle_count;
					
					pot = ( pot !== undefined ) ? (" | Power-on: " + pot + 'h' + ( poth ? ', cycles: '+ poth : '' )) : '';
					
					// Read/write data
					let log = v.nvme_smart_health_information_log;
					let rw=''
					let health=''
					if (log) {
						let read = log.data_units_read;
						let write = log.data_units_written;
						read = read ? (log.data_units_read / 1956882).toFixed(1) + 'T' : '';
						write = write ? (log.data_units_written / 1956882).toFixed(1) + 'T' : '';
						if (read && write) {
							rw = ' | R/W: ' + read + '/' + write;
						}
						let pu = log.percentage_used;
						let me = log.media_errors;
						if ( pu !== undefined ) {
							health = ' | Health: ' + ( 100 - pu ) + '%'
							if ( me !== undefined ) {
								health += ',0E: ' + me
							}
						}
					}

					// SMART status
					let smart = v.smart_status?.passed;
					if (smart === undefined ) {
						smart = '';
					} else {
						smart = ' | SMART: ' + (smart ? 'OK' : 'Warning!');
					}
					
					
					let t = model  + temp + health + pot + rw + smart;
					//console.log(t);
					return t;
				}catch(e){
					return 'Unable to read valid data';
				};

			 }
		},
EOF
		let nvi++
	done
fi
echo "Added $nvi NVMe disk(s)"



# Detect SATA SSD and HDD disks
echo "Detecting SATA SSD and HDD disks"
sdi=0
if $sODisksInfo;then
	for sd in $(ls /dev/sd[a-z] 2> /dev/null);do
		chmod +s /usr/sbin/smartctl
		chmod +s /usr/sbin/hdparm
		# Check whether the device is rotational.
		sdsn=$(awk -F '/' '{print $NF}' <<< $sd)
		sdcr=/sys/block/$sdsn/queue/rotational
		[ -f $sdcr ] || continue
		
		if [ "$(cat $sdcr)" = "0" ];then
			hddisk=false
			sdtype="SSD$sdi"
		else
			hddisk=true
			sdtype="HDD$sdi"
		fi
		
		# SATA disk output logic.
		# Return an empty JSON object if the disk does not exist.

		cat >> "$contentfornp" << EOF
	\$res->{sd$sdi} = \`
		if [ -b $sd ];then
			if $hddisk && timeout 2s hdparm -C $sd | grep -iq 'standby';then
				echo '{"standy": true}'
			else
				timeout 4s smartctl $sd -a -j
			fi
		else
			echo '{}'
		fi
	\`;
EOF

		cat >> "$contentforpvejs" << EOF
		{
			  itemId: 'sd${sdi}0',
			  colspan: 2,
			  printBar: false,
			  title: gettext('${sdtype}'),
			  textField: 'sd${sdi}',
			  renderer:function(value){
				let htmlEncode = value => String(value ?? '').replace(/[&<>"']/g, ch => ({
					'&': '&amp;',
					'<': '&lt;',
					'>': '&gt;',
					'"': '&quot;',
					"'": '&#39;',
				}[ch]));
				//return value;
				try{
					let  v = JSON.parse(value);
					console.log(v)
					if (v.standy === true) {
						return 'Standby'
					}
					
					// Name
					let model = htmlEncode(v.model_name);
					if (! model) {
						return 'Disk not found, passed through, or unmounted';
					}
					// Temperature
					let temp = v.temperature?.current;
					temp = ( temp !== undefined ) ? " | Temperature: " + temp + '°C' : '' ;
					
					// Power-on time
					let pot = v.power_on_time?.hours;
					let poth = v.power_cycle_count;
					
					pot = ( pot !== undefined ) ? (" | Power-on: " + pot + 'h' + ( poth ? ', cycles: '+ poth : '' )) : '';
					
					// SMART status
					let smart = v.smart_status?.passed;
					if (smart === undefined ) {
						smart = '';
					} else {
						smart = ' | SMART: ' + (smart ? 'OK' : 'Warning!');
					}
					
					
					let t = model + temp  + pot + smart;
					//console.log(t);
					return t;
				}catch(e){
					return 'Unable to read valid data';
				};
			 }
		},
EOF
		let sdi++
	done
fi
echo "Added $sdi SATA SSD/HDD disk(s)"

echo "Modifying Nodes.pm"
if ! grep -q 'modbyshowtempfreq' $np ;then
	[ ! -e $np.$pvever.bak ] && cp $np $np.$pvever.bak
	
	if [ "$(sed -n "/PVE::pvecfg::version_text()/{=;p;q}" "$np")" ];then # Confirm patch point.
		# The sed r command needs the filename on its own line.
		sed -i "/PVE::pvecfg::version_text()/{
			r $contentfornp
		}" $np
		$dmode && sed -n "/PVE::pvecfg::version_text()/,+5p" $np
	else
		echo 'Cannot find the Nodes.pm patch point'
		
		fail
	fi
else
	echo "Already modified"
fi

echo "Modifying pvemanagerlib.js"
if ! grep -q 'modbyshowtempfreq' $pvejs ;then
	[ ! -e $pvejs.$pvever.bak ]  && cp $pvejs $pvejs.$pvever.bak
	
	if [ "$(sed -n '/pveversion/,+3{
			/},/{=;p;q}
		}' $pvejs)" ];then 
		
		sed -i "/pveversion/,+3{
			/},/r $contentforpvejs
		}" $pvejs
		
		$dmode && sed -n "/pveversion/,+8p" $pvejs
	else
		echo 'Cannot find the pvemanagerlib.js patch point'
		fail
	fi


	echo "Adjusting page height"
	# Count added status rows.
	addRs=$(grep -c '\$res' $contentfornp)
	addHei=$(( 28 * addRs))
	$dmode && echo "Added $addRs row(s), height increase: ${addHei}px"


	# Original height: 300
	echo "Adjusting left panel height"
	if [ "$(sed -n '/widget.pveNodeStatus/,+4{
			/height:/{=;p;q}
		}' $pvejs)" ]; then 
		
		# Read original height.
		wph=$(sed -n -E "/widget\.pveNodeStatus/,+4{
			/height:/{s/[^0-9]*([0-9]+).*/\1/p;q}
		}" $pvejs)
		
		sed -i -E "/widget\.pveNodeStatus/,+4{
			/height:/{
				s#[0-9]+#$(( wph + addHei))#
			}
		}" $pvejs
		
		$dmode && sed -n '/widget.pveNodeStatus/,+4{
			/height/{
				p;q
			}
		}' $pvejs

		# Match the right panel height to the left panel to avoid two-column float issues.
		# Original height: 325
		echo "Adjusting right panel height to match the left panel"
		if [ "$(sed -n '/nodeStatus:\s*nodeStatus/,+10{
				/minHeight:/{=;p;q}
			}' $pvejs)" ]; then 
			# Read original height.
			nph=$(sed -n -E '/nodeStatus:\s*nodeStatus/,+10{
				/minHeight:/{s/[^0-9]*([0-9]+).*/\1/p;q}
			}' "$pvejs")
			
			sed -i -E "/nodeStatus:\s*nodeStatus/,+10{
				/minHeight:/{
					s#[0-9]+#$(( nph + addHei - (nph - wph) ))#
				}
			}" $pvejs
			
			$dmode && sed -n '/nodeStatus:\s*nodeStatus/,+10{
				/minHeight/{
					p;q
				}
			}' $pvejs

		else
			echo "Cannot find the right panel height patch point; skipping this adjustment"
			
		fi

	else
		echo "Cannot find the height patch point"
		fail
	fi

else
	echo "Already modified"
fi


echo "Temperature, frequency, and disk information modifications completed"
echo ------------------------
echo ------------------------
echo "Modifying proxmoxlib.js"
echo "Removing subscription popup"

if ! grep -q 'modbyshowtempfreq' $plibjs ;then

	[ ! -e $plibjs.$pvever.bak ] && cp $plibjs $plibjs.$pvever.bak
	
	if [ "$(sed -n '/\/nodes\/localhost\/subscription/{=;p;q}' $plibjs)" ];then 
		sed -i '/\/nodes\/localhost\/subscription/,+10{
			/if/ {
				:loop; N;
				s/if\s*(.*)\s*{/if (false) {/;
				t done; b loop; :done;
				a //modbyshowtempfreq;
			}
		}' $plibjs
		
		$dmode && sed -n "/\/nodes\/localhost\/subscription/,+10p" $plibjs
	else 
		echo "Cannot find the patch point; skipping this change"
	fi
else
	echo "Already modified"
fi
echo -e "------------------------
Modification completed
Refresh your browser cache: \033[31mShift+F5\033[0m
If the main page shows a connection error, or temperature and frequency are missing, press \033[31mShift+F5\033[0m to refresh the browser cache.
If you are not satisfied with the result, run \033[31m\"$sap\" restore\033[0m to restore the original files.
"

systemctl restart pveproxy
