#!/usr/bin/bash
# repeatedly submits an authentication request to server and then terminates the spawn netcan session;
while :
do
	echo "AUTH !Q#E%T&U8i6y4r2w" | nc -u 127.0.0.1 23456 &
	printf "\n"
	sleep 1
	pid=$!
	( kill -TERM $pid ) 2>&1
done
