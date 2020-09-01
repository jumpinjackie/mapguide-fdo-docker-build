# Custom SDKs

Put [Oracle Instant/MySQL] Client SDK contents here

Download MySQL Connector/C: https://downloads.mysql.com/archives/get/p/19/file/mysql-connector-c-6.1.11-linux-glibc2.12-x86_64.tar.gz

Download Oracle Instant Client (registration required): https://www.oracle.com/database/technologies/instant-client.html

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