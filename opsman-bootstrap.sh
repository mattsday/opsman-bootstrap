#!/bin/bash
# PCF Ops Manager bootstrap.
#
# Does nothing fancy, just pulls down the tiles you want
# (or some defaults) from Pivotal Network and uploads them
# to ops manager. Doesn't configure them or anything.

# Interpret CLI arguments
parse_cli() {
	# Set defaults
	SLUGS="elastic-runtime,p-spring-cloud-services,p-rabbitmq,p-mysql"
	VERSIONS=""
	IAAS=""

	if [ "$#" = 0 ]; then
		# No args, so just carry on
		return 0
	fi
	for i in "$@"; do
		case "$i" in
			--help)
				echo "Some kind of help"
				exit
				;;
			--list-slugs)
				echo "List slugs available"
				exit
				;;
			--slugs=*)
				SLUGS=$(echo $i | sed 's/--slugs=//')
				;;
			--iaas=*)
				IAAS=$(echo $i | sed 's/--iaas=//')
				IAAS_COMPARE=$(echo $IAAS | tr '[:upper:]' '[:lower:]')
				case "$IAAS_COMPARE" in
					gcp)
						IAAS="Google"
						;;
					vmware)
						IAAS="vSphere"
						;;
			    esac
				;;
			--*)
				VER=$(echo $i | sed 's/--//')
				echo Setting $VER
				VERSIONS=$VERSIONS:$VER
		esac
	done
	if [ -z "$IAAS" ]; then
		echo Warning: No IaaS specified via --iaas, stemcells may not install correctly
	fi
	echo Bootstrapping Cloud Foundry
	echo Installing slugs: $SLUGS

}

# Check the environment and install what's needed
setup() {
	if [ -z "$PIVNET_API_KEY" ]; then
		echo Please enter your Pivotal Network API Key:
		read -s PIVNET_API_KEY
		echo Set PIVNET_API_KEY to \*\*\*\*\*\*
	fi

	if [ -z "$PCF_USER" ]; then
		echo Setting \$PCF_USER to admin
		PCF_USER=admin
	fi

	if [ -z "$PCF_OPSMGR" ]; then
		echo Setting \$PCF_OPSMGR to https://localhost
		PCF_OPSMGR=https://localhost
	fi

	if [ -z "$PCF_PASSWD" ]; then
		echo Please enter your PCF Ops Manager password for $PCF_USER
		read -s PCF_PASSWD
		echo Set Ops Manager password to \*\*\*\*
	fi

	# Install OM tool
	if ! command -v om> /dev/null 2>&1; then
		echo Installing OM tool
		wget "https://github.com/pivotal-cf/om/releases/download/0.29.0/om-linux" >/dev/null 2>&1
		sudo mv om-linux /usr/local/bin
		sudo chmod +x /usr/local/bin/om-linux
		sudo ln -s /usr/local/bin/om-linux /usr/local/bin/om
	fi

	# Install jq
	if ! command -v jq> /dev/null 2>&1; then
		echo Instaling jq
		sudo apt-get update >/dev/null && sudo apt-get install -y jq >/dev/null
	fi

	# Install lynx
	if ! command -v lynx> /dev/null 2>&1; then
		echo Instaling lynx
		sudo apt-get update >/dev/null && sudo apt-get install -y lynx >/dev/null
	fi

	# Create download directory
	if [ ! -d "$HOME/opsmgr-downloads" ]; then
		mkdir "$HOME/opsmgr-downloads"
	fi
}

wget_download() {
	wget -qO $2 --post-data="" --header="Authorization: Token RwvGHXjFTP1pSTZgTo4B" $1
}

wget_post() {
	wget -qO- --post-data="" --header="Authorization: Token RwvGHXjFTP1pSTZgTo4B" $1
}

wget_get() {
	wget -qO- --header="Authorization: Token RwvGHXjFTP1pSTZgTo4B" $1
}

# Download list of products
get_product_list() {
	echo Getting product list...
	PRODUCT_LIST=$(wget_get http://network.pivotal.io/api/v2/products)
#	PRODUCT_LIST=$(cat ~/.opsmgr/products)
	PRODUCT_LIST=$(echo $PRODUCT_LIST | jq '.products | .[] | {slug:.slug,releases:._links.releases.href}')
}
get_releases() {
	RELEASES=$(wget_get $1)
}

get_files() {
	FILES=$(wget_get $1)
}

parse_cli $*
setup
get_product_list

#
IFS=,
for slug in $SLUGS; do
	unset IFS
	PRODUCT=$(echo $PRODUCT_LIST | jq 'select(.slug == "'$slug'")')
	if [ -z "$PRODUCT" ]; then
		echo Error: Could not find slug "$slug"
		exit
	fi
	RELEASES_URL=$(echo $PRODUCT | jq -r '.releases')
	get_releases $RELEASES_URL
	# Check if there's a version specified for this release
	unset slug_version
	if [ ! -z "$VERSIONS" ]; then
		IFS=:
		for version in $VERSIONS; do
			unset IFS
			slug_name=$(echo $version | awk -F= '{print $1}')
			if [ "$slug" = "$slug_name" ]; then
				# Set the version
				slug_version=$(echo $version | awk -F= '{print $2}')
			fi
		done
	fi
	if [ ! -z "$slug_version" ]; then
		RELEASE=$(echo $RELEASES | jq '.releases | .[] | {version:.version,eula:._links.eula_acceptance.href,files:._links.product_files.href} | select(.version == "'$slug_version'")')
		if [ -z "$RELEASE" ]; then
			echo "Error: Cannot find release $slug_version of $slug"
			exit
		fi
	else
		RELEASE=$(echo $RELEASES | jq '.releases | .[0] | {version:.version,eula:._links.eula_acceptance.href,files:._links.product_files.href}')
		slug_version=$(echo $RELEASE | jq -r '.version')
	fi
	# Accept the EULA
	EULA=$(echo $RELEASE | jq -r '.eula')
	if [ ! -z "$EULA" ]; then
		EULA=$(wget_post "$EULA")
	fi
	FILES=$(echo $RELEASE | jq -r '.files')
	get_files $FILES
	# List files
	FILES=$(echo $FILES | jq '.product_files | .[]')
	URL=""
	FILENAME=""
	VERSION=""
	if [ "$slug" = "stemcells" ]; then
		if [ ! -z "$IAAS" ]; then
			STEMCELL=$(echo $FILES | jq 'select(.name | contains("'$IAAS'"))')
			if [ -z "$STEMCELL" ]; then
				echo Error: Cannot find stemcell for IaaS $IAAS - incorrect spelling\?
				exit
			fi
			FILENAME=$(basename $(echo $STEMCELL | jq -r '.aws_object_key'))
			URL=$(echo $STEMCELL | jq -r '._links.download.href')
		fi
	elif [ "$slug" = "elastic-runtime" ]; then
		echo ERT
		#TODO - add ERT stuff
	else
		# Assume whatever file matches .pivotal is the golden egg
		TILE=$(echo $FILES | jq 'select(.aws_object_key | contains(".pivotal"))')
		if [ -z "$TILE" ]; then
			echo Error: Cannot find product $slug
			exit
		fi
		FILENAME=$(basename $(echo $TILE | jq -r '.aws_object_key'))
		URL=$(echo $TILE | jq -r '._links.download.href')
	fi

	if [ -z "$URL" ] || [ -z "$FILENAME" ]; then
		echo Error - Cannot determine URL or filename for slug $slug
		exit
	fi
	FILENAME="$HOME/opsmgr-downloads/$FILENAME"
	echo Downloading $slug $slug_version
	wget_download $URL $FILENAME

	if [ "$slug" = "stemcells" ]; then
		echo Installing stemcell $slug_version
		om -k -u "$PCF_USER" -p "$PCF_PASSWD" -t "$PCF_OPSMGR" upload-stemcell -s "$FILENAME"
	else
		echo Installing $slug $slug_version
		om -k -u "$PCF_USER" -p "$PCF_PASSWD" -t "$PCF_OPSMGR" upload-product -p "$FILENAME"
	fi
	#TODO - add this as an option to not do
	echo Cleaning up...
	rm "$FILENAME"

#	echo $FILES | jq '.product_files | .[]'
done
