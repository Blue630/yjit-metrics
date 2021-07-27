# General-purpose benchmark management routines

require 'fileutils'
require 'tempfile'
require 'json'
require 'csv'
require 'erb'

require_relative "./yjit-metrics/bench-results"

# Require all source files in yjit-metrics/report_types/*.rb
Dir.glob("yjit-metrics/report_types/*.rb", base: __dir__).each do |report_type_file|
    require_relative report_type_file
end

module YJITMetrics
    extend self # Make methods callable as YJITMetrics.method_name

    HARNESS_PATH = File.expand_path(__dir__ + "/../metrics-harness")

    # Checked system - error if the command fails
    def check_call(command, verbose: false)
        puts(command)

        if verbose
            status = system(command, out: $stdout, err: :out)
        else
            status = system(command)
        end

        unless status
            puts "Command #{command.inspect} failed in directory #{Dir.pwd}"
            raise RuntimeError.new
        end
    end

    def check_output(command)
        output = IO.popen(command).read
        unless $?.success?
            puts "Command #{command.inspect} failed in directory #{Dir.pwd}"
            raise RuntimeError.new
        end
        output
    end

    def run_script_from_string(script)
        tf = Tempfile.new("yjit-metrics-script")
        tf.write(script)
        tf.flush # No flush can result in successfully running an empty script

        # Passing -l to bash makes sure to load .bash_profile
        # for chruby.
        status = system("bash", "-l", tf.path, out: :out, err: :err)

        unless status
            STDERR.puts "Script failed in directory #{Dir.pwd}"
            raise RuntimeError.new
        end
    ensure
        if(tf)
            tf.close
            tf.unlink
        end
    end

    def per_os_checks
        if RUBY_PLATFORM["darwin"]
            puts "Mac results are considered less stable for this benchmarking harness."
            puts "Please assume you'll need more runs and more time for similar final quality."
            return
        end

        # Only available on intel systems
        if !File.exist?('/sys/devices/system/cpu/intel_pstate/no_turbo')
            return
        end

        File.open('/sys/devices/system/cpu/intel_pstate/no_turbo', mode='r') do |file|
            if file.read.strip != '1'
                puts("You forgot to disable turbo: (note: sudo ./setup.sh will do this)")
                puts("  sudo sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'")
                exit(-1)
            end
        end

        if !File.exist?('/sys/devices/system/cpu/intel_pstate/min_perf_pct')
            return
        end

        File.open('/sys/devices/system/cpu/intel_pstate/min_perf_pct', mode='r') do |file|
            if file.read.strip != '100'
                puts("You forgot to set the min perf percentage to 100: (note: sudo ./setup.sh will do this)")
                puts("  sudo sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'")
                exit(-1)
            end
        end
    end

    def per_os_shell_prelude
      if RUBY_PLATFORM["darwin"]
        []
      elsif RUBY_PLATFORM["win"]
        []
      else
        # On Linux, disable address space randomization for determinism unless YJIT_METRICS_USE_ASLR is specified
        (ENV["YJIT_METRICS_USE_ASLR"] ? [] : ["setarch", "x86_64", "-R"]) +
        # And pin the process to one given core to improve caching
        (ENV["YJIT_METRICS_NO_PIN"] ? [] : ["taskset", "-c", "11"])
      end
    end

    def clone_repo_with(path:, git_url:, git_branch:)
        unless File.exist?(path)
            check_call("git clone '#{git_url}' '#{path}'")
        end

        Dir.chdir(path) do
            check_call("git checkout #{git_branch}")
            check_call("git pull")

            # TODO: git clean?
        end
    end

    def clone_ruby_repo_with(path:, git_url:, git_branch:, config_opts:, config_env: [], install_to:)
        clone_repo_with(path: path, git_url: git_url, git_branch: git_branch)

        Dir.chdir(path) do
            config_opts += [ "--prefix=#{install_to}" ]

            unless File.exist?("./configure")
                check_call("./autogen.sh")
            end

            if !File.exist?("./config.status")
                should_configure = true
            else
                # Right now this config check is brittle - if you give it a config_env containing quotes, for
                # instance, it will tend to believe it needs to reconfigure. We cut out single-quotes
                # because they've caused trouble, but a full fix might need to understand bash quoting.
                config_status_output = check_output("./config.status --conf").gsub("'", "").split(" ").sort
                desired_config = config_opts.sort + config_env
                if config_status_output != desired_config
                    puts "Configuration is wrong, reconfiguring..."
                    puts "Desired: #{desired_config.inspect}"
                    puts "Current: #{config_status_output.inspect}"
                    should_configure = true
                end
            end

            if should_configure
                check_call("#{config_env.join(" ")} ./configure #{ config_opts.join(" ") }")
                check_call("make clean")
            end

            check_call("make -j16 install")
        end
    end

    # Each benchmark returns its data as a simple hash for that benchmark:
    #
    #    {
    #       "times" => [ 2.3, 2.5, 2.7, 2.4, ...],
    #       "benchmark_metadata" => {...},
    #       "ruby_metadata" => {...},
    #       "yjit_stats" => {...},  # Note: yjit_stats may be empty, but is present
    #    }
    #
    # This method returns five separate objects for times, warmups, yjit stats,
    # benchmark metadata and ruby metadata. Note that only a single yjit stats
    # hash is returned for all iterations combined, while times and warmups are
    # arrays with sizes equal to the number of 'real' and warmup iterations,
    # respectively.
    #
    # This method converts the seconds returned by the harness to milliseconds before
    # returning times and warmups.
    def run_benchmark_path_with_runner(bench_name, script_path, output_path:".", ruby_opts: [], with_chruby: nil,
        warmup_itrs: 15, min_benchmark_itrs: 10, min_benchmark_time: 10.0)

        out_json_path = File.expand_path(File.join(output_path, 'temp.json'))
        FileUtils.rm_f(out_json_path) # No stale data please

        ruby_opts_section = ruby_opts.map { |s| '"' + s + '"' }.join(" ")
        script_template = ERB.new File.read(__dir__ + "/../metrics-harness/run_harness.sh.erb")
        bench_script = script_template.result(binding) # Evaluate an Erb template with locals like warmup_itrs

        # Do the benchmarking
        run_script_from_string(bench_script)

        # Read the benchmark data
        single_bench_data = JSON.load(File.read out_json_path)

        # Convert times to ms
        times = single_bench_data["times"].map { |v| 1000 * v.to_f }
        warmups = single_bench_data["warmups"].map { |v| 1000 * v.to_f }

        yjit_stats = {}
        if single_bench_data["yjit_stats"] && !single_bench_data["yjit_stats"].empty?
            yjit_stats = single_bench_data["yjit_stats"]
        end

        benchmark_metadata = single_bench_data["benchmark_metadata"]
        ruby_metadata = single_bench_data["ruby_metadata"]

        # Add per-benchmark metadata from this script to the data returned from the harness.
        benchmark_metadata.merge({
            "benchmark_name" => bench_name,
            "chruby_version" => with_chruby,
            "ruby_opts" => ruby_opts
        })

        return times, warmups, yjit_stats, benchmark_metadata, ruby_metadata
    end

    # Run all the benchmarks and record execution times.
    # This method converts the benchmark_list to a set of benchmark names and paths.
    # It also combines results from multiple worker subprocesses.
    #
    # This method returns a benchmark data array of the following form:


    # For timings, YJIT stats and benchmark metadata, we add a hash inside
    # each top-level key for each benchmark name, e.g.:
    #
    #    "times" => { "yaml-load" => [ 2.3, 2.5, 2.7, 2.4, ...] }
    #
    def run_benchmarks(benchmark_dir, out_path, ruby_opts: [], benchmark_list: [], with_chruby: nil, on_error: nil,
                        warmup_itrs: 15, min_benchmark_itrs: 10, min_benchmark_time: 10.0)
        bench_data = { "times" => {}, "warmups" => {}, "benchmark_metadata" => {}, "ruby_metadata" => {}, "yjit_stats" => {} }

        Dir.chdir(benchmark_dir) do
            # Get the list of benchmark files/directories matching name filters
            bench_files = Dir.children('benchmarks').sort
            legal_bench_names = (bench_files + bench_files.map { |name| name.delete_suffix(".rb") }).uniq
            benchmark_list.map! { |name| name.delete_suffix(".rb") }

            unknown_benchmarks = benchmark_list - legal_bench_names
            raise(RuntimeError.new("Unknown benchmarks: #{unknown_benchmarks.inspect}!")) if unknown_benchmarks.size > 0
            bench_files = benchmark_list if benchmark_list.size > 0

            bench_files.each_with_index do |bench_name, idx|
                puts("Running benchmark \"#{bench_name}\" (#{idx+1}/#{bench_files.length})")

                # Path to the benchmark runner script
                script_path = File.join('benchmarks', bench_name)

                # Choose the first of these that exists
                real_script_path = [script_path, script_path + ".rb", script_path + "/benchmark.rb"].detect { |path| File.exist?(path) && !File.directory?(path) }
                raise "Could not find benchmark file starting from script path #{script_path.inspect}!" unless real_script_path
                script_path = real_script_path

                times, warmups, yjit_stats, bench_metadata, ruby_metadata = run_benchmark_path_with_runner(
                    bench_name, script_path,
                    output_path: out_path, ruby_opts: ruby_opts, with_chruby: with_chruby,
                    warmup_itrs: warmup_itrs, min_benchmark_itrs: min_benchmark_itrs, min_benchmark_time: min_benchmark_time)

                # We don't save individual Ruby metadata for all benchmarks because it
                # should be identical for all of them -- we use the same Ruby
                # every time. Instead we save one copy of it, but we make sure
                # on each subsequent benchmark that it returned exactly the same
                # metadata about the Ruby version.
                bench_data["times"][bench_name] = times
                bench_data["warmups"][bench_name] = warmups
                bench_data["yjit_stats"][bench_name] = [yjit_stats]
                bench_data["benchmark_metadata"][bench_name] = bench_metadata
                bench_data["ruby_metadata"] = ruby_metadata if bench_data["ruby_metadata"].empty?
                if bench_data["ruby_metadata"] != ruby_metadata
                    puts "Ruby metadata 1: #{bench_data["ruby_metadata"].inspect}"
                    puts "Ruby metadata 2: #{ruby_metadata.inspect}"
                    raise "Ruby benchmark metadata should not change across a single set of benchmark runs!"
                end
            end
        end

        return bench_data
    end
end
