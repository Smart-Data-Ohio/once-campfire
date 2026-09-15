require "minitest/autorun"
require "tempfile"
load File.expand_path("../../bin/boot", __dir__)

class BootProcessMonitorTest < Minitest::Test
  LIVEKIT_ENVIRONMENT = ProcessMonitor::OPTIONAL_PROCESS_ENVIRONMENT.fetch("huddle_reconciler")

  def setup
    @original_environment = LIVEKIT_ENVIRONMENT.to_h { |name| [ name, ENV[name] ] }
    LIVEKIT_ENVIRONMENT.each { |name| ENV.delete(name) }
    @procfile = Tempfile.new("Procfile")
    @procfile.write("web: start-web\nhuddle_reconciler: start-reconciler\n")
    @procfile.close
  end

  def teardown
    @original_environment.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
    @procfile.unlink
  end

  def test_non_huddle_boot_keeps_only_the_existing_processes
    assert_equal [ "web" ], process_names
  end

  def test_complete_huddle_configuration_adds_the_reconciler
    LIVEKIT_ENVIRONMENT.each { |name| ENV[name] = "configured" }

    assert_equal %w[ web huddle_reconciler ], process_names
  end

  def test_partial_huddle_configuration_fails_without_printing_values
    ENV["LIVEKIT_URL"] = "private-value"

    _output, error = capture_io do
      assert_raises(SystemExit) { process_names }
    end

    assert_includes error, "Incomplete huddle configuration"
    refute_includes error, "private-value"
  end

  private
    def process_names
      ProcessMonitor.allocate.send(:process_list, @procfile.path).map { |process| process.instance_variable_get(:@name) }
    end
end
