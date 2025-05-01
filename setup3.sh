#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Update CentOS repository and disable SSL verification
echo "Updating CentOS repository..."
sed -i 's/mirror.centos.org/vault.centos.org/g' /etc/yum.repos.d/*.repo
sed -i 's/^#.*baseurl=http/baseurl=http/g' /etc/yum.repos.d/*.repo
sed -i 's/^mirrorlist=http/#mirrorlist=http/g' /etc/yum.repos.d/*.repo
echo "sslverify=false" >> /etc/yum.conf
echo "Updated CentOS repository and disabled SSL verification"

# Generate random IPv6 address within the subnet
array=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
gen64() {
    ip64() {
        echo "${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}${array[$RANDOM % 16]}"
    }
    echo "$1:$(ip64):$(ip64):$(ip64):$(ip64)"
}

# Install 3proxy
install_3proxy() {
    echo "Installing 3proxy..."
    URL="https://github.com/z3APA3A/3proxy/archive/3proxy-0.8.6.tar.gz"
    wget -qO- $URL | bsdtar -xvf-
    cd 3proxy-3proxy-0.8.6
    make -f Makefile.Linux
    mkdir -p /usr/local/etc/3proxy/{bin,logs,stat}
    cp src/3proxy /usr/local/etc/3proxy/bin/
    cd $WORKDIR
    echo "3proxy installed successfully"
}

# Generate 3proxy configuration without authentication
gen_3proxy() {
    port=$1
    ip6=$2
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
auth none
allow *
proxy -6 -n -a -p$port -i$IP4 -e$ip6
flush
EOF
}

# Generate ifconfig command for IPv6
gen_ifconfig() {
    ip6=$1
    echo "ifconfig eth0 inet6 add $ip6/64"
}

# Clean old IPv6 addresses
clean_old_ips() {
    ip -6 addr flush dev eth0 scope global
    # Re-add primary IPv6
    echo "ifconfig eth0 inet6 add $IPV6ADDR/64" > $WORKDIR/boot_ifconfig.sh
    bash $WORKDIR/boot_ifconfig.sh
}

# Install required packages
echo "Installing necessary applications..."
yum -y install wget gcc net-tools bsdtar zip python3 >/dev/null

# Create rc.local if not exists
cat << EOF > /etc/rc.d/rc.local
#!/bin/bash
touch /var/lock/subsys/local
EOF
chmod +x /etc/rc.local

# Clear input buffer
stty sane
echo "" > /dev/tty

# Input IPv6 configuration
echo "Enter IPv6 information:"

# Input IPV6ADDR
while :; do
    read -p "Enter IPV6ADDR (e.g., 2001:19f0:5401:2c7::2): " IPV6ADDR
    if [ -n "$IPV6ADDR" ]; then
        echo "IPV6ADDR entered: $IPV6ADDR"
        break
    else
        echo "Please enter a valid IPV6ADDR!"
    fi
done

# Input IPV6_DEFAULTGW
while :; do
    read -p "Enter IPV6_DEFAULTGW (e.g., 2001:19f0:5401:2c7::1): " IPV6_DEFAULTGW
    if [ -n "$IPV6_DEFAULTGW" ]; then
        echo "IPV6_DEFAULTGW entered: $IPV6_DEFAULTGW"
        break
    else
        echo "Please enter a valid IPV6_DEFAULTGW!"
    fi
done

# Input number of proxies
while :; do
    read -p "Enter number of proxies to create (1-10): " NUM_PROXIES
    if [ "$NUM_PROXIES" -ge 1 ] && [ "$NUM_PROXIES" -le 10 ]; then
        echo "Number of proxies: $NUM_PROXIES"
        break
    else
        echo "Please enter a number between 1 and 10!"
    fi
done

# Configure IPv6
echo "Configuring IPv6..."
cat << EOF >> /etc/sysconfig/network-scripts/ifcfg-eth0
IPV6_FAILURE_FATAL=no
IPV6_ADDR_GEN_MODE=stable-privacy
IPV6ADDR=$IPV6ADDR
IPV6_DEFAULTGW=$IPV6_DEFAULTGW
EOF
echo "IPv6 configuration written to ifcfg-eth0"

# Restart network
echo "Restarting network..."
service network restart
echo "Network restarted, waiting 5 seconds for stability..."
sleep 5

# Test IPv6 connectivity
echo "Testing IPv6 connectivity..."
ping6 google.com.vn -c4
if [ $? -eq 0 ]; then
    echo "IPv6 connectivity successful!"
else
    echo "IPv6 connectivity failed. Please check network configuration."
    exit 1
fi

# Install 3proxy
install_3proxy

# Set up working directory
echo "Working directory = /home/cloudfly"
WORKDIR="/home/cloudfly"
mkdir -p $WORKDIR && cd $_
echo "Created working directory $WORKDIR"

# Get IP addresses
IP4=$(curl -4 -s icanhazip.com)
IP6_PREFIX=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
echo "Internal IP = ${IP4}. External IPv6 prefix = ${IP6_PREFIX}"

# Initialize proxy configurations
PROXY_PORTS=()
IP6_ADDRESSES=()
for i in $(seq 1 $NUM_PROXIES); do
    PORT=$((21000 + i - 1))
    CURRENT_IP6=$(gen64 $IP6_PREFIX)
    PROXY_PORTS+=($PORT)
    IP6_ADDRESSES+=($CURRENT_IP6)
    
    # Generate configuration for each proxy
    gen_ifconfig $CURRENT_IP6 > $WORKDIR/boot_ifconfig_$PORT.sh
    chmod +x $WORKDIR/boot_ifconfig_$PORT.sh
    bash $WORKDIR/boot_ifconfig_$PORT.sh
    
    # Generate 3proxy configuration
    gen_3proxy $PORT $CURRENT_IP6 > /usr/local/etc/3proxy/3proxy_$PORT.cfg
    
    # Start individual 3proxy instance
    /usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy_$PORT.cfg &
    
    echo "Proxy $i running on ${IP4}:${PORT} with IPv6 ${CURRENT_IP6}"
done

# Update rc.local
cat > /etc/rc.local <<EOF
#!/bin/bash
touch /var/lock/subsys/local
$(for port in "${PROXY_PORTS[@]}"; do
    echo "bash ${WORKDIR}/boot_ifconfig_${port}.sh"
    echo "ulimit -n 1000048"
    echo "/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy_${port}.cfg"
done)
EOF
chmod 0755 /etc/rc.local

# Create API server script
cat > $WORKDIR/api_server.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import subprocess
import json
import random
import urllib.parse

# Configuration
WORKDIR = "/home/cloudfly"
IP6_PREFIX = subprocess.check_output("curl -6 -s icanhazip.com | cut -f1-4 -d':'", shell=True).decode().strip()
IP4 = subprocess.check_output("curl -4 -s icanhazip.com", shell=True).decode().strip()

# Generate random IPv6
def gen_ip6(prefix):
    hex_chars = "0123456789abcdef"
    segments = [''.join(random.choice(hex_chars) for _ in range(4)) for _ in range(4)]
    return f"{prefix}:{':'.join(segments)}"

# Clean old IPs
def clean_old_ips():
    subprocess.run(["ip", "-6", "addr", "flush", "dev", "eth0", "scope", "global"])
    with open(f"{WORKDIR}/boot_ifconfig.sh", "r") as f:
        subprocess.run(f.read(), shell=True)

# Update 3proxy configuration
def update_3proxy(port, ip6):
    with open(f"/usr/local/etc/3proxy/3proxy_{port}.cfg", "w") as f:
        f.write(f"""daemon
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
auth none
allow *
proxy -6 -n -a -p{port} -i{IP4} -e{ip6}
flush
""")

# Update ifconfig script
def update_ifconfig(port, ip6):
    with open(f"{WORKDIR}/boot_ifconfig_{port}.sh", "w") as f:
        f.write(f"ifconfig eth0 inet6 add {ip6}/64\n")
    subprocess.run(["chmod", "+x", f"{WORKDIR}/boot_ifconfig_{port}.sh"])

# Restart 3proxy for specific port
def restart_3proxy(port):
    subprocess.run(["pkill", "-f", f"3proxy_{port}.cfg"])
    subprocess.run(["bash", f"{WORKDIR}/boot_ifconfig_{port}.sh"])
    subprocess.run(["/usr/local/etc/3proxy/bin/3proxy", f"/usr/local/etc/3proxy/3proxy_{port}.cfg"])

# HTTP handler
class APIHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed_path = urllib.parse.urlparse(self.path)
        query_params = urllib.parse.parse_qs(parsed_path.query)
        
        if parsed_path.path == "/rest":
            try:
                port = query_params.get('port', [None])[0]
                if not port or not port.isdigit() or int(port) < 21000 or int(port) >= 21010:
                    self.send_response(400)
                    self.send_header("Content-type", "application/json")
                    self.end_headers()
                    response = {"status": "error", "message": "Invalid or missing port parameter"}
                    self.wfile.write(json.dumps(response).encode())
                    return
                
                # Clean old IPs
                clean_old_ips()
                
                # Generate new IPv6
                new_ip6 = gen_ip6(IP6_PREFIX)
                
                # Update configurations
                update_ifconfig(port, new_ip6)
                update_3proxy(port, new_ip6)
                
                # Restart proxy
                restart_3proxy(port)
                
                # Send response
                self.send_response(200)
                self.send_header("Content-type", "application/json")
                self.end_headers()
                response = {"status": "success", "port": port, "new_ip6": new_ip6}
                self.wfile.write(json.dumps(response).encode())
            except Exception as e:
                self.send_response(500)
                self.send_header("Content-type", "application/json")
                self.end_headers()
                response = {"status": "error", "message": str(e)}
                self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()

# Start server
PORT = 8080
with socketserver.TCPServer(("0.0.0.0", PORT), APIHandler) as httpd:
    print(f"API server running on port {PORT}")
    httpd.serve_forever()
EOF

# Make API server executable
chmod +x $WORKDIR/api_server.py

# Start API server in background
nohup python3 $WORKDIR/api_server.py &

echo "Proxy setup complete!"
for i in "${!PROXY_PORTS[@]}"; do
    echo "Proxy $((i+1)) running on ${IP4}:${PROXY_PORTS[$i]} with IPv6 ${IP6_ADDRESSES[$i]}"
    echo "Rotate IP for port ${PROXY_PORTS[$i]}: curl http://${IP4}:8080/rest?port=${PROXY_PORTS[$i]}"
done
echo "API server running on port 8080"
