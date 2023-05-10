# Custom SDKs

Put [Oracle Instant/MySQL] Client SDK and other thirdparty lib contents here

Download MySQL Connector/C: https://downloads.mysql.com/archives/get/p/19/file/mysql-connector-c-6.1.11-linux-glibc2.12-x86_64.tar.gz

Download Oracle Instant Client (registration required): https://www.oracle.com/database/technologies/instant-client.html

Download zlib: https://www.zlib.net/

Download postgresql: https://ftp.postgresql.org/pub/source/v12.6/postgresql-12.6.tar.gz

Download MariaDB Connector/C: https://downloads.mariadb.org/connector-c/3.1.12/

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