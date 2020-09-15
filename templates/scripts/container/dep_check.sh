#!/bin/sh
NOT_FOUND=$(ldd $1 | grep "not found")
if [ -n "$NOT_FOUND" ]; then
    case "$1" in
        *KingOracleProvider*) # We expect users to bring their own OCI for legal reasons so we expect dep check to fail for this library
            echo "Skipping dependency check on $1: We're expecting you to bring your own OCI"
            ;;
        *)
            echo "$1 has missing dependencies:"
            echo "$NOT_FOUND"
            exit 1
            ;;
    esac
else
    echo "$1: All dependencies met"
fi
exit 0