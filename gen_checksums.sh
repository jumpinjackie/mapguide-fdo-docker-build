#!/bin/bash

printf "|%-53s|%-12s|%-40s|\n" Name "Size (bytes)" "SHA-1"
pushd artifacts 2>&1 > /dev/null
ls -la --block-size="'1" *.tar.gz | awk '{
  cmd = "sha1sum " $9;
  cmd | getline out;
  print $5, out;
  close(cmd);
}' | awk '{printf("|%-53s|%-12s|%-40s|\n", $3, $1, $2)}'
popd 2>&1 > /dev/null