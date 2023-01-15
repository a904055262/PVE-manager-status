#!/usr/bin/env bash

#添加硬盘信息的控制变量，如果你想不显示硬盘信息就设置为0
#NVME硬盘
sNVMEInfo=1
#固态和机械硬盘
sODisksInfo=1
#debug，显示修改后的内容，用于调试
dmode=0



#脚本路径
sdir=$(cd $(dirname ${BASH_SOURCE[0]}); pwd)
sname=`awk -F '/' '{print $NF}' <<< ${BASH_SOURCE[0]}`
sap=$sdir/$sname
echo "脚本路径：$sap"

#需要修改的文件
np="/usr/share/perl5/PVE/API2/Nodes.pm"
pvejs="/usr/share/pve-manager/js/pvemanagerlib.js"
plib="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

if ! command -v sensors > /dev/null 2>&1; then
	echo 你需要先安装lm-sensors，脚本尝试给你自动安装
	if apt update && apt install -y lm-sensors; then 
		echo 安装lm-sensors成功，脚本继续执行
	else
		echo 脚本安装lm-sensors失败，请手动安装后继续执行本脚本
		echo 脚本退出
		exit 1
  fi
fi

#获取版本号
pvever=`pveversion | awk -F"/" '{print $2}'`
echo "你的PVE版本号：$pvever"

backup() {
	cp "$np" "$np.$pvever.bak"
	cp "$pvejs" "$pvejs.$pvever.bak"
	cp "$plib" "$plib.$pvever.bak"
}

restore() {
	mv "$np.$pvever.bak" "$np"
	mv "$pvejs.$pvever.bak" "$pvejs"
	mv "$plib.$pvever.bak" "$plib" 
}

fail() {
	echo "修改失败，可能不兼容你的pve版本：$pvever，开始还原"
	restore
	echo 还原完成
	exit 1
}

#还原修改
case "$1" in 
	restore)
		if [ -e "$np.$pvever.bak" ];then  
			restore
			echo 已还原修改
			
			if [ "$2" != 'remod' ];then 
				echo -e "请刷新浏览器缓存：\033[31mShift+F5\033[0m"
				systemctl restart pveproxy
			else 
				echo -----
			fi
		else
			echo 文件没有被修改过
		fi
		
		exit 0
	;;
	remod)
		echo 强制重新修改
		echo -----------
		"$sap" restore remod
		"$sap"
		exit 0
	;;
esac

#检测是否已经修改过
[ -e "$np.$pvever.bak" ] && {
	echo -e "
	已经修改过，请勿重复修改
	如果没有生效，或者页面一直转圈圈
	请使用 \033[31mShift+F5\033[0m 刷新浏览器缓存
	如果一直异常，请执行：\033[31m\"$sap\" restore\033[0m 命令，可以还原修改
	"
	exit 1
}

echo 备份源文件
backup

tmpf=.sdfadfasdf.tmp

cat > $tmpf << 'EOF'
	{
		itemId: 'thermal',
		colspan: 2,
		printBar: false,
		title: gettext('温度'),
		textField: 'thermalstate',
		renderer:function(value){
			//value进来的值是有换行符的
			
			let b = value.trim().split(/\)\s+(?=[A-z]+-)/).sort();
			let c = b.map(function (v){
				let name = v.match(/^[^-]+/)[0].toUpperCase() + ': ';
				
				let temp = v.match(/(?<=:\s+\+)[\d\.]+/g).map( v => v + '°C');
				
				if (/coretemp/i.test(name)) {
					name = 'CPU温度: ';
					temp = temp[0] + '(' +   temp.slice(1).join(', ') + ')';
				} else if (/acpitz/i.test(name)) {
					name = '主板: '
					temp = temp[0];
				} else { 
					temp = temp[0];
				}
				
				return name + temp;
			});
			//排序，把cpu温度放最前
			//console.log(c);
			
			c.unshift(c.splice(c.findIndex(v => /CPU温度/i.test(v)), 1));
			//console.log(c)
			c = c.join(' | ');
			// console.log(c);
			return c;
		 }
	},
	{
		  itemId: 'cpumhz',
		  colspan: 2,
		  printBar: false,
		  title: gettext('CPU频率'),
		  textField: 'cpure',
		  renderer:function(v){
			//return v;
			let m = v.match(/(?<=cpu[^\d]+)\d+/ig);
			let i=0
			let m2 = m.map(e =>{
				let t = `${i}: ${e}`;
				i++
				return t;
			});
			m2 = m2.join(' | ');
			let gov = v.match(/(?<=gov:\s*).+/i)[0].toUpperCase();
			let min = v.match(/(?<=min[^\d+]+)\d+/i)[0]/1000;
			let max = v.match(/(?<=max[^\d+]+)\d+/i)[0]/1000;
			return `${m2} | MAX: ${max} | MIN: ${min} | 调速器: ${gov}`
		 }
	},
EOF


tmpf0=.dfadfasdf.tmp

cat > $tmpf0 << 'EOF'
$res->{thermalstate} = `sensors`;
$res->{cpure} = `
	cat /proc/cpuinfo | grep -i  "cpu mhz"
	echo -n 'gov:'
	cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
	echo -n 'min:'
	cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq
	echo -n 'max:'
	cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq
`;
EOF

#检测nvme硬盘
echo 检测系统中的NVME硬盘
nvi=0
if [ $sNVMEInfo -eq 1 ] && ls /dev/nvme[0-9] >/dev/null 2>&1;then
	for nvme in `ls /dev/nvme[0-9]`; do
		chmod +s /usr/sbin/smartctl
		#echo '$res->{nvme'"$nvi"'} = `smartctl '"$nvme"' -a -j`;' >> $tmpf0

		cat >> $tmpf0 << EOF
	\$res->{nvme$nvi} = \`smartctl $nvme -a -j\`;
EOF
		
		
		cat >> $tmpf << EOF
		{
			  itemId: 'nvme${nvi}0',
			  colspan: 2,
			  printBar: false,
			  title: gettext('NVME硬盘${nvi}'),
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
					let temp = "温度: " + v.temperature.current + '°C';
					// 通电时间
					let pot = "通电: " + v.power_on_time.hours + '时' + ',次: '+ v.power_cycle_count;
					let log = v.nvme_smart_health_information_log;
					let read = (log.data_units_read / 1956882).toFixed(1) + 'T';
					let write = (log.data_units_written / 1956882).toFixed(1) + 'T'
					
					// smart状态
					let smart = 'SMART: ' + (v.smart_status.passed? '正常' : '警告！');
					let t = model + ' | ' + temp + ' | ' + pot + ' | ' + '读/写: ' + read + '/' + write + ' | ' + smart;
					return t;
					//console.log(t);
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
if [ $sODisksInfo -eq 1 ] && ls /dev/sd[a-z] >/dev/null 2>&1;then
	for sd in `ls /dev/sd[a-z]`;do
		chmod +s /usr/sbin/smartctl
		#检测是否是真的机械键盘
		sdsn=`echo $sd | awk -F '/' '{print $NF}'`
		sdcr=/sys/block/$sdsn/queue/rotational
		sdtype="机械硬盘$sdi"
		
		if [ ! -e $sdcr ];then
			continue
		else
			if [ "`cat $sdcr`" -eq 0 ];then 
				sdtype="固态硬盘$sdi"
			fi
		fi

		#[] && 型条件判断，嵌套的条件判断的非 || 后面一定要写动作，否则会穿透到上一层的非条件
		#机械/固态硬盘输出信息逻辑,
		#如果硬盘不存在就输出空JSON

		cat >> $tmpf0 << EOF
	\$res->{sd$sdi} = \`
		if [ -b $sd ];then
			smartctl $sd -a -j
		else
			echo '{}'
		fi
	\`;
EOF

		cat >> $tmpf << EOF
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
					//名字
					let model = v.model_name;
					if (! model) {
						return '找不到硬盘，直通或已被卸载';
					}
					// 温度
					let temp = "温度: " + v.temperature.current + '°C';
					// 通电时间
					let pot = "通电: " + v.power_on_time.hours + '时' + ',次: '+ v.power_cycle_count;
					let log = v.nvme_smart_health_information_log;
					// smart状态
					let smart = 'SMART: ' + (v.smart_status.passed? '正常' : '警告！');
					let t = model + ' | ' + temp + ' | ' + pot + ' | ' + smart;
					return t;
					//console.log(t);
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
if [ "$(sed -n "/PVE::pvecfg::version_text()/{=;p;q}" "$np")" ];then #确认修改点
	#r追加文本后面必须跟回车，否则r 后面的文字都会被当成文件名，导致脚本出错
	sed -i "/PVE::pvecfg::version_text()/{
		r $tmpf0
	}" "$np"
	[ $dmode -eq 1 ] && sed -n "/PVE::pvecfg::version_text()/,+5p" "$np"
else
	echo '找不到nodes.pm文件的修改点'
	
	fail
fi


echo 开始修改pvemanagerlib.js文件
if [ "$(sed -n '/pveversion/,+3{
		/},/{=;p;q}
	}' "$pvejs")" ];then 
	
	sed -i "/pveversion/,+3{
		/},/r $tmpf
	}" "$pvejs"
	
	[ $dmode -eq 1 ] && sed -n "/pveversion/,+8p" "$pvejs"
else
	echo '找不到pvemanagerlib.js文件的修改点'
	fail
fi

echo 修改页面高度
#统计加了几条
addRs=`grep -c '\$res' $tmpf0`
addHei=$(( 28 * addRs))
[ $dmode -eq 1 ] && echo "添加了$addRs条内容,增加高度为:${addHei}px"


#原高度300
echo 修改左栏高度
if [ "$(sed -n '/widget.pveNodeStatus/,+4{
		/height:/{=;p;q}
	}' "$pvejs")" ]; then 
	
	#获取原高度
	wph=$(sed -n -E "/widget\.pveNodeStatus/,+4{
		/height:/{s/[^0-9]*([0-9]+).*/\1/p;q}
	}" "$pvejs")
	
	sed -i -E "/widget\.pveNodeStatus/,+4{
		/height:/{
			s#[0-9]+#$(( wph + addHei))#
		}
	}" "$pvejs"
	
	[ $dmode -eq 1 ] && sed -n '/widget.pveNodeStatus/,+4{
		/height/{
			p;q
		}
	}' "$pvejs"

	#修改右边栏高度，让它和左边一样高，双栏的时候否则导致浮动出问题
	#原高度325
	echo 修改右栏高度和左栏一致，解决浮动错位
	if [ "$(sed -n '/nodeStatus:\s*nodeStatus/,+10{
			/minHeight:/{=;p;q}
		}' "$pvejs")" ]; then 
		#获取原高度
		nph=$(sed -n -E '/nodeStatus:\s*nodeStatus/,+10{
			/minHeight:/{s/[^0-9]*([0-9]+).*/\1/p;q}
		}' "$pvejs")
		
		sed -i -E "/nodeStatus:\s*nodeStatus/,+10{
			/minHeight:/{
				s#[0-9]+#$(( nph + addHei - (nph - wph) ))#
			}
		}" "$pvejs"
		
		[ $dmode -eq 1 ] && sed -n '/nodeStatus:\s*nodeStatus/,+10{
			/minHeight/{
				p;q
			}
		}' "$pvejs"

	else
		echo 右边栏高度找不到修改点，修改失败
		
	fi

else
	echo 找不到修改高度的修改点
	fail
fi




echo 温度，频率，硬盘信息相关修改已完成
echo ------------------------
echo ------------------------
echo 开始修改proxmoxlib.js文件
echo 去除订阅弹窗

if [ "$(sed -n '/\/nodes\/localhost\/subscription/{=;p;q}' "$plib")" ];then 
	sed -i '/\/nodes\/localhost\/subscription/,+10s/Ext.Msg.show/void/' "$plib" 
	
	[ $dmode -eq 1 ] && sed -n "/\/nodes\/localhost\/subscription/,+10p" "$plib"
else 
	echo 找不到修改点，放弃修改这个
fi

echo -e "------------------------
	修改完成
	请刷新浏览器缓存：\033[31mShift+F5\033[0m
	如果你看到主页面提示连接错误或者没看到温度和频率，请按：\033[31mShift+F5\033[0m，刷新浏览器缓存！
	如果你对效果不满意，请执行：\033[31m\"$sap\" restore\033[0m 命令，可以还原修改
"

systemctl restart pveproxy
