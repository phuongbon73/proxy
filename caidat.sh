#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Đường dẫn file log
LOGFILE="/home/cloudfly/install_log.txt"
echo "Bắt đầu cài đặt - $(date)" > $LOGFILE

# Cập nhật kho CentOS và tắt xác thực SSL
echo "Đang cập nhật kho CentOS..." | tee -a $LOGFILE
sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/*.repo
sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/*.repo
sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/*.repo
echo "sslverify=false" >> /etc/yum.conf
echo "Đã cập nhật kho CentOS và tắt SSL verify" | tee -a $LOGFILE

random() {
    tr </dev/urandom -dc A-Za-z0-9 | head -c12
    echo
}

array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

install_3proxy() {
    echo "Đang cài đặt 3proxy..." | tee -a $LOGFILE
    URL="https://github.com/z3APA3A/3proxy/archive/3proxy-0.8.6.tar.gz"
    wget -qO- $URL | bsdtar -xvf- >> $LOGFILE 2>&1
    cd 3proxy-3proxy-0.8.6
    make -f Makefile.Linux >> $LOGFILE 2>&1
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
    echo "Đã cài đặt 3proxy thành công" | tee -a $LOGFILE
}

gen_3proxy() {
    cat <<EOF
daemon
maxconn 2000
nserver 1.1.1.1
nserver 8.8.4.4
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456 
flush
auth strong

users $(awk -F "/" 'BEGIN{ORS="";} {print $1 ":CL:" $2 " "}' ${WORKDATA})

$(awk -F "/" '{print "auth strong\n" \
"allow " $1 "\n" \
"proxy -6 -n -a -p" $4 " -i" $3 " -e"$5"\n" \
"flush\n"}' ${WORKDATA})
EOF
}

gen_proxy_file_for_user() {
    cat >proxy.txt <<EOF
$(awk -F "/" '{print $3 ":" $4 ":" $1 ":" $2 }' ${WORKDATA})
EOF
    echo "Đã tạo file proxy.txt với danh sách proxy" | tee -a $LOGFILE
}

gen_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "user$port/$(random)/$IP4/$port/$(gen64 $IP6)"
    done
}

gen_iptables() {
    cat <<EOF
    $(awk -F "/" '{print "iptables -I INPUT -p tcp --dport " $4 "  -m state --state NEW -j ACCEPT"}' ${WORKDATA}) 
EOF
}

gen_ifconfig() {
    cat <<EOF
$(awk -F "/" '{print "ifconfig eth0 inet6 add " $5 "/64"}' ${WORKDATA})
EOF
}

echo "Đang cài đặt các ứng dụng cần thiết..." | tee -a $LOGFILE
yum -y install wget gcc net-tools bsdtar zip >> $LOGFILE 2>&1

cat << EOF > /etc/rc.d/rc.local
#!/bin/bash
touch /var/lock/subsys/local
EOF

# Nhập cấu hình IPv6 từ người dùng
echo "Nhập thông tin IPv6:" | tee -a $LOGFILE
read -p "Nhập IPV6ADDR (ví dụ: 2001:19f0:5401:2c7::2): " IPV6ADDR
read -p "Nhập IPV6_DEFAULTGW (ví dụ: 2001:19f0:5401:2c7::1): " IPV6_DEFAULTGW
echo "IPV6ADDR: $IPV6ADDR, IPV6_DEFAULTGW: $IPV6_DEFAULTGW" | tee -a $LOGFILE

# Cấu hình IPv6
echo "Đang cấu hình IPv6..." | tee -a $LOGFILE
cat << EOF >> /etc/sysconfig/network-scripts/ifcfg-eth0
IPV6_FAILURE_FATAL=no
IPV6_ADDR_GEN_MODE=stable-privacy
IPV6ADDR=$IPV6ADDR
IPV6_DEFAULTGW=$IPV6_DEFAULTGW
EOF
echo "Đã ghi cấu hình IPv6 vào ifcfg-eth0" | tee -a $LOGFILE

# Khởi động lại mạng
echo "Đang khởi động lại mạng..." | tee -a $LOGFILE
service network restart >> $LOGFILE 2>&1

# Kiểm tra kết nối IPv6
echo "Đang kiểm tra kết nối IPv6..." | tee -a $LOGFILE
ping6 google.com.vn -c4 >> $LOGFILE 2>&1
if [ $? -eq 0 ]; then
    echo "Kết nối IPv6 thành công!" | tee -a $LOGFILE
else
    echo "Kết nối IPv6 thất bại. Vui lòng kiểm tra cấu hình mạng." | tee -a $LOGFILE
    exit 1
fi

echo "Đang cài đặt lại các ứng dụng cần thiết..." | tee -a $LOGFILE
yum -y install wget gcc net-tools bsdtar zip >> $LOGFILE 2>&1

install_3proxy

echo "Thư mục làm việc = /home/cloudfly" | tee -a $LOGFILE
WORKDIR="/home/cloudfly"
WORKDATA="${WORKDIR}/data.txt"
mkdir $WORKDIR && cd $_
echo "Đã tạo thư mục làm việc $WORKDIR" | tee -a $LOGFILE

IP4=$(curl -4 -s icanhazip.com)
IP6=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
echo "IP nội bộ = ${IP4}. IP6 bên ngoài = ${IP6}" | tee -a $LOGFILE

FIRST_PORT=21000
MAX_PORT=61000
MAX_PROXIES=$((MAX_PORT - FIRST_PORT + 1))

while :; do
    read -p "Nhập số lượng proxy cần tạo (1-$MAX_PROXIES): " PROXY_COUNT
    [[ $PROXY_COUNT =~ ^[0-9]+$ ]] || { echo "Vui lòng nhập số hợp lệ"; continue; }
    if ((PROXY_COUNT >= 1 && PROXY_COUNT <= MAX_PROXIES)); then
        echo "OK! Sẽ tạo $PROXY_COUNT proxy" | tee -a $LOGFILE
        break
    else
        echo "Số lượng không trong khoảng (1-$MAX_PROXIES), thử lại"
    fi
done

LAST_PORT=$((FIRST_PORT + PROXY_COUNT - 1))
echo "Bắt đầu từ port $FIRST_PORT đến $LAST_PORT. Tiếp tục..." | tee -a $LOGFILE

echo "Đang tạo dữ liệu proxy..." | tee -a $LOGFILE
gen_data >$WORKDIR/data.txt
gen_iptables >$WORKDIR/boot_iptables.sh
gen_ifconfig >$WORKDIR/boot_ifconfig.sh
chmod +x boot_*.sh /etc/rc.local
echo "Đã tạo file dữ liệu và script khởi động" | tee -a $LOGFILE

echo "Đang tạo cấu hình 3proxy..." | tee -a $LOGFILE
gen_3proxy >/usr/local/etc/3proxy/3proxy.cfg

cat >>/etc/rc.local <<EOF
bash ${WORKDIR}/boot_iptables.sh
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 1000048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF
chmod 0755 /etc/rc.local
bash /etc/rc.local
echo "Đã cấu hình rc.local và khởi động proxy" | tee -a $LOGFILE

gen_proxy_file_for_user

echo "Hoàn tất tạo proxy. Danh sách proxy được lưu tại proxy.txt" | tee -a $LOGFILE
echo "Đang khởi động Proxy..." | tee -a $LOGFILE
echo "Kết thúc cài đặt - $(date)" >> $LOGFILE
