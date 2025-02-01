#!/bin/sh

#echo "WhereAmI?: $PWD"
#ls $PWD


# Set safe shell defaults
set -euf

FDOVER_MAJOR=4
FDOVER_MINOR=2
FDOVER_MAJOR_MINOR=${FDOVER_MAJOR}.${FDOVER_MINOR}
FDOVER_POINT=0
FDOVER_MAJOR_MINOR_REV=${FDOVER_MAJOR_MINOR}.${FDOVER_POINT}
MGVER_MAJOR=4
MGVER_MINOR=0
MGVER_MAJOR_MINOR=${MGVER_MAJOR}.${MGVER_MINOR}
MGVER_POINT=0
MGVER_MAJOR_MINOR_REV=${MGVER_MAJOR_MINOR}.${MGVER_POINT}

MG_INST=/usr/local/mapguideopensource-${MGVER_MAJOR_MINOR_REV}
FDO_INST=/usr/local/fdo-${FDOVER_MAJOR_MINOR_REV}

DRY_RUN=0
HEADLESS=0
NO_SERVICE_INSTALL=0
NO_MGSERVER_START=0
NO_TOMCAT_START=0
NO_HTTPD_START=0
INSTALLER_TITLE="MapGuide Open Source installer"

DEFAULT_ENABLE_TOMCAT=N

DEFAULT_SERVER_IP="127.0.0.1"

DEFAULT_ADMIN_PORT=2810
DEFAULT_CLIENT_PORT=2811
DEFAULT_SITE_PORT=2812

DEFAULT_HTTPD_PORT=8008
DEFAULT_TOMCAT_PORT=8009

DEFAULT_HTTPD_USER=daemon
DEFAULT_HTTPD_GROUP=daemon

HAVE_TOMCAT=0
TOMCAT_AJP_SECRET=mapguide4java
TOMCAT_AJP_LISTEN_HOST="127.0.0.1"

csmap_choice="full"

server_ip="127.0.0.1"
webtier_server_ip="127.0.0.1"

admin_port=2810
client_port=2811
site_port=2812

httpd_port=8008
tomcat_port=8009

httpd_user=daemon
httpd_group=daemon

fdo_provider_choice=""
extras_choice=""

# Must have root
if ! [ "$(id -u)" = "0" ]; then
    echo "You must run this script with superuser privileges"
    exit 1
fi

while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        -dry-run|--dry-run)
            DRY_RUN=1
            ;;
        -headless|--headless)
            HEADLESS=1
            ;;
        -no-service-install|--no-service-install)
            NO_SERVICE_INSTALL=1
            ;;
        -no-mgserver-start|--no-mgserver-start)
            NO_MGSERVER_START=1
            ;;
        -no-tomcat-start|--no-tomcat-start)
            NO_TOMCAT_START=1
            ;;
        -no-httpd-start|--no-httpd-start)
            NO_HTTPD_START=1
            ;;
        -with-sdf|--with-sdf)
            fdo_provider_choice="$fdo_provider_choice sdf"
            ;;
        -with-shp|--with-shp)
            fdo_provider_choice="$fdo_provider_choice shp"
            ;;
        -with-sqlite|--with-sqlite)
            fdo_provider_choice="$fdo_provider_choice sqlite"
            ;;
        -with-gdal|--with-gdal)
            fdo_provider_choice="$fdo_provider_choice gdal"
            ;;
        -with-ogr|--with-ogr)
            fdo_provider_choice="$fdo_provider_choice ogr"
            ;;
        -with-rdbms|--with-rdbms)
            fdo_provider_choice="$fdo_provider_choice rdbms"
            ;;
        -with-kingoracle|--with-kingoracle)
            fdo_provider_choice="$fdo_provider_choice kingoracle"
            ;;
        -with-wfs|--with-wfs)
            fdo_provider_choice="$fdo_provider_choice wfs"
            ;;
        -with-wms|--with-wms)
            fdo_provider_choice="$fdo_provider_choice wms"
            ;;
        -server-ip|--server-ip)
            server_ip="$2"
            webtier_server_ip="$2"
            shift
            ;;
        -admin-port|--admin-port)
            admin_port=$2
            shift
            ;;
        -client-port|--client-port)
            client_port=$2
            shift
            ;;
        -site-port|--site-port)
            site_port=$2
            shift
            ;;
        -httpd-port|--httpd-port)
            httpd_port=$2
            shift
            ;;
        -httpd-user|--httpd-user)
            httpd_user=$2
            shift
            ;;
        -httpd-group|--httpd-group)
            httpd_group=$2
            shift
            ;;
        -tomcat-port|--tomcat-port)
            tomcat_port=$2
            shift
            ;;
        -with-tomcat|--with-tomcat)
            HAVE_TOMCAT=1
            ;;
        -help|--help)
            echo "Usage: installer.run -- (add options here)"
            echo "Options:"
            echo "  --dry-run [Bail before actual installation, to see what configuration will be applied]"
            echo "  --headless [Install headlessly (skip UI)]"
            echo "  --with-sdf [Include SDF Provider]"
            echo "  --with-shp [Include SHP Provider]"
            echo "  --with-sqlite [Include SQLite Provider]"
            echo "  --with-gdal [Include GDAL Provider]"
            echo "  --with-ogr [Include OGR Provider]"
            echo "  --with-rdbms [Include RDBMS Providers]"
            echo "  --with-kingoracle [Include King Oracle Provider]"
            echo "  --with-wfs [Include WFS Provider]"
            echo "  --with-wms [Include WMS Provider]"
            echo "  --with-tomcat [Enable Tomcat]"
            echo "  --no-service-install [Skip service installation]"
            echo "  --no-mgserver-start [Do not start mgserver after installation]"
            # Doesn't work atm, don't advertise
            #echo "  --no-tomcat-start [Do not start tomcat after installation]"
            echo "  --no-httpd-start [Do not start httpd after installation]"
            echo "  --server-ip [Server IP, default: $DEFAULT_SERVER_IP]"
            echo "  --admin-port [Admin Server Port, default: $DEFAULT_ADMIN_PORT]"
            echo "  --client-port [Client Server Port, default: $DEFAULT_CLIENT_PORT]"
            echo "  --site-port [Site Server Port, default: $DEFAULT_SITE_PORT]"
            echo "  --httpd-port [HTTPD port, default: $DEFAULT_HTTPD_PORT]"
            echo "  --tomcat-port [Tomcat Port, default: $DEFAULT_TOMCAT_PORT]"
            echo "  --httpd-user [Run HTTPD under this user, default: $DEFAULT_HTTPD_USER]"
            echo "  --httpd-group [Tomcat Port, default: $DEFAULT_HTTPD_GROUP]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

dialog_check()
{
    if [ "$HEADLESS" != "1" ];
    then
        DIALOG=${DIALOG=dialog}
        if [ -x "$(command -v $DIALOG)" ]; then
            echo "[install]: dialog was found. Proceeding with interactive installer"
        else
            echo "[install]: The executable dialog was not found. Attempting to automatically install it"
            packagesNeeded="dialog"
            echo "[install]: Installing pre-requisite packages: ${packagesNeeded}"
            if [ -x "$(command -v apt-get)" ]; #ubuntu/debian
            then
                apt-get install -y "${packagesNeeded}"
            elif [ -x "$(command -v dnf)" ]; #centos/fedora/rhel
            then
                dnf install -y "${packagesNeeded}"
            elif [ -x "$(command -v zypper)" ]; #suse
            then
                zypper install -n "${packagesNeeded}"
            else
                echo "We could not determine your distro to know how to acquire package: ${packagesNeeded}"
                echo "Please install the dialog package using your distro's package manager"
                echo "Otherwise, you will have to run this installer with --headless and provide all the configuration"
                echo "arguments up-front. Run with --help for all the possible configuration arguments"
                exit 1
            fi
        fi
    fi
}

try_install_libaio()
{
    packagesNeeded="libaio"
    echo "[install]: Attempting to install packages: ${packagesNeeded}"
    if [ -x "$(command -v apt-get)" ]; #ubuntu/debian
    then
        apt-get install -y "${packagesNeeded}"
    elif [ -x "$(command -v dnf)" ]; #centos/fedora/rhel
    then
        dnf install -y "${packagesNeeded}"
    elif [ -x "$(command -v zypper)" ]; #suse
    then
        zypper install -n "${packagesNeeded}"
    else
        echo "==== WARNING ===="
        echo "We could not determine your distro to know how to acquire package: ${packagesNeeded}"
        echo "Please install the libaio package using your distro's package manager"
    fi
}

main()
{
    dialog_check
    if [ "$HEADLESS" != "1" ]
    then
        dialog_welcome
        dialog_fdo_provider
        dialog_server
        dialog_webtier
        dialog_extras
    fi
    dump_configuration
    install_prerequisites
    install_fdo
    install_mapguide_packages
    post_install
}

set_server_vars()
{
    vars=$(cat $1)
    set $vars
    server_ip=${1:-$DEFAULT_SERVER_IP}
    admin_port=${2:-$DEFAULT_ADMIN_PORT}
    client_port=${3:-$DEFAULT_CLIENT_PORT}
    site_port=${4:-$DEFAULT_SITE_PORT}
}

set_webtier_vars()
{
    vars=$(cat $1)
    set $vars
    webtier_server_ip=${1:-$DEFAULT_SERVER_IP}
    httpd_port=${2:-$DEFAULT_HTTPD_PORT}
    enable_tomcat=${3:-$DEFAULT_ENABLE_TOMCAT}
    tomcat_port=${4:-$DEFAULT_TOMCAT_PORT}
    httpd_user=${5:-$DEFAULT_HTTPD_USER}
    httpd_group=${6:-$DEFAULT_HTTPD_GROUP}
    case $enable_tomcat in
        y*|Y*)
            HAVE_TOMCAT=1
            ;;
        *)
            HAVE_TOMCAT=0
            ;;
    esac
}

dump_configuration()
{
    echo "********* Configuration Summary ************"
    echo " Default Ports (Server)"
    echo "  Admin: ${DEFAULT_ADMIN_PORT}"
    echo "  Client: ${DEFAULT_CLIENT_PORT}"
    echo "  Site: ${DEFAULT_SITE_PORT}"
    echo " Default Ports (WebTier)"
    echo "  Apache: ${DEFAULT_HTTPD_PORT}"
    echo "  Tomcat: ${DEFAULT_TOMCAT_PORT}"
    echo " Configured Ports (Server)"
    echo "  Admin: ${admin_port}"
    echo "  Client: ${client_port}"
    echo "  Site: ${site_port}"
    echo " Configured Ports (WebTier)"
    echo "  Apache: ${httpd_port}"
    echo "  Tomcat: ${tomcat_port}"
    echo " Other choices"
    echo "  FDO: ${fdo_provider_choice}"
    echo "  CS-Map: ${csmap_choice}"
    echo "  Extras: ${extras_choice}"
    echo "  Server IP: ${server_ip}"
    echo " Enable Tomcat: ${HAVE_TOMCAT}"
    echo " Run httpd under user: ${httpd_user}"
    echo " Run httpd under group: ${httpd_group}"
    echo " No service install: ${NO_SERVICE_INSTALL}"
    echo " No mgserver start: ${NO_MGSERVER_START}"
    echo " No httpd start: ${NO_HTTPD_START}"
    echo " No tomcat start: ${NO_TOMCAT_START}"
    echo "********************************************"
    if [ "$DRY_RUN" = "1" ]; then
        exit 0
    fi
}

dialog_welcome()
{
    $DIALOG --backtitle "$INSTALLER_TITLE" \
            --title "Welcome" --clear \
            --yesno "Welcome to the MapGuide Open Source installer. Would you like to proceed?" 10 30

    case $? in
      1)
        echo "Cancelled"
        exit 1;;
      255)
        echo "Cancelled"
        exit 255;;
    esac
}

dialog_fdo_provider()
{
    tempfile=$(mktemp 2>/dev/null) || tempfile=/tmp/test$$
    trap 'rm -f $tempfile' 0 1 2 5 15

    #arcsde    	"OSGeo FDO Provider for ArcSDE" off \
    # Disable RDBMS provider selection by default
    $DIALOG --backtitle "$INSTALLER_TITLE" \
            --title "FDO Providers" --clear \
            --checklist "Check the FDO Providers you want to install" 20 61 5 \
            sdf  		"OSGeo FDO Provider for SDF" ON \
            shp    		"OSGeo FDO Provider for SHP" ON \
            sqlite 		"OSGeo FDO Provider for SQLite" ON \
            gdal    	"OSGeo FDO Provider for GDAL" ON \
            ogr    		"OSGeo FDO Provider for OGR" ON \
            kingoracle  "OSGeo FDO Provider for Oracle" off \
            rdbms	    "RDBMS FDO Providers (ODBC, MySQL, PostgreSQL)" off \
            wfs    		"OSGeo FDO Provider for WFS" ON \
            wms   		"OSGeo FDO Provider for WMS" ON  2> $tempfile

    fdo_provider_choice=$(cat $tempfile | sed s/\"//g)
    case $? in
      1)
        echo "Cancelled"
        exit 1;;
      255)
        echo "Cancelled"
        exit 255;;
    esac
    rm $tempfile
}

dialog_server()
{
    tempfile=$(mktemp 2>/dev/null) || tempfile=/tmp/form.$$
    dialog --backtitle "$INSTALLER_TITLE" --title "Server Configuration" \
            --form "\nSet the port numbers that the MapGuide Server will listen on" 25 60 16 \
            "Server IP:"   1 1 "${DEFAULT_SERVER_IP}"   1 25 25 30 \
            "Admin Port:"  2 1 "${DEFAULT_ADMIN_PORT}"  2 25 25 30 \
            "Client Port:" 3 1 "${DEFAULT_CLIENT_PORT}" 3 25 25 30 \
            "Site Port:"   4 1 "${DEFAULT_SITE_PORT}"   4 25 25 30 2> $tempfile
    case $? in
      1)
        echo "Cancelled"
        exit 1;;
      255)
        echo "Cancelled"
        exit 255;;
    esac
    set_server_vars $tempfile
    rm $tempfile
}

dialog_tomcat()
{
    tempfile=$(mktemp 2>/dev/null) || tempfile=/tmp/form.$$
    dialog --title "Enable Tomcat" \
           --yesno "Do you want to enable Tomcat to run Java MapGuide applications?" 10 40 2> $tempfile
    case $? in
      0)
        HAVE_TOMCAT=1
        #echo "Enable tomcat"
        ;;
      1)
        HAVE_TOMCAT=0
        #echo "Disable tomcat"
        ;;
    esac
    rm $tempfile
}

dialog_webtier()
{
    tempfile=$(mktemp 2>/dev/null) || tempfile=/tmp/form.$$
    dialog --backtitle "$INSTALLER_TITLE" --title "Web Tier Configuration" \
            --form "\nSet the port numbers that Apache/Tomcat will listen on.\n\nTomcat only needs to be enabled if you are intending to run Java MapGuide applications" 25 60 16 \
            "Connect to Server IP:" 1 1 "${DEFAULT_SERVER_IP}"     1 25 25 30 \
            "Apache Port:"          2 1 "${DEFAULT_HTTPD_PORT}"    2 25 25 30 \
            "Enable Tomcat (Y/N)?:" 3 1 "${DEFAULT_ENABLE_TOMCAT}" 3 25 1 30 \
            "Tomcat Port:"          4 1 "${DEFAULT_TOMCAT_PORT}"   4 25 25 30 \
            "Run httpd as user:"    5 1 "${DEFAULT_HTTPD_USER}"   5 25 25 30 \
            "Run httpd as group:"   6 1 "${DEFAULT_HTTPD_GROUP}"   6 25 25 30 2> $tempfile
    case $? in
      1)
        echo "Cancelled"
        exit 1;;
      255)
        echo "Cancelled"
        exit 255;;
    esac
    set_webtier_vars $tempfile
    rm $tempfile
}

dialog_extras()
{
    tempfile=$(mktemp 2>/dev/null) || tempfile=/tmp/form.$$
    $DIALOG --backtitle "$INSTALLER_TITLE" \
            --title "Extra Features" --clear \
            --checklist "Check the extra features you want to enable/install" 20 61 5 \
            noserviceinstall "do not install services" OFF \
            nomgserverstart "do not start mgserver" OFF \
            nohttpdstart "do not start httpd" OFF 2> $tempfile
    case $? in
      1)
        echo "Cancelled"
        exit 1;;
      255)
        echo "Cancelled"
        exit 255;;
    esac
    extras_choice=$(cat $tempfile | sed s/\"//g)
    for extra in $extras_choice
    do
        case $extra in
            noserviceinstall)
                NO_SERVICE_INSTALL=1
                ;;
            nomgserverstart)
                NO_MGSERVER_START=1
                ;;
            nohttpdstart)
                NO_HTTPD_START=1
                ;;
        esac
    done
    # re-read to trim these extraneous options
    extras_choice=$(cat $tempfile | sed s/noserviceinstall//g | sed s/nomgserverstart//g | sed s/nohttpdstart//g | sed s/\"//g)
    rm $tempfile
}

install_prerequisites()
{
    # Our generic build is fully self-contained, so there is no pre-requisites to install
    if [ ${HAVE_TOMCAT} = "1" ]; then
        # However, we should still check if java is present if tomcat is enabled
        JAVA_CMD=java
        HAVE_JAVA=0
        if [ -x "$(command -v $JAVA_CMD)" ]; then
            HAVE_JAVA=1
        else
            echo "java not found globally. Falling back to JAVA_HOME env var"
            JAVA_CMD=$JAVA_HOME/bin/java
            if [ -x "$(command -v $JAVA_CMD)" ]; then
                HAVE_JAVA=1
            else
                echo "==== WARNING ===="
                echo "We could not find java on this system. The bundled tomcat will not run without java installed"
                echo "Please install java through your distro's package manager"
            fi
        fi
        if [ "${HAVE_JAVA}" = "1" ]; then
            JAVA_VER=$($JAVA_CMD -version 2>&1 >/dev/null | grep -E "\S+\s+version" | awk '{print $3}' | tr -d '"')
            echo "[install]: Found java version ${JAVA_VER}"
        fi
    fi
}

install_fdo()
{
    # set initial registration state
    arcsde_registered=0
    gdal_registered=0
    kingoracle_registered=0
    rdbms_registered=0
    ogr_registered=0
    sdf_registered=0
    shp_registered=0
    sqlite_registered=0
    wfs_registered=0
    wms_registered=0

    # Include core and rdbms packages regardless of choice.
    # fdo_provider_choice="core rdbms $fdo_provider_choice"
    # Download and install Ubuntu packages for FDO
    # for file in $fdo_provider_choice
    # do
    #     download_file="${TEMPDIR}/fdo-${file}_${FDOVER}.deb"
    #     wget -N -O "${download_file}" "${URL}/fdo-${file}_${FDOVER}.deb"
    #     dpkg -E -G --install "${download_file}"
    # done

    # Copy FDO directory from installer staging area
    cp -R fdo-${FDOVER_MAJOR_MINOR_REV} ${FDO_INST}

    # Nuke the old providers.xml, we're rebuiding it
    providersxml=${FDO_INST}/lib64/providers.xml
    echo "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"no\" ?>" > ${providersxml}
    echo "<FeatureProviderRegistry>" >> ${providersxml}
    for file in $fdo_provider_choice
    do
        case $file in
          arcsde)
            if [ $arcsde_registered -eq 1 ];
            then
                continue
            fi
            echo "Registering ArcSDE Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>OSGeo.ArcSDE.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for ArcSDE</DisplayName>" >> ${providersxml}
            echo "    <Description>Read/write access to an ESRI ArcSDE-based data store, using Oracle and SQL Server</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libArcSDEProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            arcsde_registered=1
            ;;
          gdal)
            if [ $gdal_registered -eq 1 ];
            then
                continue
            fi
            echo "Registering GDAL Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>OSGeo.Gdal.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for GDAL</DisplayName>" >> ${providersxml}
            echo "    <Description>FDO Provider for GDAL</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libGRFPProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            gdal_registered=1
            ;;
          kingoracle)
            if [ $kingoracle_registered -eq 1 ];
            then
                continue
            fi
            echo "Registering King Oracle Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>King.Oracle.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for Oracle</DisplayName>" >> ${providersxml}
            echo "    <Description>Read/write access to spatial and attribute data in Oracle Spatial</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libKingOracleProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            kingoracle_registered=1
            # libaio is a dependency of OCI and not the provider itself
            try_install_libaio
            ;;
          rdbms)
            if [ $rdbms_registered -eq 1 ];
            then
                continue
            fi
            echo "Registering ODBC Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>OSGeo.ODBC.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for ODBC</DisplayName>" >> ${providersxml}
            echo "    <Description>FDO Provider for ODBC</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libODBCProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            echo "Registering PostgreSQL Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>OSGeo.PostgreSQL.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for PostgreSQL</DisplayName>" >> ${providersxml}
            echo "    <Description>Read/write access to PostgreSQL/PostGIS-based data store. Supports spatial data types and spatial query operations</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libPostgreSQLProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            echo "Registering MySQL Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>OSGeo.MySQL.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for MySQL</DisplayName>" >> ${providersxml}
            echo "    <Description>FDO Provider for MySQL</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libMySQLProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            rdbms_registered=1
            ;;
          ogr)
            if [ $ogr_registered -eq 1 ];
            then
                continue
            fi
            echo "Registering OGR Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>OSGeo.OGR.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for OGR</DisplayName>" >> ${providersxml}
            echo "    <Description>FDO Access to OGR Data Sources</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libOGRProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            ogr_registered=1
            ;;
          sdf)
            if [ $sdf_registered -eq 1 ];
            then
                continue
            fi
            echo "Registering SDF Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>OSGeo.SDF.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for SDF</DisplayName>" >> ${providersxml}
            echo "    <Description>Read/write access to Autodesk's spatial database format, a file-based geodatabase that supports multiple features/attributes, spatial indexing and file-locking</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libSDFProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            sdf_registered=1
            ;;
          shp)
            if [ $shp_registered -eq 1 ];
            then
                continue
            fi
            echo "Registering SHP Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>OSGeo.SHP.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for SHP</DisplayName>" >> ${providersxml}
            echo "    <Description>Read/write access to spatial and attribute data in an ESRI SHP file</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libSHPProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            shp_registered=1
            ;;
          sqlite)
            if [ $sqlite_registered -eq 1 ];
            then
                continue
            fi
            echo "Registering SQLite Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>OSGeo.SQLite.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for SQLite</DisplayName>" >> ${providersxml}
            echo "    <Description>Read/write access to feature data in a SQLite file</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libSQLiteProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            sqlite_registered=1
            ;;
          wfs)
            if [ $wfs_registered -eq 1 ];
            then
                continue
            fi
            echo "Registering WFS Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>OSGeo.WFS.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for WFS</DisplayName>" >> ${providersxml}
            echo "    <Description>Read access to OGC WFS-based data store</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libWFSProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            wfs_registered=1
            ;;
          wms)
            if [ $wms_registered -eq 1 ];
            then
                continue
            fi
            echo "Registering WMS Provider"
            echo "  <FeatureProvider>" >> ${providersxml}
            echo "    <Name>OSGeo.WMS.${FDOVER_MAJOR_MINOR}</Name>" >> ${providersxml}
            echo "    <DisplayName>OSGeo FDO Provider for WMS</DisplayName>" >> ${providersxml}
            echo "    <Description>Read access to OGC WMS-based data store</Description>" >> ${providersxml}
            echo "    <IsManaged>False</IsManaged>" >> ${providersxml}
            echo "    <Version>${FDOVER_MAJOR_MINOR_REV}.0</Version>" >> ${providersxml}
            echo "    <FeatureDataObjectsVersion>${FDOVER_MAJOR_MINOR_REV}.0</FeatureDataObjectsVersion>" >> ${providersxml}
            echo "    <LibraryPath>libWMSProvider.so</LibraryPath>" >> ${providersxml}
            echo "  </FeatureProvider>" >> ${providersxml}
            wms_registered=1
            ;;
        esac
    done
    echo "</FeatureProviderRegistry>" >> ${providersxml}
}

install_mapguide_packages()
{
    # Download Ubuntu packages for MapGuide
    # mapguide_packages="platformbase coordsys common server webextensions httpd"
    # if [ "$csmap_choice" = "lite" ]; then
    #     mapguide_packages="platformbase coordsys-lite common server webextensions httpd"
    # fi
    # for file in $mapguide_packages
    # do
    #     download_file="${TEMPDIR}/mapguideopensource-${file}_${MGVER}.deb"
    #     wget -N -O "${download_file}" "${URL}/mapguideopensource-${file}_${MGVER}.deb"
    #     dpkg -E -G --install "${download_file}"
    # done

    cp -R mapguideopensource-${MGVER_MAJOR_MINOR_REV} ${MG_INST}
}

post_install()
{
    echo "[config]: Updating serverconfig.ini with configuration choices"
    sed -i 's/MachineIp.*= '"${DEFAULT_SERVER_IP}"'/MachineIp = '"${server_ip}"'/g' ${MG_INST}/server/bin/serverconfig.ini
    sed -i 's/IpAddress.*= '"${DEFAULT_SERVER_IP}"'/IpAddress = '"${server_ip}"'/g' ${MG_INST}/server/bin/serverconfig.ini
    sed -i 's/Port.*= '"${DEFAULT_ADMIN_PORT}"'/Port = '"${admin_port}"'/g' ${MG_INST}/server/bin/serverconfig.ini
    sed -i 's/Port.*= '"${DEFAULT_CLIENT_PORT}"'/Port = '"${client_port}"'/g' ${MG_INST}/server/bin/serverconfig.ini
    sed -i 's/Port.*= '"${DEFAULT_SITE_PORT}"'/Port = '"${site_port}"'/g' ${MG_INST}/server/bin/serverconfig.ini
    echo "[config]: Updating webconfig.ini with configuration choices"
    sed -i 's/IpAddress.*= '"${DEFAULT_SERVER_IP}"'/IpAddress = '"${webtier_server_ip}"'/g' ${MG_INST}/webserverextensions/www/webconfig.ini
    sed -i 's/Port.*= '"${DEFAULT_ADMIN_PORT}"'/Port = '"${admin_port}"'/g' ${MG_INST}/webserverextensions/www/webconfig.ini
    sed -i 's/Port.*= '"${DEFAULT_CLIENT_PORT}"'/Port = '"${client_port}"'/g' ${MG_INST}/webserverextensions/www/webconfig.ini
    sed -i 's/Port.*= '"${DEFAULT_SITE_PORT}"'/Port = '"${site_port}"'/g' ${MG_INST}/webserverextensions/www/webconfig.ini
    echo "[config]: Updating httpd.conf with configuration choices"
    sed -i 's/Listen '"${DEFAULT_HTTPD_PORT}"'/Listen '"${httpd_port}"'/g' ${MG_INST}/webserverextensions/apache2/conf/httpd.conf
    sed -i 's/User '"${DEFAULT_HTTPD_USER}"'/User '"${httpd_user}"'/g' ${MG_INST}/webserverextensions/apache2/conf/httpd.conf
    sed -i 's/Group '"${DEFAULT_HTTPD_GROUP}"'/Group '"${httpd_group}"'/g' ${MG_INST}/webserverextensions/apache2/conf/httpd.conf
    echo "[config]: Updating OGC configuration files with configuration choices"
    sed -i 's/'"localhost:${DEFAULT_HTTPD_PORT}"'/'"localhost:${httpd_port}"'/g' ${MG_INST}/server/Wfs/OgcWfsService.config.awd
    sed -i 's/'"localhost:${DEFAULT_HTTPD_PORT}"'/'"localhost:${httpd_port}"'/g' ${MG_INST}/server/Wms/OgcWmsService.config.awd

    if [ ${HAVE_TOMCAT} = "1" ]; then
        echo "[config]: Writing workers.properties for mod_jk"
        cat << EOF > ${MG_INST}/webserverextensions/apache2/conf/mapguide/workers.properties
# Define 1 real worker using ajp13
worker.list=worker1
# Set properties for worker1 (ajp13)
worker.worker1.type=ajp13
worker.worker1.host=${TOMCAT_AJP_LISTEN_HOST}
worker.worker1.port=${tomcat_port}
worker.worker1.lbfactor=50
worker.worker1.cachesize=10
worker.worker1.cache_timeout=600
worker.worker1.socket_keepalive=1
worker.worker1.recycle_timeout=300
worker.worker1.secret=${TOMCAT_AJP_SECRET}
EOF
        echo "[config]: Updating tomcat configs with configuration choices"
        sed -i "s|<!-- Define an AJP 1.3 Connector on port 8009 -->|<Connector protocol=\"AJP/1.3\" address=\"${TOMCAT_AJP_LISTEN_HOST}\" secret=\"${TOMCAT_AJP_SECRET}\" port=\"${tomcat_port}\" redirectPort=\"8443\" />|g" ${MG_INST}/webserverextensions/tomcat/conf/server.xml
    else
        echo "[config]: Skipping tomcat configuration"
    fi

    echo "[config]: Ensuring key directories exist"
    mkdir -p ${MG_INST}/webserverextensions/apache2/logs
    mkdir -p ${MG_INST}/webserverextensions/Temp
    mkdir -p ${MG_INST}/webserverextensions/www/fusion/lib/tcpdf/cache

    echo "[config]: Fixing permissions for certain folders"
    chmod 770 ${MG_INST}/webserverextensions/Temp

    if id "$httpd_user" >/dev/null 2>&1; then
        echo "[config]: chown-ing some key directories to user '$httpd_user'"
        chown ${httpd_user}:${httpd_group} ${MG_INST}/webserverextensions/Temp
        chown ${httpd_user}:${httpd_group} ${MG_INST}/webserverextensions/www/fusion/lib/tcpdf/cache
    else
        echo "[config]: User '$httpd_user' does not exist. Will not attempt any chown-ing of certain directories for temporary data"
        echo "[config]: Some web application behaviour may not work properly"
    fi

    if [ "$HEADLESS" = "1" ] && [ "$NO_SERVICE_INSTALL" = "1" ];
    then
        echo "[config]: Skipping service registration as --headless and --no-service-install specified"
    else
        echo "[config]: Registering Services"
        mkdir -p /etc/init.d
        ln -s ${MG_INST}/server/bin/mapguidectl /etc/init.d/mapguide
        ln -s ${MG_INST}/webserverextensions/apache2/bin/apachectl /etc/init.d/apache-mapguide
        #update-rc.d mapguide defaults 35 65
        #update-rc.d apache-mapguide defaults 30 70
    fi
    
    if [ "$HEADLESS" = "1" ] && [ "$NO_HTTPD_START" = "1" ];
    then
        echo "[install]: Skipping httpd auto-start as --headless and --no-httpd-start specified"
    else
        if [ -e "/etc/init.d/apache-mapguide" ]; 
        then
            echo "[install]: Starting httpd"
            /etc/init.d/apache-mapguide start
        else
            echo "[install]: WARNING - apache-mapguide service entry not found"
        fi
    fi
    if [ "$HEADLESS" = "1" ] && [ "$NO_MGSERVER_START" = "1" ];
    then
        echo "[install]: Skipping mgserver auto-start as --headless and --no-mgserver-start specified"
    else
        if [ -e "/etc/init.d/mapguide" ]; 
        then
            echo "[install]: Starting mgserver"
            /etc/init.d/mapguide start
        else
            echo "[install]: WARNING - mgserver service entry not found"
        fi
    fi
    if [ "$HAVE_TOMCAT" = "0" ];
    then
        echo "[install]: Skipping tomcat auto-start"
    else
        echo "[install]: Tomcat service script"
        cat << EOF > /etc/init.d/tomcat-mapguide
#!/bin/bash
# 
# tomcat
#
# chkconfig: 35
# description: Start up the Tomcat servlet engine.
# processname: tomcat

RETVAL=\$?
CATALINA_HOME="${MG_INST}/webserverextensions/tomcat"

case "\$1" in
 start)
        if [ -f \$CATALINA_HOME/bin/startup.sh ];
          then
    echo \$"Starting Tomcat"
            \$CATALINA_HOME/bin/startup.sh
        fi
;;
 stop)
        if [ -f \$CATALINA_HOME/bin/shutdown.sh ];
          then
    echo \$"Stopping Tomcat"
            \$CATALINA_HOME/bin/shutdown.sh
        fi
;;
 *)
 echo \$"Usage: \$0 {start|stop}"
exit 1
;;
esac

exit \$RETVAL
EOF
        chmod +x /etc/init.d/tomcat-mapguide
        if [ "$HEADLESS" = "1" ] && [ "$NO_TOMCAT_START" = "1" ];
        then
            echo "[install]: Skipping tomcat auto-start as --headless and --no-tomcat-start specified"
        else
            # FIXME: Tomcat doesn't want to start from within this 
            # script (ps -A does not show a running java process afterwards) 
            # but starts fine without problems afterwards???
            echo "You can start tomcat by running: "
            echo "/etc/init.d/tomcat-mapguide start"
        fi
    fi
    echo "DONE!"
}

main
