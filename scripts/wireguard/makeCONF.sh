#!/bin/bash

setupVars="/etc/pivpn/wireguard/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

source "${setupVars}"

helpFunc(){
    echo "::: Create a client conf profile"
    echo ":::"
    echo "::: Usage: pivpn <-a|add> [-n|--name <arg>] [-h|--help]"
    echo ":::"
    echo "::: Commands:"
    echo ":::  [none]               Interactive mode"
    echo ":::  -n,--name            Name for the Client (default: '$HOSTNAME')"
    echo ":::  -h,--help            Show this help dialog"
}

validIP(){
	local ip=$1
	local stat=1

	if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
		OIFS=$IFS
		IFS='.'
		read -r -a ip <<< "$ip"
		IFS=$OIFS
		[[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
		&& ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
		stat=$?
	fi
	return $stat
}

# Parse input arguments
while test $# -gt 0; do
    _key="$1"
    case "$_key" in
        -n|--name|--name=*)
            _val="${_key##--name=}"
            if test "$_val" = "$_key"; then
                test $# -lt 2 && echo "::: Missing value for the optional argument '$_key'." && exit 1
                _val="$2"
                shift
            fi
            CLIENT_NAME="$_val"
            ;;
        -ip|--ip-address)
            if validIP $2 ; then
		echo "ip $2 valid"
		custIP="$2"
		shift
	    else
		echo "$2 is not a valid ip, aborting"
		exit 0
	    fi
            ;;
        -h|--help)
            helpFunc
            exit 0
            ;;
        *)
            echo "::: Error: Got an unexpected argument '$1'"
            helpFunc
            exit 1
            ;;
    esac
    shift
done

# The home folder variable was sourced from the settings file.
if [ ! -d "${install_home}/configs" ]; then
    mkdir "${install_home}/configs"
    chown "${install_user}":"${install_user}" "${install_home}/configs"
    chmod 0750 "${install_home}/configs"
fi

cd /etc/wireguard

if [ -z "${CLIENT_NAME}" ]; then
    read -r -p "Enter a Name for the Client: " CLIENT_NAME
fi

if [[ "${CLIENT_NAME}" =~ [^a-zA-Z0-9.@_-] ]]; then
    echo "Name can only contain alphanumeric characters and these characters (.-@_)."
    exit 1
fi

if [[ "${CLIENT_NAME}" =~ ^[0-9]+$ ]]; then
    echo "Names cannot be integers."
    exit 1
fi

if [ -z "${CLIENT_NAME}" ]; then
    echo "::: You cannot leave the name blank."
    exit 1
fi

if [ -f "configs/${CLIENT_NAME}.conf" ]; then
    echo "::: A client with this name already exists"
    exit 1
fi

wg genkey | tee "keys/${CLIENT_NAME}_priv" | wg pubkey > "keys/${CLIENT_NAME}_pub"
wg genpsk | tee "keys/${CLIENT_NAME}_psk" &> /dev/null
echo "::: Client Keys generated"

# Find an unused number for the last octet of the client IP if not given
if [ "$custIP" == "" ]; then
for i in {2..254}; do
    if ! grep -q " $i$" configs/clients.txt; then
        COUNT="$i"
        echo "${CLIENT_NAME} $(<keys/${CLIENT_NAME}_pub) $(date +%s) ${COUNT}" >> configs/clients.txt
        break
    fi
done
else
	echo "configuring with custom ip $custIP";
	echo "${CLIENT_NAME} $(<keys/${CLIENT_NAME}_pub) $(date +%s) ${custIP}" >> configs/clients.txt
#	exit 0;
fi

NET_REDUCED="${pivpnNET::-2}"

if [ "$custIP" == "" ]; then
	adr="${NET_REDUCED}.${COUNT}/${subnetClass}"
	alAdr="${NET_REDUCED}.${COUNT}/32"
else
	adr="${custIP}/${subnetClass}"
	alAdr="${custIP}/32"
fi

echo -n "[Interface]
PrivateKey = $(cat "keys/${CLIENT_NAME}_priv")
Address = ${adr}
DNS = ${pivpnDNS1}" > "configs/${CLIENT_NAME}.conf"

if [ -n "${pivpnDNS2}" ]; then
    echo ", ${pivpnDNS2}" >> "configs/${CLIENT_NAME}.conf"
else
    echo >> "configs/${CLIENT_NAME}.conf"
fi
echo >> "configs/${CLIENT_NAME}.conf"

# to allow trafic to live and test, replace allowed ips with this:
# AllowedIPs = 185.170.114.39/32, 185.233.106.96/32, 10.10.0.0/16" >> "configs/${CLIENT_NAME}.conf"

echo "[Peer]
PublicKey = $(cat keys/server_pub)
PresharedKey = $(cat "keys/${CLIENT_NAME}_psk")
Endpoint = ${pivpnHOST}:${pivpnPORT}
PersistentKeepalive = 10
AllowedIPs = 10.10.0.0/16" >> "configs/${CLIENT_NAME}.conf"
echo "::: Client config generated"


echo "### begin ${CLIENT_NAME} ###
[Peer]
PublicKey = $(cat "keys/${CLIENT_NAME}_pub")
PresharedKey = $(cat "keys/${CLIENT_NAME}_psk")
AllowedIPs = ${alAdr}
### end ${CLIENT_NAME} ###" >> wg0.conf
echo "::: Updated server config"

if [ -f /etc/pivpn/hosts.wireguard ]; then
    echo "${NET_REDUCED}.${COUNT} ${CLIENT_NAME}.pivpn" >> /etc/pivpn/hosts.wireguard
    if killall -SIGHUP pihole-FTL; then
        echo "::: Updated hosts file for Pi-hole"
    else
        echo "::: Failed to reload pihole-FTL configuration"
    fi
fi

if systemctl restart wg-quick@wg0; then
    echo "::: WireGuard restarted"
else
    echo "::: Failed to restart WireGuard"
fi

cp "configs/${CLIENT_NAME}.conf" "${install_home}/configs/${CLIENT_NAME}.conf"
chown "${install_user}":"${install_user}" "${install_home}/configs/${CLIENT_NAME}.conf"
chmod 640 "${install_home}/configs/${CLIENT_NAME}.conf"

echo "======================================================================"
echo -e "::: Done! \e[1m${CLIENT_NAME}.conf successfully created!\e[0m"
echo "::: ${CLIENT_NAME}.conf was copied to ${install_home}/configs for easy transfer."
echo "::: Please use this profile only on one device and create additional"
echo -e "::: profiles for other devices. You can also use \e[1mpivpn -qr\e[0m"
echo "::: to generate a QR Code you can scan with the mobile app."
echo "======================================================================"
