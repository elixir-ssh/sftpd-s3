#!/usr/bin/env bash

set -e

mkdir -p test/fixtures/ssh_keys/etc/ssh

ssh-keygen -A -f test/fixtures/ssh_keys

mv test/fixtures/ssh_keys/etc/ssh/* test/fixtures/ssh_keys
rm -r test/fixtures/ssh_keys/etc