#!/bin/bash
set -e

apt update

apt install -y \
  qemu-user-binfmt \
  qemu-user-static \
  binfmt-support

update-binfmts --enable
