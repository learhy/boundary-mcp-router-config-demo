#!/bin/bash
set -e
PASS="fr12pass!"
read -r -p "Password: " input
if [ "$input" != "$PASS" ]; then
  echo "Access denied"
  exit 1
fi
exec vtysh
