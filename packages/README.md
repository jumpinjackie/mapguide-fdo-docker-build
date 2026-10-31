Drop any MapGuide package files here

`./image_install.sh` mounts this directory into the installed server's
`/usr/local/mapguideopensource-<major.minor.rel>/server/Packages` directory, so anything dropped here
is available to the server inside that container. Pass `--no-packages` to mount nothing instead.

## SELinux hosts

Under an SELinux-enforcing host the mount is relabelled to `container_file_t` **when the container is
created**, and only then. A package added while the container is running keeps whatever label it
arrived with, and the container is denied access to it — `ls -l` shows `-??????????` and reading it
gives `Permission denied`, even as root, because SELinux is not bypassed by `CAP_DAC_OVERRIDE`.

`mv` and `cp -a`/`rsync -a` preserve the source's label (a file moved out of `~` stays `user_home_t`);
a plain `cp` inherits this directory's `container_file_t` and is fine. Either way, relabel after
adding to a running container, or simply restart it:

```
chcon -R -t container_file_t .
```
