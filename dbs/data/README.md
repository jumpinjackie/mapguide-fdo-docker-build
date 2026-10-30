Database data directories for the fixtures in [../docker-compose.yml](../docker-compose.yml).

Each service bind-mounts a directory of its own here (`postgis`, `postgis_pg11`, `postgis_pg12`,
`postgis_pg14`, `postgis_pg16`, `mariadb`, `mysql_56`, `mysql_80`, `mssql`, `mssql_cs`), so the
database files live on the host instead of in the container's writable layer. The directories are
created on first start and are gitignored apart from this file.

To reset a fixture to a freshly initialised database, delete its directory. Under rootless podman the
directory is chowned to the container's database user, so that needs `podman unshare` rather than a
plain `rm -rf`:

```
podman unshare rm -rf dbs/data/mysql_80
```

`oracle_xe_11g` deliberately has no directory here: its image ships a pre-built XE database that a bind
mount over `/u01/app/oracle/oradata/XE` would mask. See the comment on that service.
