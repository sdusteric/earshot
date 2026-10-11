#!/bin/zsh -f
# app-send.zsh <socket> '<json>': hands one message to Earshot for Mac and
# waits at most 0.2 s for its answer. Exit 0 only when the app answered ok.
# zsh, because its socket module and fractional read timeout come with macOS.
zmodload zsh/net/socket 2>/dev/null || exit 3
zsocket "$1" 2>/dev/null || exit 2
fd=$REPLY
print -r -u $fd -- "$2"
read -t 0.2 -r -u $fd reply || { exec {fd}>&-; exit 1; }
exec {fd}>&-
[[ $reply == '{"ok":true}' ]]
