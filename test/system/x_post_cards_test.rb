require "application_system_test_case"

class XPostCardsTest < ApplicationSystemTestCase
  setup do
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  teardown do
    WebMock.reset!
    WebMock.disable!
  end

  # Belt and suspenders around the teardown above: WebMock must never leak
  # out of this file, even when a test or an earlier teardown step errors.
  # The browser's HTTP client is shared across tests (see
  # ApplicationSystemTestCase), so leaving WebMock enabled here breaks every
  # later system test's chromedriver traffic.
  def after_teardown
    super
  ensure
    WebMock.reset!
    WebMock.disable!
  end

  test "a posted x.com link fills its card in without reloading" do
    stub_fxtwitter_post

    sign_in "jz@37signals.com"
    join_room rooms(:designers)

    send_message "check https://x.com/jack/status/140 out"

    assert_selector ".x-post-card__loading", text: "Loading post…"
    perform_enqueued_jobs

    assert_selector ".x-post-card__name", text: "jack"
    assert_selector ".x-post-card__handle", text: "@jack"
    assert_selector ".x-post-card__text", text: "just setting up my twttr"
    assert_selector ".x-post-card__link", text: "View on X"
  end

  private
    def stub_fxtwitter_post
      tweet = {
        "url" => "https://x.com/jack/status/140",
        "id" => "140",
        "text" => "just setting up my twttr",
        "created_at" => "Tue Mar 21 20:50:14 +0000 2006",
        "created_timestamp" => 1142974214,
        "likes" => 310826,
        "retweets" => 124658,
        "replies" => 18041,
        "author" => {
          "name" => "jack",
          "screen_name" => "jack",
          "avatar_url" => "https://pbs.twimg.com/profile_images/1/avatar_200x200.jpg"
        }
      }

      stub_request(:get, "https://api.fxtwitter.com/jack/status/140")
        .to_return(status: 200, body: { code: 200, message: "OK", tweet: tweet }.to_json,
          headers: { "Content-Type" => "application/json" })
    end
end
