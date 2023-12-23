# Custom SDKs

Put [Oracle Instant/MySQL] Client SDK and other thirdparty lib contents here

Download MySQL Connector/C: https://downloads.mysql.com/archives/get/p/19/file/mysql-connector-c-6.1.11-linux-glibc2.12-x86_64.tar.gz

Download Oracle Instant Client (registration required): https://www.oracle.com/database/technologies/instant-client.html

Download zlib: https://www.zlib.net/

Download postgresql: https://ftp.postgresql.org/pub/source/v16.1/postgresql-16.1.tar.gz

Download MariaDB Connector/C: https://dlm.mariadb.com/3677127/Connectors/c/connector-c-3.3.8/mariadb-connector-c-3.3.8-src.tar.gz

# Expected structure

```
 $ROOT
    sdks
        mysql
            x64
                bin
                docs
                include
                lib
        oracle
            x64
                instantclient_11_2
                    sdk
                        include
                        ...
                instantclient_12_2
                    sdk
                        include
                        ...
```