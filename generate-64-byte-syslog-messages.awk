#!/usr/bin/gawk -f

BEGIN {
    if(length(start_seq) == 0) {
        start_seq = 0;
    }
    if(length(message_count) == 0) {
        message_count = 1;
    }
    if(length(message) == 0) {
        message = "%010d: some repetetive 64 byte filler to stuff syslog with\n";
    }
    end_seq = start_seq + message_count;
    for(i = start_seq; i < end_seq; i++) {
        printf(message, i);
    }
}