#!/bin/zsh
# Generate a large CSV for testing BigCSV's "open a multi-GB file instantly" path.
#
# Usage:
#   Scripts/make-sample-csv.sh [output_path] [row_count]
# Examples:
#   Scripts/make-sample-csv.sh SampleData/big.csv 15000000   # ~1 GB
#   Scripts/make-sample-csv.sh SampleData/huge.csv 80000000  # ~5 GB
#
# Each row is ~70 bytes and includes a quoted field containing a comma, so the
# file also exercises quote-aware parsing — not just plain rows.

set -e
out=${1:-SampleData/big.csv}
rows=${2:-15000000}
mkdir -p "$(dirname "$out")"

print "Generating $rows rows -> $out"
{
  print 'id,name,email,amount,note,city'
  awk -v n="$rows" 'BEGIN {
    split("Berlin,Paris,New York,Tokyo,London,Madrid", cities, ",")
    for (i = 1; i <= n; i++) {
      c = cities[(i % 6) + 1]
      amt = ((i * 7919) % 100000) / 100.0
      printf "%d,User %d,user%d@example.com,%.2f,\"note for, row %d\",%s\n", i, i, i, amt, i, c
    }
  }'
} > "$out"

print "Done: $(du -h "$out" | cut -f1) ($rows rows)"
