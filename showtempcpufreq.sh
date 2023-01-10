#!/usr/bin/env bash

#debug，显示修改后的内容，用于调试
dmode=0

#需要修改的文件
np="/usr/share/perl5/PVE/API2/Nodes.pm"
pvejs="/usr/share/pve-manager/js/pvemanagerlib.js"
plib="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

if ! sensors > /dev/null 2>&1; then
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
pvever=$(pveversion | awk -F"/" '{print $2}')
echo 你的PVE版本号：$pvever

backup() {
	cp $np $np.$pvever.bak
	cp $pvejs $pvejs.$pvever.bak
	cp $plib $plib.$pvever.bak
}

restore() {
	mv $np.$pvever.bak $np
	mv $pvejs.$pvever.bak $pvejs
	mv $plib.$pvever.bak $plib 
}

fail() {
	echo 修改失败，可能不兼容你的pve版本：$pvever，开始还原
	restore
	exit 1
}

#还原修改
case "$1" in 
	"restore")
		[ -e $np.$pvever.bak ] && {
			restore
			echo 已还原修改
			echo "请刷新浏览器缓存：Shift+F5"
			systemctl restart pveproxy
		} || {
			echo 文件没有被修改过
		}
		exit 0
	;;
esac

#检测是否已经修改过
[ -e $np.$pvever.bak ] && {
	echo 已经修改过，请勿重复修改
	echo 如果没有生效，或者页面一直转圈圈
	echo 请使用 shift+F5 刷新浏览器缓存
	echo 如果你想还原修改，请执行脚本加上 restore 参数
	exit 1
}
 
echo 备份源文件
backup

tmpf=.sdfadfasdf.tmp
touch $tmpf
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
				let name = v.match(/^[^-]+/)[0] + ': ';
				
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
		  renderer:function(value){
			const m = value.match(/(?<=:\s+)\d+/g);
			const m2 = m.map(e => e + 'MHz');
			return m2.join(' | ');
		 }
	},
EOF


tmpf0=.dfadfasdf.tmp
touch $tmpf0
echo '$res->{thermalstate} = `sensors`;' > $tmpf0
echo '$res->{cpure} = `cat /proc/cpuinfo | grep -i  "cpu mhz"`;' >> $tmpf0


#检测nvme硬盘
nvi=0
for nvme in `ls /dev/nvme[0-9]`;do
	chmod +s /usr/sbin/smartctl
	echo '$res->{nvme'"$nvi"'} = `smartctl '"$nvme"' -a -j`;' >> $tmpf0

	cat >> $tmpf << EOF
	{
		  itemId: 'nvme${nvi}0',
		  colspan: 2,
		  printBar: false,
		  title: gettext('nvme硬盘'),
		  textField: 'nvme${nvi}',
		  renderer:function(value){
				//return value;
			try{
				let  v = JSON.parse(value);
				//名字
				let model = v.model_name;
				if (! model) {
					return '无权限访问这块硬盘信息'
				}
				// 温度
				let temp = "温度：" + v.temperature.current;
				// 通电时间
				let pot = "通电时间：" + v.power_on_time.hours + '小时' + ',次数：'+ v.power_cycle_count;
				let log = v.nvme_smart_health_information_log;
				// smart状态
				let smart = 'SMART状态：' + (v.smart_status.passed? '正常' : '失败');
				let t = model + '|' + temp + '|' + pot + '|' + smart;
				return t;
				//console.log(t);
			}
			catch(e){
				return '无法获得有效消息';
			};

		 }
	},
EOF
	let nvi++
done


echo 开始修改nodes.pm文件
if [ "$(sed -n "/PVE::pvecfg::version_text()/{=;p;q}" $np)" ];then #确认修改点
	#r追加文本后面必须跟回车，否则r 后面的文字都会被当成文件名，导致脚本出错
	sed -i "/PVE::pvecfg::version_text()/{r $tmpf0
	}" $np
	[ $dmode -eq 1 ] && sed -n "/PVE::pvecfg::version_text()/,+5p" $np
else
	echo '找不到nodes.pm文件的修改点'
	
	fail
fi


echo 开始修改pvemanagerlib.js文件
if [ "$(sed -n "/pveversion/{=;p;q}" $pvejs)" ];then #确认修改点
	#r追加文本后面必须跟回车，否则r 后面的文字都会被当成文件名，导致脚本出错
	sed -i "/pveversion/,+3{/},/r $tmpf
	}" $pvejs
	
	[ $dmode -eq 1 ] && sed -n "/pveversion/,+8p" $pvejs
	#rm $tmpf
else
	echo '找不到pvemanagerlib.js文件的修改点'
	#rm $tmpf
	fail
fi

echo 修改页面高度
#统计添加了几行
addRs=`awk 'END{print NR}' $tmpf0`
addHei=$(( 30 * addRs))

#原高度300
if [ "$(sed -n "/widget.pveNodeStatus/{=;p;q}" $pvejs)" ]; then 
	sed -i -E "/widget\.pveNodeStatus/,+4{/height:/{s#[0-9]+#$(( 300 + addHei))#}}" $pvejs
	
	[ $dmode -eq 1 ] && sed -n "/widget.pveNodeStatus/,+4p" $pvejs
else
	echo 找不到修改高度的修改点
	fail
fi

#原高度400
if [ "$(sed -n "/\[logView\]/{=;p;q}" $pvejs)" ]; then 
	sed -i -E "/\[logView\]/,+4{/height:/{s#[0-9]+#$(( 400 + addHei))#}}" $pvejs
	
	[ $dmode -eq 1 ] && sed -n "/\[logView\]/,+4p" $pvejs
else
	echo 找不到修改高度的修改点
	fail
fi

echo 温度，频率相关修改已完成
echo ------------------------
echo ------------------------
echo 开始修改proxmoxlib.js文件
echo 去除订阅弹窗

if [ "$(sed -n '/\/nodes\/localhost\/subscription/{=;p;q}' $plib)" ];then 
	sed -i '/\/nodes\/localhost\/subscription/,+10s/Ext.Msg.show/void/' $plib 
	
	[ $dmode -eq 1 ] && sed -n "/\/nodes\/localhost\/subscription/,+10p" $plib 
else 
	echo 找不到修改点，放弃修改这个
fi


echo "修改完成"
echo "请刷新浏览器缓存：Shift+F5"
echo "如果你看到主页面提示连接错误或者没看到温度和频率，请按：Shift+F5，刷新浏览器缓存！"
echo "如果你对效果不满意，请给脚本加上 restore 参数运行，可以还原修改"

sleep 1s && systemctl restart pveproxy


