#!/bin/zsh -f
# fake-app.zsh <socket> <log> <mode>: a stand-in for Earshot for Mac.
# Logs each message line; mode ok answers {"ok":true}, reject answers
# {"ok":false}, silent never answers.
zmodload zsh/net/socket
rm -f "$1"
zsocket -l "$1" || exit 1
listen=$REPLY
while zsocket -a $listen; do
  fd=$REPLY
  if read -r -u $fd line; then
    print -r -- "$line" >> "$2"
    case $3 in
      ok) print -r -u $fd -- '{"ok":true}' ;;
      reject) print -r -u $fd -- '{"ok":false,"reason":"version"}' ;;
      silent) sleep 1 ;;
    esac
  fi
  exec {fd}>&-
done
