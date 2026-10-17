#!/bin/zsh -f
# app-send.zsh <socket> '<json>': hands one message to Kobi for Mac and
# waits at most 0.2 s for its answer. Exit 0 only when the app answered ok.
# zsh, because its socket module and fractional read timeout come with macOS.
# The message gets "sent" (epoch ms), so an app that reads it after this gave
# up refuses it instead of saying it a second time.
zmodload zsh/net/socket 2>/dev/null || exit 3
zmodload zsh/datetime 2>/dev/null || exit 3
zsocket "$1" 2>/dev/null || exit 2
fd=$REPLY
integer ms=$(( EPOCHREALTIME * 1000 ))
print -r -u $fd -- "{\"sent\":$ms,${2#\{}"
read -t 0.2 -r -u $fd reply || { exec {fd}>&-; exit 1; }
exec {fd}>&-
[[ $reply == '{"ok":true}' ]]
