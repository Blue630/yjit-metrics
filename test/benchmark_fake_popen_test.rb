require_relative "test_helper"

# For these tests we don't want to run the harness. We want to fake running the harness
# using a fake popen to avoid interacting with (e.g.) the contents of the yjit-bench repo.
class FakePopen
    def initialize(expected_args: nil, readpartial_results:, worker_pid: 12345, harness_script_pid: 54321)
        @expected_args = expected_args
        @readpartial_results = ["HARNESS PID: #{worker_pid} -\n"] + readpartial_results
        @worker_pid = worker_pid
        @harness_script_pid = harness_script_pid
    end

    def call(args, err:)
        assert_equal(@expected_args, args) if @expected_args

        # For now ignore the value of err but require that it be passed in.

        # We need to set $?, so we'll run a trivial script to say "success"
        system("echo success")

        # This object is both the IO object in popen's block and the object that's called.
        yield(self)
    end

    def pid
        @harness_script_pid
    end

    def readpartial(size)
        val = @readpartial_results.shift
        raise(EOFError.new) if val == :eof
        raise "Some bad thing raised an intentional exception in FakePopen!" if val == :die
        assert(false, "Not enough readpartial_results in FakePopen!") if val.nil?
        val
    end
end

class TestBenchmarkingWithFakePopen < Minitest::Test
    def setup
    end

    # "Basic success" test of the harness runner
    def test_harness_runner
        fake_popen = FakePopen.new readpartial_results: [ "chunk1\n", "chunk2\n", :eof ]

        run_info = YJITMetrics.run_harness_script_from_string("fake script contents", popen = fake_popen, crash_file_check: false, do_echo: false)

        assert_equal false, run_info[:failed]
        assert_equal [], run_info[:crash_files]
        assert_equal 54321, run_info[:harness_script_pid]
        assert_equal 12345, run_info[:worker_pid]
        assert run_info[:output].include?("chunk1"), "First chunk isn't in script output!"
        assert run_info[:output].include?("chunk2"), "First chunk isn't in script output!"
    end

end
