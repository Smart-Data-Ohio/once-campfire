require "test_helper"

class Github::WebhooksControllerTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  setup do
    @original_secret = ENV["GITHUB_WEBHOOK_SECRET"]
    ENV["GITHUB_WEBHOOK_SECRET"] = "webhook-secret"
    @original_token = ENV["GITHUB_TOKEN"]
    ENV["GITHUB_TOKEN"] = "test-token"

    @room = rooms(:designers)
    @message = @room.messages.create!(
      creator: users(:david),
      markdown_source: "review https://github.com/rails/rails/pull/123",
      client_message_id: "webhook-ref-1"
    )
    @pull_request = @message.github_pull_requests.first
  end

  teardown do
    ENV["GITHUB_WEBHOOK_SECRET"] = @original_secret
    ENV["GITHUB_TOKEN"] = @original_token
  end

  test "valid pull_request signature updates the record and broadcasts once" do
    stub_github_api
    clear_enqueued_jobs # setup's reference sync enqueued a fetch; only the webhook's should run

    stream = room_messages_stream_name(@room)

    assert_broadcasts stream, 1 do
      perform_enqueued_jobs do
        post github_webhooks_url, params: pull_request_payload.to_json, headers: webhook_headers(event: "pull_request", body: pull_request_payload.to_json)
      end
    end

    assert_response :success
    assert_equal "Add shiny things", @pull_request.reload.title
  end

  test "response carries no card content" do
    post github_webhooks_url, params: pull_request_payload.to_json, headers: webhook_headers(event: "pull_request", body: pull_request_payload.to_json)

    assert_response :success
    assert_empty response.body
  end

  test "bad signature is rejected without enqueueing" do
    assert_no_enqueued_jobs only: Github::FetchPullRequestJob do
      post github_webhooks_url, params: pull_request_payload.to_json,
        headers: webhook_headers(event: "pull_request", body: "tampered").merge("X-Hub-Signature-256" => "sha256=deadbeef")
    end

    assert_response :unauthorized
  end

  test "missing signature is rejected" do
    post github_webhooks_url, params: pull_request_payload.to_json,
      headers: { "X-GitHub-Event" => "pull_request", "X-GitHub-Delivery" => SecureRandom.uuid, "Content-Type" => "application/json" }

    assert_response :unauthorized
  end

  test "missing secret answers unavailable" do
    ENV["GITHUB_WEBHOOK_SECRET"] = nil

    post github_webhooks_url, params: pull_request_payload.to_json, headers: webhook_headers(event: "pull_request", body: pull_request_payload.to_json)

    assert_response :service_unavailable
  end

  test "redelivered events are ignored" do
    body = pull_request_payload.to_json
    headers = webhook_headers(event: "pull_request", body: body)

    assert_enqueued_jobs 1, only: Github::FetchPullRequestJob do
      post github_webhooks_url, params: body, headers: headers
      assert_response :success
    end

    assert_no_enqueued_jobs only: Github::FetchPullRequestJob do
      post github_webhooks_url, params: body, headers: headers
      assert_response :success
    end
  end

  test "events for unreferenced PRs are ignored" do
    body = pull_request_payload(number: 999).to_json

    assert_no_enqueued_jobs only: Github::FetchPullRequestJob do
      post github_webhooks_url, params: body, headers: webhook_headers(event: "pull_request", body: body)
      assert_response :success
    end

    assert_nil Github::PullRequest.find_by(number: 999)
  end

  test "unhandled event types are acknowledged and ignored" do
    assert_no_enqueued_jobs only: Github::FetchPullRequestJob do
      post github_webhooks_url, params: {}.to_json, headers: webhook_headers(event: "ping", body: {}.to_json)
      assert_response :success
    end
  end

  test "pull_request_review, check_run, check_suite, and status events enqueue a refresh" do
    @pull_request.update!(head_branch: "shiny")

    {
      "pull_request_review" => pull_request_payload,
      "check_run" => check_payload("check_run"),
      "check_suite" => check_payload("check_suite"),
      "status" => status_payload
    }.each do |event, payload|
      body = payload.to_json

      assert_enqueued_jobs 1, only: Github::FetchPullRequestJob do
        post github_webhooks_url, params: body, headers: webhook_headers(event: event, body: body)
        assert_response :success
      end
    end
  end

  test "check events without PR links and status events for other branches are ignored" do
    @pull_request.update!(head_branch: "shiny")

    assert_no_enqueued_jobs only: Github::FetchPullRequestJob do
      body = { "repository" => { "full_name" => "rails/rails" }, "check_run" => { "pull_requests" => [] } }.to_json
      post github_webhooks_url, params: body, headers: webhook_headers(event: "check_run", body: body)
      assert_response :success

      body = { "repository" => { "full_name" => "rails/rails" }, "branches" => [ { "name" => "other" } ] }.to_json
      post github_webhooks_url, params: body, headers: webhook_headers(event: "status", body: body)
      assert_response :success
    end
  end

  private
    def webhook_headers(event:, body:)
      {
        "X-GitHub-Event" => event,
        "X-GitHub-Delivery" => SecureRandom.uuid,
        "X-Hub-Signature-256" => "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", body)}",
        "Content-Type" => "application/json"
      }
    end

    def pull_request_payload(number: 123)
      {
        "repository" => { "full_name" => "rails/rails" },
        "pull_request" => {
          "number" => number,
          "base" => { "repo" => { "full_name" => "rails/rails" } }
        }
      }
    end

    def check_payload(key)
      {
        "repository" => { "full_name" => "rails/rails" },
        key => { "pull_requests" => [ { "number" => 123 } ] }
      }
    end

    def status_payload
      {
        "repository" => { "full_name" => "rails/rails" },
        "branches" => [ { "name" => "shiny" } ]
      }
    end

    def stub_github_api
      WebMock.stub_request(:get, "https://api.github.com/repos/rails/rails/pulls/123")
        .to_return(status: 200, body: {
          "number" => 123, "title" => "Add shiny things", "state" => "open", "draft" => false,
          "merged_at" => nil, "html_url" => "https://github.com/rails/rails/pull/123",
          "updated_at" => "2026-09-15T12:00:00Z",
          "user" => { "login" => "dhh", "avatar_url" => "https://avatars.example/dhh" },
          "base" => { "ref" => "main" }, "head" => { "ref" => "shiny", "sha" => "abc123" }
        }.to_json, headers: { "Content-Type" => "application/json" })
      WebMock.stub_request(:get, "https://api.github.com/repos/rails/rails/pulls/123/reviews?per_page=100")
        .to_return(status: 200, body: [].to_json)
      WebMock.stub_request(:get, "https://api.github.com/repos/rails/rails/commits/abc123/check-runs?per_page=100")
        .to_return(status: 200, body: { "check_runs" => [] }.to_json)
      WebMock.stub_request(:get, "https://api.github.com/repos/rails/rails/commits/abc123/status")
        .to_return(status: 200, body: { "state" => "success" }.to_json)
    end

    def room_messages_stream_name(room)
      signed = Turbo::StreamsChannel.signed_stream_name([ room, :messages ])
      Turbo::StreamsChannel.verified_stream_name(signed)
    end
end
