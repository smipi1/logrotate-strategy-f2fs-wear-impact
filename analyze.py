#!/usr/bin/env python3

import csv, sys

seconds_elapsed = 0.0
size_logged = 0.0
sectors_written_min = None
sectors_written_max = None

with open(sys.argv[1]) as f:
    reader = csv.DictReader(f)
    for row in reader:
        seconds_elapsed = max(
            seconds_elapsed,
            float(row['seconds_elapsed'])
        )
        size_logged = max(
            size_logged,
            float(row['size_logged'])
        )
        sectors_written_min = min(
            float(row['sectors_written']),
            float(row['sectors_written']) if sectors_written_min is None else sectors_written_min
        )
        sectors_written_max = max(
            float(row['sectors_written']),
            float(row['sectors_written'] if sectors_written_min is None else sectors_written_min)
        )
    sectors_written = sectors_written_max - sectors_written_min
    bytes_written = sectors_written * 512
    log_rate = size_logged / seconds_elapsed
    wear_rate = bytes_written / seconds_elapsed
    savings = (log_rate - wear_rate) / log_rate
    print(f"log_rate:                  {log_rate:5.2f} B/s")
    print(f"wear_rate:                 {wear_rate:5.2f} B/s")
    print(f"savings:                   {savings*100.0:5.2f} %")
