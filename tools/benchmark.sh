#!/usr/bin/env bash
# REQUIRE: titandb_bench binary exists in the current directory

if [ $# -ne 1 ]; then
  echo -n "./benchmark.sh [bulkload/fillseq/overwrite/filluniquerandom/"
  echo    "readrandom/readwhilewriting/readwhilemerging/updaterandom/"
  echo    "mergerandom/randomtransaction/compact]"
  exit 0
fi

# Make it easier to run only the compaction test. Getting valid data requires
# a number of iterations and having an ability to run the test separately from
# rest of the benchmarks helps.
if [ "$COMPACTION_TEST" == "1" -a "$1" != "universal_compaction" ]; then
  echo "Skipping $1 because it's not a compaction test."
  exit 0
fi

# size constants
K=1024
M=$((1024 * K))
G=$((1024 * M))

if [ -z $TITAN ]; then
  TITAN="true"
fi

if [ -z $DB_DIR ]; then
#  echo "DB_DIR is not defined"
#  exit 0
  DB_DIR="db"
fi

if [ -z $WAL_DIR ]; then
#  echo "WAL_DIR is not defined"
#  exit 0
  WAL_DIR="db"
fi

output_dir=${OUTPUT_DIR:-/tmp/}
if [ ! -d $output_dir ]; then
  mkdir -p $output_dir
fi

num_threads=${NUM_THREADS:-1}
mb_written_per_sec=${MB_WRITE_PER_SEC:-0}
# Only for tests that do range scans
num_nexts_per_seek=${NUM_NEXTS_PER_SEEK:-100}
cache_size=${CACHE_SIZE:-$((1 * G))}
compression_max_dict_bytes=${COMPRESSION_MAX_DICT_BYTES:-0}
compression_type=${COMPRESSION_TYPE:-snappy}
duration=${DURATION:-0}

num_keys=${NUM_KEYS:-$((1 * G))}
key_size=${KEY_SIZE:-20}
value_size=${VALUE_SIZE:-100}

const_params="
  --db=$DB_DIR \
  --wal_dir=$WAL_DIR \
  \
  --num=$num_keys \
  --key_size=$key_size \
  --value_size=$value_size \
  --compression_ratio=0.5 \
  --compression_type=$compression_type \
  \
  --block_size=$((64 * K)) \
  --cache_size=$cache_size \
  --cache_numshardbits=6 \
  --cache_index_and_filter_blocks=1 \
  --pin_l0_filter_and_index_blocks_in_cache=1 \
  --bloom_bits=10 \
  \
  --num_levels=7 \
  --write_buffer_size=$((128 * M)) \
  --level_compaction_dynamic_level_bytes=true \
  --max_write_buffer_number=5 \
  --target_file_size_base=$((8 * M)) \
  --max_bytes_for_level_base=$((512 * M)) \
  --max_bytes_for_level_multiplier=10 \
  \
  --max_background_jobs=6 \
  --titan_max_background_gc=6
  --open_files=40960 \
  --statistics=1 \
  --verify_checksum=1 \
  \
  --bytes_per_sync=$((1 * M)) \
  --wal_bytes_per_sync=$((512 * K)) \
  \
  --use_titan=$TITAN"

if [ $duration -gt 0 ]; then
  const_params="$const_params --duration=$duration"
fi

#
# Tune values for level and universal compaction.
# For universal compaction, these level0_* options mean total sorted of runs in
# LSM. In level-based compaction, it means number of L0 files.
#
params_level_compact="$const_params \
                --max_background_jobs=16 \
                --max_write_buffer_number=4 \
                --level0_file_num_compaction_trigger=4 \
                --level0_slowdown_writes_trigger=16 \
                --level0_stop_writes_trigger=20"

params_univ_compact="$const_params \
                --max_background_jobs=20 \
                --max_write_buffer_number=4 \
                --level0_file_num_compaction_trigger=8 \
                --level0_slowdown_writes_trigger=16 \
                --level0_stop_writes_trigger=20"

function summarize_result {
  test_out=$1
  test_name=$2
  bench_name=$3

  # Note that this function assumes that the benchmark executes long enough so
  # that "Compaction Stats" is written to stdout at least once. If it won't
  # happen then empty output from grep when searching for "Sum" will cause
  # syntax errors.
  uptime=$( grep ^Uptime\(secs $test_out | tail -1 | awk '{ printf "%.0f", $2 }' )
  stall_time=$( grep "^Cumulative stall" $test_out | tail -1  | awk '{  print $3 }' )
  stall_pct=$( grep "^Cumulative stall" $test_out| tail -1  | awk '{  print $5 }' )
  ops_sec=$( grep ^${bench_name} $test_out | awk '{ print $5 }' )
  mb_sec=$( grep ^${bench_name} $test_out | awk '{ print $7 }' )
  lo_wgb=$( grep "^  L0" $test_out | tail -1 | awk '{ print $9 }' )
  sum_wgb=$( grep "^ Sum" $test_out | tail -1 | awk '{ print $9 }' )
  sum_size=$( grep "^ Sum" $test_out | tail -1 | awk '{ printf "%.1f", $3 / 1024.0 }' )
  wamp=$( echo "scale=1; $sum_wgb / $lo_wgb" | bc )
  wmb_ps=$( echo "scale=1; ( $sum_wgb * 1024.0 ) / $uptime" | bc )
  usecs_op=$( grep ^${bench_name} $test_out | awk '{ printf "%.1f", $3 }' )
  p50=$( grep "^Percentiles:" $test_out | tail -1 | awk '{ printf "%.1f", $3 }' )
  p75=$( grep "^Percentiles:" $test_out | tail -1 | awk '{ printf "%.1f", $5 }' )
  p99=$( grep "^Percentiles:" $test_out | tail -1 | awk '{ printf "%.0f", $7 }' )
  p999=$( grep "^Percentiles:" $test_out | tail -1 | awk '{ printf "%.0f", $9 }' )
  p9999=$( grep "^Percentiles:" $test_out | tail -1 | awk '{ printf "%.0f", $11 }' )
  echo -e "$ops_sec\t$mb_sec\t$sum_size\t$lo_wgb\t$sum_wgb\t$wamp\t$wmb_ps\t$usecs_op\t$p50\t$p75\t$p99\t$p999\t$p9999\t$uptime\t$stall_time\t$stall_pct\t$test_name" \
    >> $output_dir/report.txt
}

function run_bulkload {
  # This runs with a vector memtable and the WAL disabled to load faster. It is still crash safe and the
  # client can discover where to restart a load after a crash. I think this is a good way to load.

  # TITAN: The implementation of memtable is changed from vector to default skiplist. Because GC in titan need to get in memtable. Vector will cause poor performance.
  echo "Bulk loading $num_keys random keys"
  cmd="./titandb_bench --benchmarks=fillrandom \
       $const_params \
       --use_existing_db=0 \
       --disable_auto_compactions=1 \
       --disable_wal=true
       --sync=false \
       --titan_disable_background_gc=true \
       --threads=${num_threads} \
       --seed=$( date +%s ) \
       2>&1 | tee -a $output_dir/benchmark_bulkload_fillrandom.log"
  echo $cmd | tee $output_dir/benchmark_bulkload_fillrandom.log
  eval $cmd
  summarize_result $output_dir/benchmark_bulkload_fillrandom.log bulkload fillrandom
  echo "Compacting..."
  cmd="./titandb_bench --benchmarks=compact \
       --use_existing_db=1 \
       --disable_auto_compactions=1 \
       --sync=0 \
       $const_params \
       --threads=1 \
       2>&1 | tee -a $output_dir/benchmark_bulkload_compact.log"
  echo $cmd | tee $output_dir/benchmark_bulkload_compact.log
  eval $cmd
}

#
# Parameter description:
#
# $1 - 1 if I/O statistics should be collected.
# $2 - compaction type to use (level=0, universal=1).
# $3 - number of subcompactions.
# $4 - number of maximum background compactions.
#
function run_manual_compaction_worker {
  # This runs with a vector memtable and the WAL disabled to load faster.
  # It is still crash safe and the client can discover where to restart a
  # load after a crash. I think this is a good way to load.

  # TITAN: The implementation of memtable is changed from vector to default skiplist. Because GC in titan need to get in memtable. Vector will cause poor performance.
  echo "Bulk loading $num_keys random keys for manual compaction."

  fillrandom_output_file=$output_dir/benchmark_man_compact_fillrandom_$3.log
  man_compact_output_log=$output_dir/benchmark_man_compact_$3.log

  if [ "$2" == "1" ]; then
    extra_params=$params_univ_compact
  else
    extra_params=$params_level_compact
  fi

  # Make sure that fillrandom uses the same compaction options as compact.
  cmd="./titandb_bench --benchmarks=fillrandom \
       --use_existing_db=0 \
       --disable_auto_compactions=0 \
       --sync=0 \
       $extra_params \
       --threads=$num_threads \
       --compaction_measure_io_stats=$1 \
       --compaction_style=$2 \
       --subcompactions=$3 \
       --allow_concurrent_memtable_write=false \
       --disable_wal=1 \
       --max_background_jobs=$4 \
       --seed=$( date +%s ) \
       2>&1 | tee -a $fillrandom_output_file"

  echo $cmd | tee $fillrandom_output_file
  eval $cmd

  summarize_result $fillrandom_output_file man_compact_fillrandom_$3 fillrandom

  echo "Compacting with $3 subcompactions specified ..."

  # This is the part we're really interested in. Given that compact benchmark
  # doesn't output regular statistics then we'll just use the time command to
  # measure how long this step takes.
  cmd="{ \
       time ./titandb_bench --benchmarks=compact \
       --use_existing_db=1 \
       --disable_auto_compactions=0 \
       --sync=0 \
       $extra_params \
       --threads=$num_threads \
       --compaction_measure_io_stats=$1 \
       --compaction_style=$2 \
       --subcompactions=$3 \
       --max_background_compactions=$4 \
       ;}
       2>&1 | tee -a $man_compact_output_log"

  echo $cmd | tee $man_compact_output_log
  eval $cmd

  # Can't use summarize_result here. One way to analyze the results is to run
  # "grep real" on the resulting log files.
}

function run_univ_compaction {
  # Always ask for I/O statistics to be measured.
  io_stats=1

  # Values: kCompactionStyleLevel = 0x0, kCompactionStyleUniversal = 0x1.
  compaction_style=1

  # Define a set of benchmarks.
  subcompactions=(1 2 4 8 16)
  max_background_jobs=(20 20 10 5 4)

  i=0
  total=${#subcompactions[@]}

  # Execute a set of benchmarks to cover variety of scenarios.
  while [ "$i" -lt "$total" ]
  do
    run_manual_compaction_worker $io_stats $compaction_style ${subcompactions[$i]} \
      ${max_background_jobs[$i]}
    ((i++))
  done
}

function run_fillseq {
  # Make sure that we'll have unique names for all the files so that data won't
  # be overwritten.
  if [ $1 == 1 ]; then
    log_file_name=$output_dir/benchmark_fillseq.wal_disabled.v${value_size}.log
    test_name=fillseq.wal_disabled.v${value_size}
  else
    log_file_name=$output_dir/benchmark_fillseq.wal_enabled.v${value_size}.log
    test_name=fillseq.wal_enabled.v${value_size}
  fi

  echo "Loading $num_keys keys sequentially"
  cmd="./titandb_bench --benchmarks=fillseq \
       --use_existing_db=0 \
       $const_params \
       --disable_wal=$1 \
       --threads=${num_threads} \
       --seed=$( date +%s ) \
       2>&1 | tee -a $log_file_name"
  echo $cmd | tee $log_file_name
  eval $cmd

  # The constant "fillseq" which we pass to titandb_bench is the benchmark name.
  summarize_result $log_file_name $test_name fillseq
}

function run_change {
  operation=$1
  echo "Do $num_keys random $operation"
  out_name="benchmark_${operation}.t${num_threads}.log"
  cmd="./titandb_bench --benchmarks=$operation \
       --use_existing_db=1 \
       $const_params \
       --threads=$num_threads \
       --merge_operator=\"put\" \
       --seed=$( date +%s ) \
       2>&1 | tee -a $output_dir/${out_name}"
  echo $cmd | tee $output_dir/${out_name}
  eval $cmd
  summarize_result $output_dir/${out_name} ${operation}.t${num_threads} $operation
}

function run_filluniquerandom {
  echo "Loading $num_keys unique keys randomly"
  cmd="./titandb_bench --benchmarks=filluniquerandom \
       --use_existing_db=0 \
       --sync=0 \
       $const_params \
       --threads=1 \
       --seed=$( date +%s ) \
       2>&1 | tee -a $output_dir/benchmark_filluniquerandom.log"
  echo $cmd | tee $output_dir/benchmark_filluniquerandom.log
  eval $cmd
  summarize_result $output_dir/benchmark_filluniquerandom.log filluniquerandom filluniquerandom
}

function run_readrandom {
  echo "Reading $num_keys random keys"
  out_name="benchmark_readrandom.t${num_threads}.log"
  cmd="./titandb_bench --benchmarks=readrandom \
       --use_existing_db=1 \
       $const_params \
       --threads=$num_threads \
       --seed=$( date +%s ) \
       2>&1 | tee -a $output_dir/${out_name}"
  echo $cmd | tee $output_dir/${out_name}
  eval $cmd
  summarize_result $output_dir/${out_name} readrandom.t${num_threads} readrandom
}

function run_readwhile {
  operation=$1
  echo "Reading $num_keys random keys while $operation"
  out_name="benchmark_readwhile${operation}.t${num_threads}.log"
  cmd="./titandb_bench --benchmarks=readwhile${operation} \
       --use_existing_db=1 \
       $const_params \
       --threads=$num_threads \
       --merge_operator=\"put\" \
       --seed=$( date +%s ) \
       2>&1 | tee -a $output_dir/${out_name}"
  echo $cmd | tee $output_dir/${out_name}
  eval $cmd
  summarize_result $output_dir/${out_name} readwhile${operation}.t${num_threads} readwhile${operation}
}

function run_rangewhile {
  operation=$1
  full_name=$2
  reverse_arg=$3
  out_name="benchmark_${full_name}.t${num_threads}.log"
  echo "Range scan $num_keys random keys while ${operation} for reverse_iter=${reverse_arg}"
  cmd="./titandb_bench --benchmarks=seekrandomwhile${operation} \
       --use_existing_db=1 \
       $const_params \
       --threads=$num_threads \
       --merge_operator=\"put\" \
       --seek_nexts=$num_nexts_per_seek \
       --reverse_iterator=$reverse_arg \
       --seed=$( date +%s ) \
       2>&1 | tee -a $output_dir/${out_name}"
  echo $cmd | tee $output_dir/${out_name}
  eval $cmd
  summarize_result $output_dir/${out_name} ${full_name}.t${num_threads} seekrandomwhile${operation}
}

function run_range {
  full_name=$1
  reverse_arg=$2
  out_name="benchmark_${full_name}.t${num_threads}.log"
  echo "Range scan $num_keys random keys for reverse_iter=${reverse_arg}"
  cmd="./titandb_bench --benchmarks=seekrandom \
       --use_existing_db=1 \
       $const_params \
       --threads=$num_threads \
       --seek_nexts=$num_nexts_per_seek \
       --reverse_iterator=$reverse_arg \
       --seed=$( date +%s ) \
       2>&1 | tee -a $output_dir/${out_name}"
  echo $cmd | tee $output_dir/${out_name}
  eval $cmd
  summarize_result $output_dir/${out_name} ${full_name}.t${num_threads} seekrandom
}

function run_randomtransaction {
  echo "..."
  cmd="./titandb_bench $params_r --benchmarks=randomtransaction \
       --num=$num_keys \
       --transaction_db \
       --threads=5 \
       --transaction_sets=5 \
       2>&1 | tee $output_dir/benchmark_randomtransaction.log"
  echo $cmd | tee $output_dir/benchmark_rangescanwhilewriting.log
  eval $cmd
}

function now() {
  echo `date +"%s"`
}

report="$output_dir/report.txt"
schedule="$output_dir/schedule.txt"

echo "===== Benchmark ====="

# Run!!!
IFS=',' read -a jobs <<< $1
# shellcheck disable=SC2068
for job in ${jobs[@]}; do

  if [ $job != debug ]; then
    echo "Start $job at `date`" | tee -a $schedule
  fi

  start=$(now)
  if [ $job = bulkload ]; then
    run_bulkload
  elif [ $job = fillseq_disable_wal ]; then
    run_fillseq 1
  elif [ $job = fillseq_enable_wal ]; then
    run_fillseq 0
  elif [ $job = overwrite ]; then
    run_change overwrite
  elif [ $job = updaterandom ]; then
    run_change updaterandom
  elif [ $job = mergerandom ]; then
    run_change mergerandom
  elif [ $job = filluniquerandom ]; then
    run_filluniquerandom
  elif [ $job = readrandom ]; then
    run_readrandom
  elif [ $job = fwdrange ]; then
    run_range $job false
  elif [ $job = revrange ]; then
    run_range $job true
  elif [ $job = readwhilewriting ]; then
    run_readwhile writing
  elif [ $job = readwhilemerging ]; then
    run_readwhile merging
  elif [ $job = fwdrangewhilewriting ]; then
    run_rangewhile writing $job false
  elif [ $job = revrangewhilewriting ]; then
    run_rangewhile writing $job true
  elif [ $job = fwdrangewhilemerging ]; then
    run_rangewhile merging $job false
  elif [ $job = revrangewhilemerging ]; then
    run_rangewhile merging $job true
  elif [ $job = randomtransaction ]; then
    run_randomtransaction
  elif [ $job = universal_compaction ]; then
    run_univ_compaction
  elif [ $job = debug ]; then
    num_keys=1000; # debug
    echo "Setting num_keys to $num_keys"
  else
    echo "unknown job $job"
    exit
  fi
  end=$(now)

  if [ $job != debug ]; then
    echo "Complete $job in $((end-start)) seconds" | tee -a $schedule
  fi

  echo -e "ops/sec\tmb/sec\tSize-GB\tL0_GB\tSum_GB\tW-Amp\tW-MB/s\tusec/op\tp50\tp75\tp99\tp99.9\tp99.99\tUptime\tStall-time\tStall%\tTest"
  tail -1 $output_dir/report.txt

done
