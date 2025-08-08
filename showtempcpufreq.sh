#!/usr/bin/env bash

# version: 2023.9.5
#添加硬盘信息的控制变量，如果你想不显示硬盘信息就设置为false
#NVME硬盘
sNVMEInfo=true
#固态和机械硬盘
sODisksInfo=true
#debug，显示修改后的内容，用于调试
dmode=false

#脚本路径
sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)
cd "$sdir"

sname=$(basename "${BASH_SOURCE[0]}")
sap=$sdir/$sname
echo 脚本路径："$sap"

#需要修改的文件
np=/usr/share/perl5/PVE/API2/Nodes.pm
pvejs=/usr/share/pve-manager/js/pvemanagerlib.js
plibjs=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

if ! command -v sensors > /dev/null; then
	echo 你需要先安装 lm-sensors 和 linux-cpupower，脚本尝试给你自动安装
	if apt update ; apt install -y lm-sensors; then 
		echo lm-sensors 安装成功
		
		echo 尝试继续安装linux-cpupower获取功耗信息
		if apt install -y linux-cpupower;then
			echo linux-cpupower安装成功
		else
			echo -e "linux-cpupower安装失败，可能无法正常获取功耗信息，你可以使用\033[34mapt update ; apt install linux-cpupower && modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf && chmod +s /usr/sbin/turbostat && echo 成功！\033[0m 手动安装"
		fi
	else
		echo 脚本自动安装所需依赖失败
		echo -e "请使用蓝色命令：\033[34mapt update ; apt install -y lm-sensors linux-cpupower && chmod +s /usr/sbin/turbostat && echo 成功！ \033[0m 手动安装后重新运行本脚本"
		echo 脚本退出
		exit 1
	fi
fi


#获取版本号
pvever=$(pveversion | awk -F"/" '{print $2}')
echo "你的PVE版本号：$pvever"

restore() {
	[ -e $np.$pvever.bak ]     && mv $np.$pvever.bak $np
	[ -e $pvejs.$pvever.bak ]  && mv $pvejs.$pvever.bak $pvejs
	[ -e $plibjs.$pvever.bak ] && mv $plibjs.$pvever.bak $plibjs
}

fail() {
	echo "修改失败，可能不兼容你的pve版本：$pvever，开始还原"
	restore
	echo 还原完成
	exit 1
}

#还原修改
case $1 in 
	restore)
		restore
		echo 已还原修改
		
		if [ "$2" != 'remod' ];then 
			echo -e "请刷新浏览器缓存：\033[31mShift+F5\033[0m"
			systemctl restart pveproxy
		else 
			echo -----
		fi
		
		exit 0
	;;
	remod)
		echo 强制重新修改
		echo -----------
		"$sap" restore remod > /dev/null 
		"$sap"
		exit 0
	;;
esac

#检测是否已经修改过
[ $(grep 'modbyshowtempfreq' $np $pvejs $plibjs | wc -l) -eq 3 ]  && {
	echo -e "
已经修改过，请勿重复修改
如果没有生效，或者页面一直转圈圈
请使用 \033[31mShift+F5\033[0m 刷新浏览器缓存
如果一直异常，请执行：\033[31m\"$sap\" restore\033[0m 命令，可以还原修改
如果想强制重新修改，请执行：\033[31m\"$sap\" remod\033[0m 命令，可以还原修改
"
	exit 1
}


contentfornp=/tmp/.contentfornp.tmp

[ -e /usr/sbin/turbostat ] && {
	modprobe msr
	chmod +s /usr/sbin/turbostat
}
echo msr > /etc/modules-load.d/turbostat-msr.conf

cat > $contentfornp << 'EOF'

#modbyshowtempfreq

$res->{thermalstate} = `sensors -A`;
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
	[ -e /usr/sbin/turbostat ] && turbostat --quiet --cpu package --show "PkgWatt" -S sleep 0.25 2>&1 | tail -n1 

`;
EOF



contentforpvejs=/tmp/.contentforpvejs.tmp

cat > $contentforpvejs << 'EOF'
//modbyshowtempfreq
	{
		itemId: 'thermal',
		colspan: 2,
		printBar: false,
		title: gettext('温度(°C)'),
		textField: 'thermalstate',
		renderer:function(value){
			//value进来的值是有换行符的
			console.log(value)
			let b = value.trim().split(/\s+(?=^\w+-)/m).sort();
			let c = b.map(function (v){
				// 风扇转速数据，直接返回
				let fandata = v.match(/(?<=:\s+)[1-9]\d*(?=\s+RPM\s+)/ig)
				if ( fandata ) {
					return '风扇: ' + fandata.join(';')
				}
			
				let name = v.match(/^[^-]+/)[0].toUpperCase();
				
				let temp = v.match(/(?<=:\s+)[+-][\d.]+(?=.?°C)/g);
				// 某些没有数据的传感器,不是温度的传感器
				if ( temp ) {
					temp = temp.map(v => Number(v).toFixed(0))
					
					if (/coretemp/i.test(name)) {
						name = 'CPU';
						temp = temp[0] + ( temp.length > 1 ? ' ( ' +   temp.slice(1).join(' | ') + ' )' : '');
					} else {
						temp = temp[0];
					}
					
					let crit = v.match(/(?<=\bcrit\b[^+]+\+)\d+/);
					
					
					return name + ': ' + temp + ( crit? ` ,crit: ${crit[0]}` : '');
					
				} else {
					return 'null'
				}
				

			});
			console.log(c);
			// 排除null值的
			c=c.filter( v => ! /^null$/.test(v) )
			//console.log(c);
			//排序，把cpu温度放最前
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
		  title: gettext('CPU频率(GHz)'),
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
			watt = watt? " | 功耗: " + (watt[0]/1).toFixed(1) + 'W' : '';
			
			return `${m2} | MAX: ${max} | MIN: ${min}${watt} | 调速器: ${gov}`
		 }
	},
EOF


#检测nvme硬盘
echo 检测系统中的NVME硬盘
nvi=0
if $sNVMEInfo;then
	for nvme in $(ls /dev/nvme[0-9] 2> /dev/null); do
		chmod +s /usr/sbin/smartctl

		cat >> $contentfornp << EOF
	\$res->{nvme$nvi} = \`smartctl $nvme -a -j\`;
EOF
		
		
		cat >> $contentforpvejs << EOF
		{
			  itemId: 'nvme${nvi}0',
			  colspan: 2,
			  printBar: false,
			  title: gettext('NVME${nvi}'),
			  textField: 'nvme${nvi}',
			  renderer:function(value){
				//return value;
				try{
					let  v = JSON.parse(value);
					//名字
					let model = v.model_name;
					if (! model) {
						return '找不到硬盘，直通或已被卸载';
					}
					// 温度
					let temp = v.temperature?.current;
					temp = ( temp !== undefined ) ? " | " + temp + '°C' : '' ;
					
					// 通电时间
					let pot = v.power_on_time?.hours;
					let poth = v.power_cycle_count;
					
					pot = ( pot !== undefined ) ? (" | 通电: " + pot + '时' + ( poth ? ',次: '+ poth : '' )) : '';
					
					// 读写
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
							health = ' | 健康: ' + ( 100 - pu ) + '%'
							if ( me !== undefined ) {
								health += ',0E: ' + me
							}
						}
					}

					// smart状态
					let smart = v.smart_status?.passed;
					if (smart === undefined ) {
						smart = '';
					} else {
						smart = ' | SMART: ' + (smart ? '正常' : '警告!');
					}
					
					
					let t = model  + temp + health + pot + rw + smart;
					//console.log(t);
					return t;
				}catch(e){
					return '无法获得有效消息';
				};

			 }
		},
EOF
		let nvi++
	done
fi
echo "已添加 $nvi 块NVME硬盘"



#检测机械键盘
echo 检测系统中的SATA固态和机械硬盘
sdi=0
if $sODisksInfo;then
	for sd in $(ls /dev/sd[a-z] 2> /dev/null);do
		chmod +s /usr/sbin/smartctl
		chmod +s /usr/sbin/hdparm
		#检测是否是真的机械键盘
		sdsn=$(awk -F '/' '{print $NF}' <<< $sd)
		sdcr=/sys/block/$sdsn/queue/rotational
		[ -f $sdcr ] || continue
		
		if [ "$(cat $sdcr)" = "0" ];then
			hddisk=false
			sdtype="固态硬盘$sdi"
		else
			hddisk=true
			sdtype="机械硬盘$sdi"
		fi
		
		#[] && 型条件判断，嵌套的条件判断的非 || 后面一定要写动作，否则会穿透到上一层的非条件
		#机械/固态硬盘输出信息逻辑,
		#如果硬盘不存在就输出空JSON

		cat >> $contentfornp << EOF
	\$res->{sd$sdi} = \`
		if [ -b $sd ];then
			if $hddisk && hdparm -C $sd | grep -iq 'standby';then
				echo '{"standy": true}'
			else
				smartctl $sd -a -j
			fi
		else
			echo '{}'
		fi
	\`;
EOF

		cat >> $contentforpvejs << EOF
		{
			  itemId: 'sd${sdi}0',
			  colspan: 2,
			  printBar: false,
			  title: gettext('${sdtype}'),
			  textField: 'sd${sdi}',
			  renderer:function(value){
				//return value;
				try{
					let  v = JSON.parse(value);
					console.log(v)
					if (v.standy === true) {
						return '休眠中'
					}
					
					//名字
					let model = v.model_name;
					if (! model) {
						return '找不到硬盘，直通或已被卸载';
					}
					// 温度
					let temp = v.temperature?.current;
					temp = ( temp !== undefined ) ? " | 温度: " + temp + '°C' : '' ;
					
					// 通电时间
					let pot = v.power_on_time?.hours;
					let poth = v.power_cycle_count;
					
					pot = ( pot !== undefined ) ? (" | 通电: " + pot + '时' + ( poth ? ',次: '+ poth : '' )) : '';
					
					// smart状态
					let smart = v.smart_status?.passed;
					if (smart === undefined ) {
						smart = '';
					} else {
						smart = ' | SMART: ' + (smart ? '正常' : '警告!');
					}
					
					
					let t = model + temp  + pot + smart;
					//console.log(t);
					return t;
				}catch(e){
					return '无法获得有效消息';
				};
			 }
		},
EOF
		let sdi++
	done
fi
echo "已添加 $sdi 块SATA固态和机械硬盘"

echo 开始修改nodes.pm文件
if ! grep -q 'modbyshowtempfreq' $np ;then
	[ ! -e $np.$pvever.bak ] && cp $np $np.$pvever.bak
	
	if [ "$(sed -n "/PVE::pvecfg::version_text()/{=;p;q}" "$np")" ];then #确认修改点
		#r追加文本后面必须跟回车，否则r 后面的文字都会被当成文件名，导致脚本出错
		sed -i "/PVE::pvecfg::version_text()/{
			r $contentfornp
		}" $np
		$dmode && sed -n "/PVE::pvecfg::version_text()/,+5p" $np
	else
		echo '找不到nodes.pm文件的修改点'
		
		fail
	fi
else
	echo 已经修改过
fi

echo 开始修改pvemanagerlib.js文件
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
		echo '找不到pvemanagerlib.js文件的修改点'
		fail
	fi


	echo 修改页面高度
	#统计加了几条
	addRs=$(grep -c '\$res' $contentfornp)
	addHei=$(( 28 * addRs))
	$dmode && echo "添加了$addRs条内容,增加高度为:${addHei}px"


	#原高度300
	echo 修改左栏高度
	if [ "$(sed -n '/widget.pveNodeStatus/,+4{
			/height:/{=;p;q}
		}' $pvejs)" ]; then 
		
		#获取原高度
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

		#修改右边栏高度，让它和左边一样高，双栏的时候否则导致浮动出问题
		#原高度325
		echo 修改右栏高度和左栏一致，解决浮动错位
		if [ "$(sed -n '/nodeStatus:\s*nodeStatus/,+10{
				/minHeight:/{=;p;q}
			}' $pvejs)" ]; then 
			#获取原高度
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
			echo 右边栏高度找不到修改点，修改失败
			
		fi

	else
		echo 找不到修改高度的修改点
		fail
	fi

else
	echo 已经修改过
fi


echo 温度，频率，硬盘信息相关修改已完成
echo ------------------------
echo ------------------------
echo 开始修改proxmoxlib.js文件
echo 去除订阅弹窗

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
		echo 找不到修改点，放弃修改这个
	fi
else
	echo 已经修改过
fi
echo -e "------------------------
修改完成
请刷新浏览器缓存：\033[31mShift+F5\033[0m
如果你看到主页面提示连接错误或者没看到温度和频率，请按：\033[31mShift+F5\033[0m，刷新浏览器缓存！
如果你对效果不满意，请执行：\033[31m\"$sap\" restore\033[0m 命令，可以还原修改
"

systemctl restart pveproxy
