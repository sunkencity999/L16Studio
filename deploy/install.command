#!/bin/bash
# Double-click this file on a Mac to install L16 Studio on a connected L16.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
./install.sh
status=$?
echo
read -r -p "Press Return to close this window." _
exit $status
