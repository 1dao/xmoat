#!/bin/sh
# Start xmoat. Config comes from xmoat.cfg (and xmoat.local.cfg, which is
# loaded first and wins); override any key on the command line, e.g.
#   ./start.sh LISTEN_PORT=9000
cd "$(dirname "$0")" || exit 1
exec bin/xnet main.lua SERVER_NAME=xmoat "$@"
