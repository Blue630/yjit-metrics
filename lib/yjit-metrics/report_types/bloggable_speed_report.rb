require_relative "yjit_stats_reports"

# For details-at-a-specific-time reports, we'll want to find individual configs and make sure everything is
# present and accounted for. This is a "single" report in the sense that it's conceptually at a single
# time, even though it can be multiple runs and Rubies. What it is *not* is results over time as YJIT and
# the benchmarks change.
class YJITMetrics::BloggableSingleReport < YJITMetrics::YJITStatsReport

    # Benchmarks sometimes go into multiple categories, based on the category field
    BENCHMARK_METADATA = {
        # Highly synthetic microbenchmarks
        "30k_ifelse" => {
            single_file: true,
            category: :micro,
            desc: "30_ifelse tests thousands of nested methods containing simple if/else statements.",
        },
        "30k_methods" => {
            single_file: true,
            category: :micro,
            desc: "30_methods tests thousands of nested method calls that mostly just call out to other single-call methods.",
        },
        "cfunc_itself" => {
            single_file: true,
            category: :micro,
            desc: "cfunc_itself just calls the 'itself' method many, many times.",
        },
        "fib" => {
            single_file: true,
            category: :micro,
            desc: "Fib is a simple exponential-time recursive Fibonacci number generator.",
        },
        "getivar" => {
            single_file: true,
            category: :micro,
            desc: "getivar tests the performance of getting instance variable values.",
        },
        "setivar" => {
            single_file: true,
            category: :micro,
            desc: "setivar tests the performance of setting instance variable values.",
        },
        "str_concat" => {
            single_file: true,
            category: :micro,
            desc: "str_concat tests the performance of string concatenation in multiple different encodings.",
        },
        "respond_to" => {
            single_file: true,
            category: :micro,
            desc: "respond_to tests the performance of the respond_to? method.",
        },
        "keyword_args" => {
            single_file: true,
            category: :micro,
            desc: "keyword_args tests the performance of method calls with keyword arguments.",
        },

        # "Shootout" benchmarks, from places like The Computer Language Benchmarks Game
        "binarytrees" => {
            desc: "binarytrees from the Computer Language Benchmarks Game.",
        },
        "fannkuchredux" => {
            desc: "fannkuchredux from the Computer Language Benchmarks Game.",
        },
        "nbody" => {
            desc: "nbody from the Computer Language Benchmarks Game.",
        },

        # Benchmarks with some measure of real-world functionality (e.g. simple library load-tests)
        "activerecord" => {
            category: :headline,
            desc: "activerecord repeatedly queries entries in a SQLite table with highly-random names.",
        },
        "psych-load" => {
            category: :headline,
            desc: "psych-load repeatedly loads a small selection of YAML files taken from various OSS projects.",
        },
        "mail" => {
            category: :headline,
            desc: "mail tests the Mail gem by repeatedly creating an email from a text file and converting it to a string for sending.",
        },
        "liquid-render" => {
            category: :headline,
            desc: "liquid-render renders a chosen-for-profiling Liquid theme repeatedly.",
        },
        "jekyll" => {
            category: :headline,
            unstable: 1, # jekyll has known problems including some kind of resource leak. Jekyll-the-tool is fine, but this usage method is flawed.
            desc: "jekyll reviews and rebuilds a Jekyll site, but is almost entirely scanning directories of files that didn't change.",
        },
        "hexapdf" => {
            category: :headline,
            desc: "hexapdf benchmarks the hexapdf Ruby gem by line-wrapping The Odyssey with specific line-length and font.",
        },
        "erubi" => {
            desc: "erubi compiles a simple Erb template into a method with erubi, then times evaluating that method.",
        },
        "erubi_rails" => {
            desc: "erubi_rails uses Rails template rendering to repeatedly render a stubbed Discourse view.",
        },

        # Real-esque benchmarks that you could pretend are real for a blog post or a paper
        "lee" => {
            desc: "lee is a circuit-board layout solver, deployed in a plausibly reality-like way",
        },
        "railsbench" => {
            category: :headline,
            desc: "railsbench is a read-only tiny SQLite-backed Rails app, querying a small selection of .html.erb routes and JSON routes.",
        },
        "optcarrot" => {
            desc: "optcarrot is a functional headless NES emulator, run on a specific game cartridge for a specific number of frames.",
        },
        "rubykon" => {
            desc: "Ruby solver for Go (the boardgame.) Runs 1,000 iterations forward from an initial starting board.",
        },

    }

    def headline_benchmarks
        @benchmark_names.select { |bench| BENCHMARK_METADATA[bench] && BENCHMARK_METADATA[bench][:category] == :headline }
    end

    def micro_benchmarks
        @benchmark_names.select { |bench| BENCHMARK_METADATA[bench] && BENCHMARK_METADATA[bench][:category] == :micro }
    end

    def benchmark_category_index(bench_name)
        return 0 if BENCHMARK_METADATA[bench_name] && BENCHMARK_METADATA[bench_name][:category] == :headline
        return 2 if BENCHMARK_METADATA[bench_name] && BENCHMARK_METADATA[bench_name][:category] == :micro
        return 1
    end

    def exactly_one_config_with_name(configs, substring, description, none_okay: false)
        matching_configs = configs.select { |name| name.include?(substring) }
        raise "We found more than one candidate #{description} config (#{matching_configs.inspect}) in this result set!" if matching_configs.size > 1
        raise "We didn't find any #{description} config among #{configs.inspect}!" if matching_configs.empty? && !none_okay
        matching_configs[0]
    end

    # Include Truffle data only if we can find it, use MJIT 3.0 and/or 3.1 depending on what's available.
    # YJIT and No-JIT are mandatory.
    def look_up_data_by_ruby(only_platforms: YJITMetrics::PLATFORMS, in_runs: false)
        only_platforms = [only_platforms].flatten
        # Filter config names by given platform(s)
        config_names = @config_names.select { |name| only_platforms.any? { |plat| name.include?(plat) } }

        @with_yjit_config = exactly_one_config_with_name(config_names, "with_yjit", "with-YJIT")
        @with_mjit30_config = exactly_one_config_with_name(config_names, "ruby_30_with_mjit", "with-MJIT3.0", none_okay: true)
        @with_mjit_latest_config = exactly_one_config_with_name(config_names, "prod_ruby_with_mjit", "with-MJIT", none_okay: true)
        @no_jit_config    = exactly_one_config_with_name(config_names, "no_jit", "no-JIT")
        @truffle_config   = exactly_one_config_with_name(config_names, "truffleruby", "Truffle", none_okay: true)

        # Order matters here - we push No-JIT, then MJIT(s), then YJIT and finally TruffleRuby when present
        @configs_with_human_names = [
            ["No JIT", @no_jit_config],
        ]
        @configs_with_human_names.push(["MJIT3.0", @with_mjit30_config]) if @with_mjit30_config
        @configs_with_human_names.push(["MJIT", @with_mjit_latest_config]) if @with_mjit_latest_config
        @configs_with_human_names.push(["YJIT", @with_yjit_config])
        @configs_with_human_names.push(["Truffle", @truffle_config]) if @truffle_config

        # Grab relevant data from the ResultSet
        @times_by_config = {}
        @warmups_by_config = {}
        @ruby_metadata_by_config = {}
        @bench_metadata_by_config = {}
        @peak_mem_by_config = {}
        @yjit_stats = {}
        @configs_with_human_names.map { |name, config| config }.each do |config|
            @times_by_config[config] = @result_set.times_for_config_by_benchmark(config, in_runs: in_runs)
            @warmups_by_config[config] = @result_set.warmups_for_config_by_benchmark(config, in_runs: in_runs)
            @ruby_metadata_by_config[config] = @result_set.metadata_for_config(config)
            @bench_metadata_by_config[config] = @result_set.benchmark_metadata_for_config_by_benchmark(config)
            @peak_mem_by_config[config] = @result_set.peak_mem_bytes_for_config_by_benchmark(config)
        end

        @yjit_stats = @result_set.yjit_stats_for_config_by_benchmark(@stats_config, in_runs: in_runs)
        @benchmark_names = filter_benchmark_names(@times_by_config[@with_yjit_config].keys)

        @times_by_config.each do |config_name, config_results|
            if config_results.nil? || config_results.empty?
                raise("No results for configuration #{config_name.inspect} in #{self.class}!")
            end
            no_result_benchmarks = @benchmark_names.select { |bench_name| config_results[bench_name].nil? || config_results[bench_name].empty? }
            unless no_result_benchmarks.empty?
                # We allow MJIT latest ONLY to have some benchmarks skipped... (empty is also fine)
                if config_name == @with_mjit_latest_config
                    @mjit_is_incomplete = true
                else
                    raise("No results in config #{config_name.inspect} for benchmark(s) #{no_result_benchmarks.inspect} in #{self.class}!")
                end
            end
        end

        no_stats_benchmarks = @benchmark_names.select { |bench_name| !@yjit_stats[bench_name] || !@yjit_stats[bench_name][0] || @yjit_stats[bench_name][0].empty? }
        unless no_stats_benchmarks.empty?
            raise "No YJIT stats found for benchmarks: #{no_stats_benchmarks.inspect}"
        end
    end

    def calc_speed_stats_by_config
        @mean_by_config = {}
        @rsd_pct_by_config = {}
        @speedup_by_config = {}
        @total_time_by_config = {}

        @configs_with_human_names.map { |name, config| config }.each do |config|
            @mean_by_config[config] = []
            @rsd_pct_by_config[config] = []
            @total_time_by_config[config] = 0.0
            @speedup_by_config[config] = [] unless config == @no_jit_config
        end

        @yjit_ratio = []

        @benchmark_names.each do |benchmark_name|
            @configs_with_human_names.each do |name, config|
                this_config_times = @times_by_config[config][benchmark_name]
                this_config_mean = mean_or_nil(this_config_times) # When nil? When a benchmark didn't happen for this config.
                @mean_by_config[config].push this_config_mean
                @total_time_by_config[config] += this_config_times.nil? ? 0.0 : sum(this_config_times)
                this_config_rel_stddev_pct = rel_stddev_pct_or_nil(this_config_times)
                @rsd_pct_by_config[config].push this_config_rel_stddev_pct
            end

            no_jit_mean = @mean_by_config[@no_jit_config][-1] # Last pushed -- the one for this benchmark
            no_jit_rel_stddev_pct = @rsd_pct_by_config[@no_jit_config][-1]
            no_jit_rel_stddev = no_jit_rel_stddev_pct / 100.0  # Get ratio, not percent
            @configs_with_human_names.each do |name, config|
                next if config == @no_jit_config

                this_config_mean = @mean_by_config[config][-1]

                if this_config_mean.nil?
                    @speedup_by_config[config].push [nil, nil]
                else
                    this_config_rel_stddev_pct = @rsd_pct_by_config[config][-1]
                    this_config_rel_stddev = this_config_rel_stddev_pct / 100.0 # Get ratio, not percent
                    speed_ratio = no_jit_mean / this_config_mean
                    speed_rel_stddev = Math.sqrt(no_jit_rel_stddev * no_jit_rel_stddev + this_config_rel_stddev * this_config_rel_stddev)
                    @speedup_by_config[config].push [ speed_ratio, speed_rel_stddev * 100.0 ]
                end

            end

            # A benchmark run may well return multiple sets of YJIT stats per benchmark name/type.
            # For these calculations we just add all relevant counters together.
            this_bench_stats = combined_stats_data_for_benchmarks([benchmark_name])

            total_exits = total_exit_count(this_bench_stats)
            retired_in_yjit = this_bench_stats["exec_instruction"] - total_exits
            total_insns_count = retired_in_yjit + this_bench_stats["vm_insns_count"]
            yjit_ratio_pct = 100.0 * retired_in_yjit.to_f / total_insns_count
            @yjit_ratio.push yjit_ratio_pct
        end
    end

    def calc_mem_stats_by_config
        @peak_mb_by_config = {}
        @mem_ratio_by_config = {}
        @configs_with_human_names.map { |name, config| config }.each do |config|
            @peak_mb_by_config[config] = []
            @mem_ratio_by_config[config] = []
        end
        @mem_overhead_factor_by_benchmark = []
        @inline_mem_used = []
        @outline_mem_used = []

        one_mib = 1024 * 1024.0 # As a float

        @benchmark_names.each.with_index do |benchmark_name, idx|
            no_jit_bytes = mean(@peak_mem_by_config[@no_jit_config][benchmark_name])
            @configs_with_human_names.each do |name, config|
                if @peak_mem_by_config[config][benchmark_name].nil?
                    @peak_mb_by_config[config].push nil
                    @inline_mem_used.push nil
                    @outline_mem_used.push nil
                    if config != @no_jit_config
                        @mem_ratio_by_config[config].push nil
                    end
                else
                    this_config_bytes = mean(@peak_mem_by_config[config][benchmark_name])
                    @peak_mb_by_config[config].push(this_config_bytes / one_mib)

                    # Round MiB upward, even with a single byte used, since we crash if the block isn't allocated.
                    inline_mib = ((@yjit_stats[benchmark_name][0]["inline_code_size"] + (one_mib - 1))/one_mib).to_i
                    outline_mib = ((@yjit_stats[benchmark_name][0]["outlined_code_size"] + (one_mib - 1))/one_mib).to_i

                    @inline_mem_used.push inline_mib
                    @outline_mem_used.push outline_mib

                    # Total mem ratios - not currently displayed
                    if config != @no_jit_config
                        @mem_ratio_by_config[config].push(this_config_bytes / no_jit_bytes)
                    end
                end
            end
            yjit_mem_usage = @peak_mem_by_config[@with_yjit_config][benchmark_name].sum
            no_jit_mem_usage = @peak_mem_by_config[@no_jit_config][benchmark_name].sum
            @mem_overhead_factor_by_benchmark[idx] = (yjit_mem_usage.to_f / no_jit_mem_usage) - 1.0
        end
    end
end

# This report is to compare YJIT's speedup versus other Rubies for a single run or block of runs,
# with a single YJIT head-of-master.
class YJITMetrics::SpeedDetailsReport < YJITMetrics::BloggableSingleReport
    # This report requires a platform name and can't be auto-instantiated by basic_report.rb.
    # Instead, its child report(s) can instantiate it for a specific platform.
    #def self.report_name
    #    "blog_speed_details"
    #end

    # If we can't get stats, the report won't produce sensible results.
    attr_reader :inactive

    def self.report_extensions
        [ "html", "raw_details.html", "svg", "head.svg", "back.svg", "micro.svg", "tripwires.json", "csv" ]
    end

    def initialize(config_names, platform, results, benchmarks: [])
        unless YJITMetrics::PLATFORMS.include?(platform)
            raise "Invalid platform for SpeedDetailsReport: #{platform.inspect}!"
        end
        @platform = platform

        # Permit non-same-platform stats config
        config_names = config_names.select { |name| name.start_with?(platform) || name.include?("yjit_stats") }
        # This can be set up using set_extra_info later.
        @filename_permalinks = {}

        # Set up the parent class, look up relevant data
        super(config_names, results, benchmarks: benchmarks)
        return if @inactive # Can't get stats? Bail out.

        look_up_data_by_ruby

        # Sort benchmarks by headline/micro category, then alphabetically
        @benchmark_names.sort_by! { |bench_name|
            [ benchmark_category_index(bench_name),
              bench_name ] }

        @headings = [ "bench" ] +
            @configs_with_human_names.flat_map { |name, config| [ "#{name} (ms)", "#{name} RSD" ] } +
            @configs_with_human_names.flat_map { |name, config| config == @no_jit_config ? [] : [ "#{name} spd", "#{name} spd RSD" ] } +
            [ "% in YJIT" ]
        # Col formats are only used when formatting entries for a text table, not for CSV
        @col_formats = [ "%s" ] +                                           # Benchmark name
            [ "%.1f", "%.2f%%" ] * @configs_with_human_names.size +         # Mean and RSD per-Ruby
            [ "%.2fx", "%.2f%%" ] * (@configs_with_human_names.size - 1) +  # Speedups per-Ruby
            [ "%.2f%%" ]                                                    # YJIT ratio

        @col_formats[13] = "<b>%.2fx</b>" # Boldface the YJIT speedup column.

        calc_speed_stats_by_config
    end

    def set_extra_info(info)
        super

        if info[:filenames]
            info[:filenames].each do |filename|
                @filename_permalinks[filename] = "https://shopify.github.io/yjit-metrics/raw_benchmark_data/#{filename}"
            end
        end
    end

    # Printed to console
    def report_table_data
        @benchmark_names.map.with_index do |bench_name, idx|
            [ bench_name ] +
                @configs_with_human_names.flat_map { |name, config| [ @mean_by_config[config][idx], @rsd_pct_by_config[config][idx] ] } +
                @configs_with_human_names.flat_map { |name, config| config == @no_jit_config ? [] : @speedup_by_config[config][idx] } +
                [ @yjit_ratio[idx] ]
        end
    end

    # Listed on the details page
    def details_report_table_data
        @benchmark_names.map.with_index do |bench_name, idx|
            bench_desc = ( BENCHMARK_METADATA[bench_name] && BENCHMARK_METADATA[bench_name][:desc] )  || "(no description available)"
            if BENCHMARK_METADATA[bench_name] && BENCHMARK_METADATA[bench_name][:single_file]
                bench_url = "https://github.com/Shopify/yjit-bench/blob/main/benchmarks/#{bench_name}.rb"
            else
                bench_url = "https://github.com/Shopify/yjit-bench/blob/main/benchmarks/#{bench_name}/benchmark.rb"
            end
            [ "<a href=\"#{bench_url}\" title=\"#{bench_desc}\">#{bench_name}</a>" ] +
                @configs_with_human_names.flat_map { |name, config| [ @mean_by_config[config][idx], @rsd_pct_by_config[config][idx] ] } +
                @configs_with_human_names.flat_map { |name, config| config == @no_jit_config ? [] : @speedup_by_config[config][idx] } +
                [ @yjit_ratio[idx] ]
        end
    end

    def to_s
        # This is just used to print the table to the console
        format_as_table(@headings, @col_formats, report_table_data) +
            "\nRSD is relative standard deviation (stddev / mean), expressed as a percent.\n" +
            "Spd is the speed (iters/second) of the optimised implementation -- 2.0x would be twice as many iters per second.\n"
    end

    # For the SVG, we calculate ratios from 0 to 1 for how far across the graph area a coordinate is.
    # Then we convert them here to the actual size of the graph.
    def ratio_to_x(ratio)
        (ratio * 1000).to_s
    end

    def ratio_to_y(ratio)
        (ratio * 600.0).to_s
    end

    # These will be assigned in order to each Ruby
    RUBY_BAR_COLOURS = [ "#7070f8", "orange", "green", "#4F3A7A" ]

    def svg_object(benchmarks: @benchmark_names)
        # If we render a comparative report to file, we need victor for SVG output.
        require "victor"

        svg = Victor::SVG.new :template => :minimal,
            :viewBox => "0 0 1000 600",
            :xmlns => "http://www.w3.org/2000/svg",
            "xmlns:xlink" => "http://www.w3.org/1999/xlink"  # background: '#ddd'

        axis_colour = "#000"
        background_colour = "#EEE"
        text_colour = "#111"
        top_legend_text_colour = "#EEE"

        # Reserve some width on the left for the axis. Include a bit of right-side whitespace.
        left_axis_width = 0.05
        right_whitespace = 0.01

        # Reserve some height for the legend and bottom height for x-axis labels
        bottom_key_height = 0.17
        top_whitespace = 0.05

        plot_left_edge = left_axis_width
        plot_top_edge = top_whitespace
        plot_bottom_edge = 1.0 - bottom_key_height
        plot_width = 1.0 - left_axis_width - right_whitespace
        plot_height = 1.0 - bottom_key_height - top_whitespace

        svg.rect x: ratio_to_x(plot_left_edge), y: ratio_to_y(plot_top_edge),
            width: ratio_to_x(plot_width), height: ratio_to_y(plot_height),
            stroke: axis_colour, fill: background_colour


        # Basic info on Ruby configs and benchmarks
        ruby_configs = @configs_with_human_names.map { |name, config| config }
        ruby_human_names = @configs_with_human_names.map(&:first)
        ruby_config_bar_colour = Hash[ruby_configs.zip(RUBY_BAR_COLOURS)]
        n_configs = ruby_configs.size
        n_benchmarks = benchmarks.size


        # How high do speedup ratios go?
        max_speedup_ratio = benchmarks.map { |bench_name|
            bench_idx = @benchmark_names.index(bench_name)
            @speedup_by_config.values.map { |speedup_by_bench| speedup_by_bench[bench_idx][0] }.compact.max
        }.max
        if max_speedup_ratio.nil?
            $stderr.puts "Error finding Y axis. Benchmarks: #{benchmarks.inspect}."
            $stderr.puts "Speedup data: #{@speedup_by_config.inspect}"
            raise "Error finding axis Y scale for benchmarks: #{benchmarks.inspect}"
        end


        # Now let's calculate some widths...

        # Within each benchmark's horizontal span we'll want 3 or 4 bars plus a bit of whitespace.
        # And we'll reserve 5% of the plot's width for whitespace on the far left and again on the far right.
        plot_padding_ratio = 0.05
        plot_effective_width = plot_width * (1.0 - 2 * plot_padding_ratio)
        plot_effective_left = plot_left_edge + plot_width * plot_padding_ratio
        each_bench_width = plot_effective_width / n_benchmarks
        bar_width = each_bench_width / (n_configs + 1)

        first_bench_left_edge = plot_left_edge + (plot_width * plot_padding_ratio)
        bench_left_edge = (0...n_benchmarks).map { |idx| first_bench_left_edge + idx * each_bench_width }


        # And some heights...
        plot_top_whitespace = 0.15 * plot_height
        plot_effective_top = plot_top_edge + plot_top_whitespace
        plot_effective_height = plot_height - plot_top_whitespace


        # Add axis markers down the left side
        tick_length = 0.008
        font_size = "small"
        # This is the largest power-of-10 multiple of the no-JIT mean that we'd see on the axis. Often it's 1 (ten to the zero.)
        largest_power_of_10 = 10.0 ** Math.log10(max_speedup_ratio).to_i
        # Let's get some nice even numbers for possible distances between ticks
        candidate_division_values =
            [ largest_power_of_10 * 5, largest_power_of_10 * 2, largest_power_of_10, largest_power_of_10 / 2, largest_power_of_10 / 5,
                largest_power_of_10 / 10, largest_power_of_10 / 20 ]
        # We'll try to show between about 4 and 10 ticks along the axis, at nice even-numbered spots.
        division_value = candidate_division_values.detect do |div_value|
            divs_shown = (max_speedup_ratio / div_value).to_i
            divs_shown >= 4 && divs_shown <= 10
        end
        raise "Error figuring out axis scale with max speedup ratio: #{max_speedup_ratio.inspect} (pow10: #{largest_power_of_10.inspect})!" if division_value.nil?
        division_ratio_per_value = plot_effective_height / max_speedup_ratio

        # Now find all the x-axis tick locations
        divisions = []
        cur_div = 0.0
        loop do
            divisions.push cur_div
            cur_div += division_value
            break if cur_div > max_speedup_ratio
        end

        divisions.each do |div_value|
            tick_distance_from_zero = div_value / max_speedup_ratio
            tick_y = plot_effective_top + (1.0 - tick_distance_from_zero) * plot_effective_height
            svg.line x1: ratio_to_x(plot_left_edge - tick_length), y1: ratio_to_y(tick_y),
                x2: ratio_to_x(plot_left_edge), y2: ratio_to_y(tick_y),
                stroke: axis_colour
            svg.text ("%.1f" % div_value),
                x: ratio_to_x(plot_left_edge - 3 * tick_length), y: ratio_to_y(tick_y),
                text_anchor: "end",
                font_weight: "bold",
                font_size: font_size,
                fill: text_colour
        end

        # Set up the top legend with coloured boxes and Ruby config names
        top_legend_box_height = 0.03
        top_legend_box_width = 0.08
        top_legend_text_height = 0.025  # Turns out we can't directly specify this...
        legend_box_stroke_colour = "#888"
        top_legend_item_width = plot_effective_width / n_configs
        n_configs.times do |config_idx|
            item_center_x = plot_effective_left + top_legend_item_width * (config_idx + 0.5)
            item_center_y = plot_top_edge + 0.025
            svg.rect \
                x: ratio_to_x(item_center_x - 0.5 * top_legend_box_width),
                y: ratio_to_y(item_center_y - 0.5 * top_legend_box_height),
                width: ratio_to_x(top_legend_box_width),
                height: ratio_to_y(top_legend_box_height),
                fill: ruby_config_bar_colour[ruby_configs[config_idx]],
                stroke: legend_box_stroke_colour
            svg.text @configs_with_human_names[config_idx][0],
                x: ratio_to_x(item_center_x), y: ratio_to_y(item_center_y + 0.5 * top_legend_text_height),
                font_size: font_size,
                text_anchor: "middle",
                font_weight: "bold",
                fill: top_legend_text_colour
        end


        # Okay. Now let's plot a lot of boxes and whiskers.
        benchmarks.each.with_index do |bench_name, bench_short_idx|
            bench_idx = @benchmark_names.index(bench_name)

            no_jit_mean = @mean_by_config[@no_jit_config][bench_idx]

            bars_width_start = bench_left_edge[bench_short_idx]
            ruby_configs.each.with_index do |config, config_idx|
                human_name = ruby_human_names[config_idx]

                if config == @no_jit_config
                    speedup = 1.0 # No-JIT is always exactly 1x No-JIT
                    rsd_pct = @rsd_pct_by_config[@no_jit_config][bench_idx]
                else
                    speedup, rsd_pct = @speedup_by_config[config][bench_idx]
                end

                # If speedup is nil, there's no such benchmark in this specific case.
                if speedup != nil
                    rsd_ratio = rsd_pct / 100.0
                    bar_height_ratio = speedup / max_speedup_ratio

                    # The calculated number is rel stddev and is scaled by bar height.
                    stddev_ratio = bar_height_ratio * rsd_ratio

                    tooltip_text = "#{"%.2f" % speedup}x baseline speed (#{human_name})"

                    bar_left = bars_width_start + config_idx * bar_width
                    bar_right = bar_left + bar_width
                    bar_lr_center = bar_left + 0.5 * bar_width
                    bar_top = plot_effective_top + (1.0 - bar_height_ratio) * plot_effective_height
                    svg.rect \
                        x: ratio_to_x(bar_left),
                        y: ratio_to_y(bar_top),
                        width: ratio_to_x(bar_width),
                        height: ratio_to_y(bar_height_ratio * plot_effective_height),
                        fill: ruby_config_bar_colour[config],
                        data_tooltip: tooltip_text

                    # Whiskers should be centered around the top of the bar, at a distance of one stddev.
                    top_whisker_y = bar_top - stddev_ratio * plot_effective_height
                    svg.line x1: ratio_to_x(bar_left), y1: ratio_to_y(top_whisker_y),
                        x2: ratio_to_x(bar_right), y2: ratio_to_y(top_whisker_y),
                        stroke: axis_colour
                    bottom_whisker_y = bar_top + stddev_ratio * plot_effective_height
                    svg.line x1: ratio_to_x(bar_left), y1: ratio_to_y(bottom_whisker_y),
                        x2: ratio_to_x(bar_right), y2: ratio_to_y(bottom_whisker_y),
                        stroke: axis_colour
                    svg.line x1: ratio_to_x(bar_lr_center), y1: ratio_to_y(top_whisker_y),
                        x2: ratio_to_x(bar_lr_center), y2: ratio_to_y(bottom_whisker_y),
                        stroke: axis_colour
                end
            end

            # Below all the bars, we'll want a tick on the bottom axis and a name of the benchmark
            bars_width_middle = bars_width_start + 0.5 * each_bench_width
            svg.line x1: ratio_to_x(bars_width_middle), y1: ratio_to_y(plot_bottom_edge),
                x2: ratio_to_x(bars_width_middle), y2: ratio_to_y(plot_bottom_edge + tick_length),
                stroke: axis_colour

            text_end_x = bars_width_middle
            text_end_y = plot_bottom_edge + tick_length * 3
            svg.text bench_name.gsub(/\.rb$/, ""),
                x: ratio_to_x(text_end_x),
                y: ratio_to_y(text_end_y),
                fill: text_colour,
                font_size: font_size,
                font_family: "monospace",
                font_weight: "bold",
                text_anchor: "end",
                transform: "rotate(-60, #{ratio_to_x(text_end_x)}, #{ratio_to_y(text_end_y)})"
        end

        svg
    end

    def speedup_tripwires
        tripwires = {}
        micro = micro_benchmarks
        @benchmark_names.each_with_index do |bench_name, idx|
            tripwires[bench_name] = {
                mean: @mean_by_config[@with_yjit_config][idx],
                rsd_pct: @rsd_pct_by_config[@with_yjit_config][idx],
                micro: micro.include?(bench_name),
            }
        end
        tripwires
    end

    def write_file(filename)
        if @inactive
            # Can't get stats? Write an empty file.
            self.class.report_extensions.each do |ext|
                File.open(filename + ".{@platform}.#{ext}", "w") { |f| f.write("") }
            end
            return
        end

        require "victor"

        head_bench = headline_benchmarks
        micro_bench = micro_benchmarks
        back_bench = @benchmark_names - head_bench - micro_bench

        if head_bench.empty?
            puts "Warning: when writing file #{filename.inspect}, headlining benchmark list is empty!"
        end
        if micro_bench.empty?
            puts "Warning: when writing file #{filename.inspect}, micro benchmark list is empty!"
        end
        if back_bench.empty?
            puts "Warning: when writing file #{filename.inspect}, miscellaneous benchmark list is empty!"
        end

        [
            [ @benchmark_names, ".svg" ],
            [ head_bench, ".head.svg" ],
            [ micro_bench, ".micro.svg" ],
            [ back_bench, ".back.svg" ],
        ].each do |bench_names, extension|
            if bench_names.empty?
                contents = ""
            else
                contents = svg_object(benchmarks: bench_names).render
            end

            File.open(filename + "." + @platform + extension, "w") { |f| f.write(contents) }
        end

        # First the 'regular' details report, with tables and text descriptions
        script_template = ERB.new File.read(__dir__ + "/../report_templates/blog_speed_details.html.erb")
        html_output = script_template.result(binding)
        File.open(filename + ".#{@platform}.html", "w") { |f| f.write(html_output) }

        # And then the "no normal person would ever care" details report, with raw everything
        script_template = ERB.new File.read(__dir__ + "/../report_templates/blog_speed_raw_details.html.erb")
        html_output = script_template.result(binding)
        File.open(filename + ".#{@platform}.raw_details.html", "w") { |f| f.write(html_output) }

        # The Tripwire report is used to tell when benchmark performance drops suddenly
        json_data = speedup_tripwires
        File.open(filename + ".#{@platform}.tripwires.json", "w") { |f| f.write JSON.pretty_generate json_data }

        write_to_csv(filename + ".#{@platform}.csv", [@headings] + report_table_data)
    end

end

class YJITMetrics::SpeedDetailsMultiplatformReport < YJITMetrics::Report
    def self.report_name
        "blog_speed_details"
    end

    # Report-extensions tries to be data-agnostic. That doesn't work very well here.
    # It turns out that the platforms in the result set determine a lot of the
    # files we generate. So we approximate by generating (sometimes-empty) indicator
    # files. That way we still rebuild all the platform-specific files if they have
    # been removed or a new type is added.
    def self.report_extensions
        ::YJITMetrics::SpeedDetailsReport.report_extensions
    end

    def initialize(config_names, results, benchmarks: [])
        # We need to instantiate N sub-reports for N platforms
        @platforms = results.platforms
        @sub_reports = {}
        @platforms.each do |platform|
            platform_config_names = config_names.select { |name| name.start_with?(platform) }

            # If we can't find a config with stats for this platform, is there one in x86_64?
            unless platform_config_names.detect { |config| config.include?("yjit_stats") }
                x86_stats_config = config_names.detect { |config| config.start_with?("x86_64") && config.include?("yjit_stats") }
                puts "Can't find #{platform} stats config, falling back to using x86_64 stats"
                platform_config_names << x86_stats_config if x86_stats_config
            end

            @sub_reports[platform] = ::YJITMetrics::SpeedDetailsReport.new(platform_config_names, platform, results, benchmarks: benchmarks)
            if @sub_reports[platform].inactive
                puts "Platform config names: #{platform_config_names.inspect}"
                puts "All config names: #{config_names.inspect}"
                raise "Unable to produce stats-capable report for platform #{platform.inspect} in SpeedDetailsMultiplatformReport!"
            end
        end
    end

    def write_file(filename)
        # First, write out per-platform reports
        @sub_reports.values.each do |report|
            # Each sub-report will add the platform name for itself
            report.write_file(filename)
        end

        # extensions:

        # For each of these types, we'll just include for each platform and we can switch display
        # in the Jekyll site. They exist, but there's no combined multiplatform version.
        # We'll create an empty 'tracker' file for the combined version.
        ::YJITMetrics::SpeedDetailsReport.report_extensions.each do |ext|
            outfile = "#{filename}.#{ext}"
            File.open(outfile, "w") { |f| f.write("") }
        end
    end
end

# This report is to compare YJIT's speedup versus other Rubies for a single run or block of runs,
# with a single YJIT head-of-master.
class YJITMetrics::MemoryDetailsReport < YJITMetrics::BloggableSingleReport
    # This report requires a platform name and can't be auto-instantiated by basic_report.rb.
    # Instead, its child report(s) can instantiate it for a specific platform.
    #def self.report_name
    #    "blog_memory_details"
    #end

    def self.report_extensions
        [ "html" ]
    end

    def initialize(config_names, platform, results, benchmarks: [])
        unless YJITMetrics::PLATFORMS.include?(platform)
            raise "Invalid platform for SpeedDetailsReport: #{platform.inspect}!"
        end
        @platform = platform

        # Set up the parent class, look up relevant data
        # Permit non-same-platform stats config
        config_names = config_names.select { |name| name.start_with?(platform) || name.include?("yjit_stats") }
        super(config_names, results, benchmarks: benchmarks)
        return if @inactive

        look_up_data_by_ruby

        # Sort benchmarks by headline/micro category, then alphabetically
        @benchmark_names.sort_by! { |bench_name|
            [ benchmark_category_index(bench_name),
              #-@yjit_stats[bench_name][0]["compiled_iseq_count"],
              bench_name ] }

        @headings = [ "bench" ] +
            @configs_with_human_names.map { |name, config| "#{name} mem (MiB)"} +
            [ "Inline Code", "Outlined Code", "YJIT Mem overhead" ]
            #@configs_with_human_names.flat_map { |name, config| config == @no_jit_config ? [] : [ "#{name} mem ratio" ] }
        # Col formats are only used when formatting entries for a text table, not for CSV
        @col_formats = [ "%s" ] +                               # Benchmark name
            [ "%d" ] * @configs_with_human_names.size +         # Mem usage per-Ruby
            [ "%d", "%d", "%.1f%%" ]                            # YJIT mem breakdown
            #[ "%.2fx" ] * (@configs_with_human_names.size - 1)  # Mem ratio per-Ruby

        calc_mem_stats_by_config
    end

    # Printed to console
    def report_table_data
        @benchmark_names.map.with_index do |bench_name, idx|
            [ bench_name ] +
                @configs_with_human_names.map { |name, config| @peak_mb_by_config[config][idx] } +
                [ @inline_mem_used[idx], @outline_mem_used[idx] ]
                #[ "#{"%d" % (@peak_mb_by_config[@with_yjit_config][idx] - 256)} + #{@inline_mem_used[idx]}/128 + #{@outline_mem_used[idx]}/128" ]
                #@configs_with_human_names.flat_map { |name, config| config == @no_jit_config ? [] : @mem_ratio_by_config[config][idx] }
        end
    end

    # Listed on the details page
    def details_report_table_data
        @benchmark_names.map.with_index do |bench_name, idx|
            bench_desc = ( BENCHMARK_METADATA[bench_name] && BENCHMARK_METADATA[bench_name][:desc] )  || "(no description available)"
            if BENCHMARK_METADATA[bench_name] && BENCHMARK_METADATA[bench_name][:single_file]
                bench_url = "https://github.com/Shopify/yjit-bench/blob/main/benchmarks/#{bench_name}.rb"
            else
                bench_url = "https://github.com/Shopify/yjit-bench/blob/main/benchmarks/#{bench_name}/benchmark.rb"
            end
            [ "<a href=\"#{bench_url}\" title=\"#{bench_desc}\">#{bench_name}</a>" ] +
                @configs_with_human_names.map { |name, config| @peak_mb_by_config[config][idx] } +
                [ @inline_mem_used[idx], @outline_mem_used[idx], @mem_overhead_factor_by_benchmark[idx] * 100.0 ]
                #[ "#{"%d" % (@peak_mb_by_config[@with_yjit_config][idx] - 256)} + #{@inline_mem_used[idx]}/128 + #{@outline_mem_used[idx]}/128" ]
                #@configs_with_human_names.flat_map { |name, config| config == @no_jit_config ? [] : @mem_ratio_by_config[config][idx] }
        end
    end

    def to_s
        # This is just used to print the table to the console
        format_as_table(@headings, @col_formats, report_table_data) +
            "\nMemory usage is in MiB (mebibytes,) rounded. Ratio is versus interpreted baseline CRuby.\n"
    end

    def write_file(filename)
        if @inactive
            # Can't get stats? Write an empty file.
            self.class.report_extensions.each do |ext|
                File.open(filename + ".#{@platform}.#{ext}", "w") { |f| f.write("") }
            end
            return
        end

        # Memory details report, with tables and text descriptions
        script_template = ERB.new File.read(__dir__ + "/../report_templates/blog_memory_details.html.erb")
        html_output = script_template.result(binding)
        File.open(filename + ".#{@platform}.html", "w") { |f| f.write(html_output) }
    end

end

class YJITMetrics::MemoryDetailsMultiplatformReport < YJITMetrics::Report
    def self.report_name
        "blog_memory_details"
    end

    # Report-extensions tries to be data-agnostic. That doesn't work very well here.
    # It turns out that the platforms in the result set determine a lot of the
    # files we generate. So we approximate by generating (sometimes-empty) indicator
    # files. That way we still rebuild all the platform-specific files if they have
    # been removed or a new type is added.
    def self.report_extensions
        ::YJITMetrics::MemoryDetailsReport.report_extensions
    end

    def initialize(config_names, results, benchmarks: [])
        # We need to instantiate N sub-reports for N platforms
        @platforms = results.platforms
        @sub_reports = {}
        @platforms.each do |platform|
            platform_config_names = config_names.select { |name| name.start_with?(platform) }

            # If we can't find a config with stats for this platform, is there one in x86_64?
            unless platform_config_names.detect { |config| config.include?("yjit_stats") }
                x86_stats_config = config_names.detect { |config| config.start_with?("x86_64") && config.include?("yjit_stats") }
                puts "Can't find #{platform} stats config, falling back to using x86_64 stats"
                platform_config_names << x86_stats_config if x86_stats_config
            end

            @sub_reports[platform] = ::YJITMetrics::MemoryDetailsReport.new(platform_config_names, platform, results, benchmarks: benchmarks)
            if @sub_reports[platform].inactive
                raise "Unable to produce stats-capable report for platform #{platform.inspect} in MemoryDetailsMultiplatformReport!"
            end
        end
    end

    def write_file(filename)
        # First, write out per-platform reports
        @sub_reports.each do |platform, report|
            # Each sub-report will add the platform name for itself
            report.write_file(filename)
        end

        # For each of these types, we'll just include for each platform and we can switch display
        # in the Jekyll site. They exist, but there's no combined multiplatform version.
        # We'll create an empty 'tracker' file for the combined version.
        File.open("#{filename}.html", "w") { |f| f.write("") }
    end
end

# Count up number of iterations and warmups for each Ruby and benchmark configuration.
# As we vary these, we need to make sure people can see what settings we're using for each Ruby.
class YJITMetrics::IterationCountReport < YJITMetrics::BloggableSingleReport
    def self.report_name
        "iteration_count"
    end

    def self.report_extensions
        ["html"]
    end

    def initialize(config_names, results, benchmarks: [])
        # Set up the parent class, look up relevant data
        super

        return if @inactive

        # This report can just run with one platform's data and everything's fine.
        # The iteration counts should be identical on other platforms.
        look_up_data_by_ruby only_platforms: results.platforms[0]

        # Sort benchmarks by headline/micro category, then alphabetically
        @benchmark_names.sort_by! { |bench_name|
            [ benchmark_category_index(bench_name),
              bench_name ] }

        @headings = [ "bench" ] +
            @configs_with_human_names.flat_map { |name, config| [ "#{name} warmups", "#{name} iters" ] }
        # Col formats are only used when formatting entries for a text table, not for CSV
        @col_formats = [ "%s" ] +                               # Benchmark name
            [ "%d", "%d" ] * @configs_with_human_names.size     # Iterations per-Ruby-config
    end

    # Listed on the details page
    def iterations_report_table_data
        @benchmark_names.map do |bench_name|
            [ bench_name ] +
                @configs_with_human_names.flat_map do |_, config|
                    if @times_by_config[config][bench_name]
                        [
                            @warmups_by_config[config][bench_name].size,
                            @times_by_config[config][bench_name].size,
                        ]
                    else
                        # If we didn't run this benchmark for this config, we'd like the columns to be blank.
                        [ nil, nil ]
                    end
                end
        end
    end

    def write_file(filename)
        if @inactive
            # Can't get stats? Write an empty file.
            self.class.report_extensions.each do |ext|
                File.open(filename + ".#{ext}", "w") { |f| f.write("") }
            end
            return
        end

        # Memory details report, with tables and text descriptions
        script_template = ERB.new File.read(__dir__ + "/../report_templates/iteration_count.html.erb")
        html_output = script_template.result(binding)
        File.open(filename + ".html", "w") { |f| f.write(html_output) }
    end

end


# This report is to compare YJIT's speedup versus other Rubies for a single run or block of runs,
# with a single YJIT head-of-master.
class YJITMetrics::BlogYJITStatsReport < YJITMetrics::BloggableSingleReport
    def self.report_name
        "blog_yjit_stats"
    end

    def self.report_extensions
        ["html"]
    end

    def set_extra_info(info)
        super

        if info[:timestamps]
            @timestamps = info[:timestamps]
            if @timestamps.size != 1
                raise "WE REQUIRE A SINGLE TIMESTAMP FOR THIS REPORT RIGHT NOW!"
            end
            @timestamp_str = @timestamps[0].strftime("%Y-%m-%d-%H%M%S")
        end
    end

    def initialize(config_names, results, benchmarks: [])
        # Set up the parent class, look up relevant data
        super
        return if @inactive

        # This report can just run with one platform's data and everything's fine.
        # The stats data should be basically identical on other platforms.
        look_up_data_by_ruby only_platforms: results.platforms[0]

        # Sort benchmarks by headline/micro category, then alphabetically
        @benchmark_names.sort_by! { |bench_name|
            [ benchmark_category_index(bench_name),
              bench_name ] }

        @headings_with_tooltips = {
            "bench" => "Benchmark name",
            "Exit Report" => "Link to a generated YJIT-stats-style exit report",
            "Inline" => "Bytes of inlined code generated",
            "Outlined" => "Bytes of outlined code generated",
            "Comp iSeqs" => "Number of compiled iSeqs (methods)",
            "Comp Blocks" => "Number of compiled blocks",
            "Inval" => "Number of methods or blocks invalidated",
            "Inval Ratio" => "Number of blocks invalidated over number of blocks compiled",
            "Bind Alloc" => "Number of Ruby bindings allocated",
            "Bind Set" => "Number of variables set via bindings",
            "Const Bumps" => "Number of times Ruby clears its internal constant cache",
        }

        # Col formats are only used when formatting entries for a text table, not for CSV
        @col_formats = @headings_with_tooltips.keys.map { "%s" }
    end

    # Listed on the details page
    def details_report_table_data
        @benchmark_names.map.with_index do |bench_name, idx|
            bench_desc = ( BENCHMARK_METADATA[bench_name] && BENCHMARK_METADATA[bench_name][:desc] )  || "(no description available)"
            if BENCHMARK_METADATA[bench_name] && BENCHMARK_METADATA[bench_name][:single_file]
                bench_url = "https://github.com/Shopify/yjit-bench/blob/main/benchmarks/#{bench_name}.rb"
            else
                bench_url = "https://github.com/Shopify/yjit-bench/blob/main/benchmarks/#{bench_name}/benchmark.rb"
            end

            exit_report_url = "https://raw.githubusercontent.com/Shopify/yjit-metrics/pages/_includes/reports/blog_exit_reports_#{@timestamp_str}.#{bench_name}.html"

            bench_stats = @yjit_stats[bench_name][0]

            fmt_inval_ratio = "?"
            if bench_stats["invalidation_count"] && bench_stats["compiled_block_count"]
                inval_ratio = bench_stats["invalidation_count"].to_f / bench_stats["compiled_block_count"]
                fmt_inval_ratio = "%d%%" % (inval_ratio * 100.0).to_i
            end

            [ "<a href=\"#{bench_url}\" title=\"#{bench_desc}\">#{bench_name}</a>",
                "<a href=\"#{exit_report_url}\">(click)</a>",
                bench_stats["inline_code_size"],
                bench_stats["outlined_code_size"],
                bench_stats["compiled_iseq_count"],
                bench_stats["compiled_block_count"],
                bench_stats["invalidation_count"],
                fmt_inval_ratio,
                bench_stats["binding_allocations"],
                bench_stats["binding_set"],
                bench_stats["constant_state_bumps"],
            ]

        end
    end

    def write_file(filename)
        if @inactive
            # Can't get stats? Write an empty file.
            self.class.report_extensions.each do |ext|
                File.open(filename + ".#{ext}", "w") { |f| f.write("") }
            end
            return
        end

        # Memory details report, with tables and text descriptions
        script_template = ERB.new File.read(__dir__ + "/../report_templates/blog_yjit_stats.html.erb")
        html_output = script_template.result(binding)
        File.open(filename + ".html", "w") { |f| f.write(html_output) }
    end

end

class BlogStatsExitReports < YJITMetrics::BloggableSingleReport
    def self.report_name
        "blog_exit_reports"
    end

    def self.report_extensions
        ["bench_list.html"]
    end

    def write_file(filename)
        if @inactive
            # Can't get stats? Write an empty file.
            self.class.report_extensions.each do |ext|
                File.open(filename + ".#{ext}", "w") { |f| f.write("") }
            end
            return
        end

        @benchmark_names.each do |bench_name|
            File.open("#{filename}.#{bench_name}.html", "w") { |f| f.puts exit_report_for_benchmarks([bench_name]) }
        end

        # This is a file with a known name that we can look for when generating.
        File.open("#{filename}.bench_list.html", "w") { |f| f.puts @benchmark_names.join("\n") }
    end
end

# This very small report is to give the quick headlines and summary for a YJIT comparison.
class YJITMetrics::SpeedHeadlineReport < YJITMetrics::BloggableSingleReport
    def self.report_name
        "blog_speed_headline"
    end

    def self.report_extensions
        ["html"]
    end

    def format_speedup(ratio)
        if ratio >= 1.01
            "%.1f%% faster" % ((ratio - 1.0) * 100)
        elsif ratio < 0.99
            "%.1f%% slower" % ((1.0 - ratio) * 100)
        else
            "the same speed" # Grammar's not perfect here
        end
    end

    def initialize(config_names, results, benchmarks: [])
        # Set up the parent class, look up relevant data
        super
        return if @inactive # Can't get stats? Bail out.

        # Give the headline data for x86 processors, not ARM64.
        # Note: as written, this will break for any data *not* including x86. Do we care?
        look_up_data_by_ruby(only_platforms: ["x86_64"])

        # Report the headlining speed comparisons versus current prerelease MJIT if available, or fall back to MJIT
        if @mjit_is_incomplete
            @with_mjit_config = @with_mjit30_config
        else
            @with_mjit_config = @with_mjit_latest_config || @with_mjit30_config
        end
        @mjit_name = "MJIT"
        @mjit_name = "MJIT (3.0)" if @with_mjit_config == @with_mjit30_config

        # Sort benchmarks by headline/micro category, then alphabetically
        @benchmark_names.sort_by! { |bench_name|
            [ benchmark_category_index(bench_name),
              #-@yjit_stats[bench_name][0]["compiled_iseq_count"],
              bench_name ] }

        calc_speed_stats_by_config

        # "Ratio of total times" method
        #@yjit_vs_cruby_ratio = @total_time_by_config[@no_jit_config] / @total_time_by_config[@with_yjit_config]
        #@yjit_vs_mjit_ratio = @total_time_by_config[@with_mjit_config] / @total_time_by_config[@with_yjit_config]

        headline_runtimes = headline_benchmarks.map do |bench_name|
            bench_idx = @benchmark_names.index(bench_name)

            bench_no_jit_mean = @mean_by_config[@no_jit_config][bench_idx]
            bench_yjit_mean = @mean_by_config[@with_yjit_config][bench_idx]

            [ bench_yjit_mean, bench_no_jit_mean ]
        end
        # Geometric mean of headlining benchmarks only
        @yjit_vs_cruby_ratio = geomean headline_runtimes.map { |yjit_mean, no_jit_mean| no_jit_mean / yjit_mean }

        @railsbench_idx = @benchmark_names.index("railsbench")
        if @railsbench_idx
            @yjit_vs_cruby_railsbench_ratio = @mean_by_config[@no_jit_config][@railsbench_idx] / @mean_by_config[@with_yjit_config][@railsbench_idx]
        end
    end

    def to_s
        script_template = ERB.new File.read(__dir__ + "/../report_templates/blog_speed_headline.html.erb")
        script_template.result(binding) # Evaluate an Erb template with template_settings
    end

    def write_file(filename)
        if @inactive
            # Can't get stats? Write an empty file.
            self.class.report_extensions.each do |ext|
                File.open(filename + ".#{ext}", "w") { |f| f.write("") }
            end
            return
        end

        html_output = self.to_s
        File.open(filename + ".html", "w") { |f| f.write(html_output) }
    end
end
