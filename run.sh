#!/bin/sh
# Exports required compile paths for OpenSSL and libyaml NIFs on macOS Homebrew
export CFLAGS="-I/opt/homebrew/opt/openssl@3/include -I/opt/homebrew/include"
export LDFLAGS="-L/opt/homebrew/opt/openssl@3/lib -L/opt/homebrew/lib"

# Start the Rebar3 shell
exec rebar3 shell
