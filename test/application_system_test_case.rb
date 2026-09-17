require "test_helper"

WebMock.disable!
Capybara.enable_aria_label = true

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Each worker drives its own headless Chrome; twenty of them starve each
  # other and fail at sign-in on a developer machine, while four stay green.
  # PARALLEL_WORKERS still overrides this, which is how CI runs a single worker.
  parallelize(workers: [ Etc.nprocessors, 4 ].min)

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  include SystemTestHelper
end
