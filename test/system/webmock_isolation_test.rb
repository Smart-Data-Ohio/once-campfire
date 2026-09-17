require "application_system_test_case"

# Guards the contract that keeps WebMock-enabled system tests (see
# DriveLinkPreviewsTest) from breaking the rest of the browser suite: the
# Capybara selenium driver reuses one HTTP client across tests, so system
# tests must start with WebMock disabled and localhost reachable no matter
# which test ran first in the process.
class WebmockIsolationTest < ApplicationSystemTestCase
  test "system tests start with WebMock disabled and localhost reachable" do
    original_net_http = WebMock::HttpLibAdapters::NetHttpAdapter::OriginalNetHTTP
    assert Net::HTTP.equal?(original_net_http), "WebMock must not leak enabled into system tests"

    assert WebMock.net_connect_allowed?("http://127.0.0.1:9515/session"),
      "localhost chromedriver traffic must stay reachable in system tests"
  end
end
