#!/usr/bin/env bash
set -euo pipefail

profile="${1:-dev}"
app_dir="build/${profile}/erlang/aura"
priv_dir="${app_dir}/priv"
otp_root="$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')"
erts_dir="$(find "${otp_root}" -maxdepth 1 -type d -name 'erts-*' | head -n 1)"

mkdir -p "${priv_dir}"
case "$(uname -s)" in
  Darwin) shared_flags=(-dynamiclib -undefined dynamic_lookup) ;;
  Linux) shared_flags=(-shared) ;;
  *) echo "Unsupported secret NIF platform" >&2; exit 1 ;;
esac

cc -std=c11 -Wall -Wextra -Werror -fPIC "${shared_flags[@]}" \
  -I"${erts_dir}/include" \
  -o "${priv_dir}/aura_secret_nif.so" \
  src/aura_secret_nif.c

erlc -o "${app_dir}/ebin" src/aura_secret_nif.erl
