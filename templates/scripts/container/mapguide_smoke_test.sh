#!/bin/sh

PACKAGE=
DISTRO=
HTTPD_PORT=8008
INST_PATH=/usr/local/mapguideopensource-4.0.0

while [ $# -gt 0 ]; do    # Until you run out of parameters...
    case "$1" in
        --package)
            PACKAGE="$2"
            shift
            ;;
        --distro)
            DISTRO="$2"
            shift
            ;;
        --httpd-port)
            HTTPD_PORT="$2"
            shift
            ;;
        --help)
            echo "Usage: $0 (options)"
            echo "Options:"
            echo "  --package [Installer package name]"
            echo "  --distro [Installer package name]"
            echo "  --httpd-port [Port number to use for httpd, default $HTTPD_PORT]"
            echo "  --help [Display usage]"
            exit
            ;;
    esac
    shift   # Check next set of parameters.
done

install_prereqs()
{
    case "$DISTRO" in
        ubuntu)
            apt-get update && apt-get install -y openjdk-8-jdk file
            ;;
        debian)
            # This may not be a java 8 JDK being installed. Let's see how famous their backwards compatibility is!
            apt-get update && apt-get install -y procps default-jdk file
            ;;
        fedora)
            yum install -y initscripts redhat-lsb libnsl procps libxcrypt-compat java-1.8.0-openjdk file
            ;;
        opensuse/leap)
            zypper install -y gzip tar libnsl1 java-1_8_0-openjdk-devel file
            groupadd daemon
            useradd -g daemon daemon
            # This is needed to avoid httpd complaining about not being able to find a transcoding service
            export LANG=en_US.UTF-8
            ;;
        archlinux)
            pacman -Sy --noconfirm libxcrypt-compat jdk8-openjdk
            ;;
        oraclelinux)
            microdnf install -y gzip procps libxcrypt-compat java-1.8.0-openjdk-devel findutils file
            ;;
        *)
            echo "FATAL: I don't know what your distro is"
            exit 1
            ;;
    esac
}

post_install()
{
    echo "Performing post-install tasks"

    echo "Checking if we have java ..."
    if ! command -v java 2>&1 >/dev/null
    then
        echo "Java not found. Testing if JAVA_HOME is set"
        if [ "$JAVA_HOME" = "" ];
        then
            echo "FATAL: Could not find java and JAVA_HOME environment variable is not set"
            exit 1
        else
            echo "JAVA_HOME is set to: $JAVA_HOME"
        fi
    fi

    # Start tomcat (installer doesn't auto start this)
    /etc/init.d/tomcat-mapguide start

    # Write a file that generates phpinfo
    cat > $INST_PATH/webserverextensions/www/phpinfo.php <<EOF
<?php
phpinfo();
?>
EOF

    # Write a sanity check PHP file that does a basic exercise of the MapGuide API php bindings
    # This is basically a near-carbon-copy of Bindings/src/Test/Php/Test1.php in the MapGuide source
    cat > $INST_PATH/webserverextensions/www/test.php <<EOF
<?php

echo "Initializing web tier";
try {
    MgInitializeWebTier(dirname(__FILE__)."/webconfig.ini");
} catch (MgException \$initEx) {
    echo "Init failure!";
    die;
} catch (Exception \$ex) {
    echo "[php]: Init exception: " . \$ex->getMessage() . "\n";
    die;
}
echo "[php]: Initialized\n";

// We haven't and shouldn't need to require/include constants.php
// they are now baked into the PHP extension along with the other
// MapGuide API proxy classes
echo "[php]: Testing some constants\n";
echo "  - AGF Mime: " . MgMimeType::Agf . "\n";
echo "  - KML Mime: " . MgMimeType::Kml . "\n";
echo "  - PNG Mime: " . MgImageFormats::Png . "\n";
echo "  - GIF Mime: " . MgImageFormats::Gif . "\n";
echo "  - Authentication Log File Type: " . MgLogFileType::Authentication . "\n";
echo "  - ClientOperationsQueueCount property: " . MgServerInformationProperties::ClientOperationsQueueCount . "\n";

\$user = new MgUserInformation("Anonymous", "");
// Basic set/get
\$user->SetLocale("en");
echo "[php]: Locale is: " . \$user->GetLocale() . "\n";
\$conn = new MgSiteConnection();
\$conn->Open(\$user);
// Create a session repository
\$site = \$conn->GetSite();
\$sessionID = \$site->CreateSession();
echo "[php]: Created session: \$sessionID\n";
\$user->SetMgSessionId(\$sessionID);
// Get an instance of the required services.
\$resourceService = \$conn->CreateService(MgServiceType::ResourceService);
echo "[php]: Created Resource Service\n";
\$mappingService = \$conn->CreateService(MgServiceType::MappingService);
echo "[php]: Created Mapping Service\n";
\$resId = new MgResourceIdentifier("Library://");
echo "[php]: Enumeratin'\n";
\$resources = \$resourceService->EnumerateResources(\$resId, -1, "");
echo \$resources->ToString() . "\n";
echo "[php]: Coordinate System\n";
\$csFactory = new MgCoordinateSystemFactory();
echo "[php]: CS Catalog\n";
\$catalog = \$csFactory->GetCatalog();
echo "[php]: Category Dictionary\n";
\$catDict = \$catalog->GetCategoryDictionary();
echo "[php]: CS Dictionary\n";
\$csDict = \$catalog->GetCoordinateSystemDictionary();
echo "[php]: Datum Dictionary\n";
\$datumDict = \$catalog->GetDatumDictionary();
echo "[php]: Coordinate System - LL84\n";
\$cs1 = \$csFactory->CreateFromCode("LL84");
echo "[php]: Coordinate System - WGS84.PseudoMercator\n";
\$cs2 = \$csFactory->CreateFromCode("WGS84.PseudoMercator");
echo "[php]: Make xform\n";
\$xform = \$csFactory->GetTransform(\$cs1, \$cs2);
echo "[php]: WKT Reader\n";
\$wktRw = new MgWktReaderWriter();
echo "[php]: WKT Point\n";
\$pt = \$wktRw->Read("POINT (1 2)");
\$coord = \$pt->GetCoordinate();
echo "[php]: X: ".\$coord->GetX().", Y: ".\$coord->GetY()."\n";
\$site->DestroySession(\$sessionID);
echo "[php]: Destroyed session \$sessionID\n";
echo "[php]: Test byte reader (read_size=2)\n";
\$bs = new MgByteSource("abcd1234", 8);
\$content = "";
\$br = \$bs->GetReader();
\$buf = "";
while (\$br->Read(\$buf, 2) > 0) {
    echo "Buffer: '\$buf'\n";
    \$content .= \$buf;
}
echo "[php]: Test byte reader2 (read_size=3)\n";
\$bs2 = new MgByteSource("abcd1234", 8);
\$content = "";
\$br2 = \$bs2->GetReader();
\$buf = "";
while (\$br2->Read(\$buf, 3) > 0) {
    echo "Buffer: '\$buf'\n";
    \$content .= \$buf;
}
echo "[php]: Test byte reader3 (stringification)\n";
\$bs3 = new MgByteSource("abcd1234", 8);
\$br3 = \$bs3->GetReader();
echo "Stringified: " . \$br3->ToString() . "\n";
\$agfRw = new MgAgfReaderWriter();
echo "[php]: Trigger an exception\n";
try {
    \$agfRw->Read(NULL);
} catch (MgException \$ex) {
    echo "[php]: MgException caught on AGF rw read\n";
    echo "[php]: MgException - Code: ".\$ex->GetExceptionCode()."\n";
    echo "[php]: MgException - Message: ".\$ex->GetExceptionMessage()."\n";
    echo "[php]: MgException - Details: ".\$ex->GetDetails()."\n";
    echo "[php]: MgException - Stack: ".\$ex->GetStackTrace()."\n";
    echo "Is standard PHP exception too? " . (\$ex instanceof Exception) . "\n";
} catch (Exception \$ex) {
    echo "[php]: Exception: " . \$ex->getMessage() . "\n";
}
echo "[php]: Trigger another exception\n";
try {
    \$r2 = new MgResourceIdentifier("");
} catch (MgException \$ex2) {
    echo "[php]: MgException caught on bad MgResourceIdentifier\n";
    echo "[php]: MgException - Code: ".\$ex2->GetExceptionCode()."\n";
    echo "[php]: MgException - Message: ".\$ex2->GetExceptionMessage()."\n";
    echo "[php]: MgException - Details: ".\$ex2->GetDetails()."\n";
    echo "[php]: MgException - Stack: ".\$ex2->GetStackTrace()."\n";
    echo "Is standard PHP exception too? " . (\$ex2 instanceof Exception) . "\n";
} catch (Exception \$ex) {
    echo "[php]: Exception: " . \$ex->getMessage() . "\n";
}

?>
EOF

    # TODO: Do an equivalent for Java

    # Check deps of all binaries and libraries
    /scripts/dep_check.sh
}

# Pre-flight checks
install_prereqs

# Run installer package
cp /artifacts/"$PACKAGE" /tmp/installer.run
# We run mgserver in interactive mode so that the container does not immediately exit, allowing us to fire off our mapagent
# integration test suite against it from a separate terminal session. Hence the --no-mgserver-start switch
#
# Also mixing up various ports from their defaults to verify all the right ports are configured by the installer
/tmp/installer.run -- --no-mgserver-start --headless --with-sdf --with-shp --with-sqlite --with-gdal --with-ogr --with-wfs --with-wms --with-tomcat --httpd-port $HTTPD_PORT --admin-port 2000 --client-port 2001 --site-port 2002 --tomcat-port 8019
post_install
cd $INST_PATH/server/bin || exit
# TODO: We should also spin up the bundled mgdevhttpserver and fire off the same mapagent integration test suite against
# that as well
./mgserver.sh
