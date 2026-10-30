Drop any MapGuide package files here

`./image_install.sh` mounts this directory into the installed server's
`/usr/local/mapguideopensource-<major.minor.rel>/server/Packages` directory, so anything dropped here
is available to the server inside that container. Pass `--no-packages` to mount nothing instead.
