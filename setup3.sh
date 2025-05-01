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
$(awk -F "/" '{print "proxy -6 -n -a -p" $1 " -i" $2 " -e" $3}' ${WORKDIR}/proxy_data.txt)
flush
EOF
}

# Generate ifconfig commands for all IPv6 addresses
gen_ifconfig() {
    awk -F "/" '{print "ifconfig eth0 inet6 add " $3 "/64"}' ${WORKDIR}/proxy_data.txt > $WORKDIR/boot_ifconfig.sh
    chmod +x $WORKDIR/boot_ifconfig.sh
}

# Generate proxy data (port, IPv4, IPv6)
gen_proxy_data() {
    seq $FIRST_PORT $LAST_PORT | while read port; do
        echo "$port/$IP4/$(gen64 $IP6_PREFIX)"
    done > $WORKDIR/proxy_data.txt
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
FIRST_PORT=21000
MAX_PORT=61000
MAX_PROXIES=$((MAX_PORT - FIRST_PORT + 1))
while :; do
    read -p "Enter number of proxies to create (1-$MAX_PROXIES): " PROXY_COUNT
    if [[ $PROXY_COUNT =~ ^[0-9]+$ ]] && [ $PROXY_COUNT -ge 1 ] && [ $PROXY_COUNT -le $MAX_PROXIES ]; then
        echo "Will create $PROXY_COUNT proxies"
        break
    else
        echo "Please enter a valid number between 1 and $MAX_PROXIES"
    fi
done
LAST_PORT=$((FIRST_PORT + PROXY_COUNT - 1))
echo "Creating proxies from port $FIRST_PORT to $LAST_PORT..."

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
WORKDIR="/home/cloudfly"
mkdir -p $WORKDIR && cd $_
echo "Created working directory $WORKDIR"

# Get IP addresses
IP4=$(curl -4 -s icanhazip.com)
IP6_PREFIX=$(curl -6 -s icanhazip.com | cut -f1-4 -d':')
echo "Internal IP = ${IP4}. External IPv6 prefix = ${IP6_PREFIX}"

# Generate proxy data
gen_proxy_data
gen_ifconfig
gen_3proxy > /usr/local/etc/3proxy/3proxy.cfg

# Apply IPv6 configurations
bash $WORKDIR/boot_ifconfig.sh
echo "Applied IPv6 configurations"

# Set up rc.local to start 3proxy
cat >> /etc/rc.local <<EOF
bash ${WORKDIR}/boot_ifconfig.sh
ulimit -n 1000048
/usr/local/etc/3proxy/bin/3proxy /usr/local/etc/3proxy/3proxy.cfg
EOF
chmod 0755 /etc/rc.local

# Start 3proxy
bash /etc/rc.local
echo "Started 3proxy"

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
PROXY_DATA_FILE = f"{WORKDIR}/proxy_data.txt"
IP6_PREFIX = subprocess.check_output("curl -6 -s icanhazip.com | cut -f1-4 -d':'", shell=True).decode().strip()
IP4 = subprocess.check_output("curl -4 -s icanhazip.com", shell=True).decode().strip()

# Generate random IPv6
def gen_ip6(prefix):
    hex_chars = "0123456789abcdef"
    segments = [''.join(random.choice(hex_chars) for _ in range(4)) for _ in range(4)]
    return f"{prefix}:{':'.join(segments)}"

# Update proxy data for a specific port or all
def update_proxy_data(port=None):
    proxies = []
    with open(PROXY_DATA_FILE, "r") as f:
        proxies = f.readlines()
    
    new_proxies = []
    for proxy in proxies:
        parts = proxy.strip().split("/")
        current_port, ip4, _ = parts
        if port is None or current_port == port:
            new_ip6 = gen_ip6(IP6_PREFIX)
            new_proxies.append(f"{current_port}/{ip4}/{new_ip6}")
        else:
            new_proxies.append(proxy.strip())
    
    with open(PROXY_DATA_FILE, "w") as f:
        f.write("\n".join(new_proxies))
    return [p.split("/")[2] for p in new_proxies if port is None or p.startswith(port)]

# Update 3proxy configuration
def update_3proxy():
    proxies = []
    with open(PROXY_DATA_FILE, "r") as f:
        proxies = f.readlines()
    
    with open("/usr/local/etc/3proxy/3proxy.cfg", "w") as f:
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
""")
        for proxy in proxies:
            port, ip4, ip6 = proxy.strip().split("/")
            f.write(f"proxy -6 -n -a -p{port} -i{ip4} -e{ip6}\n")
        f.write("flush\n")

# Update ifconfig script
def update_ifconfig():
    with open(f"{WORKDIR}/boot_ifconfig.sh", "w") as f:
        f.write("#!/bin/sh\n")
        with open(PROXY_DATA_FILE, "r") as pf:
            for line in pf:
                ip6 = line.strip().split("/")[2]
                f.write(f"ifconfig eth0 inet6 add {ip6}/64\n")
    subprocess.run(["chmod", "+x", f"{WORKDIR}/boot_ifconfig.sh"])

# Restart 3proxy
def restart_3proxy():
    subprocess.run(["pkill", "3proxy"])
    subprocess.run(["bash", f"{WORKDIR}/boot_ifconfig.sh"])
    subprocess.run(["/usr/local/etc/3proxy/bin/3proxy", "/usr/local/etc/3proxy/3proxy.cfg"])

# HTTP handler
class APIHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed_path = urllib.parse.urlparse(self.path)
        if parsed_path.path == "/rest":
            try:
                query_params = urllib.parse.parse_qs(parsed_path.query)
                port = query_params.get("port", [None])[0]
                
                if port:
                    # Validate port
                    with open(PROXY_DATA_FILE, "r") as f:
                        ports = [line.split("/")[0] for line in f]
                    if port not in ports:
                        self.send_response(400)
                        self.send_header("Content-type", "application/json")
                        self.end_headers()
                        response = {"status": "error", "message": f"Port {port} not found"}
                        self.wfile.write(json.dumps(response).encode())
                        return
                
                # Update proxy data
                new_ips = update_proxy_data(port)
                
                # Update configurations
                update_ifconfig()
                update_3proxy()
                
                # Restart proxy
                restart_3proxy()
                
                # Send response
                self.send_response(200)
                self.send_header("Content-type", "application/json")
                self.end_headers()
                response = {"status": "success", "updated_ips": new_ips}
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
echo "Created $PROXY_COUNT proxies from port $FIRST_PORT to $LAST_PORT"
echo "API server running on port 8080."
echo "Reset all proxies: curl http://${IP4}:8080/rest"
echo "Reset specific proxy: curl http://${IP4}:8080/rest?port=<port>"
