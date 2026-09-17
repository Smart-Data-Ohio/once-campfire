require "test_helper"

class Github::AgentPullRequestActionTest < ActiveSupport::TestCase
  setup do
    @pull_request = Github::PullRequest.for_reference(owner: "rails", repo: "rails", number: 12)
  end

  test "comment requires a body" do
    action = Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "comment", body: "  ")

    assert_not action.valid?
    assert_equal [ "is required for a comment" ], action.errors[:body]
  end

  test "request_changes requires a body" do
    action = Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "request_changes", body: nil)

    assert_not action.valid?
    assert_equal [ "is required when requesting changes" ], action.errors[:body]
  end

  test "approve accepts a missing body" do
    action = Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "approve", body: nil)

    assert action.valid?, action.errors.full_messages.to_sentence
  end

  test "request_review requires 1 to 15 valid logins" do
    blank = Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "request_review", reviewers: "  ")
    assert_not blank.valid?
    assert_equal [ Github::ReviewLogins::INVALID_MESSAGE ], blank.errors[:reviewers]

    invalid = Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "request_review", reviewers: "alice, bob!!")
    assert_not invalid.valid?
    assert_equal [ Github::ReviewLogins::INVALID_MESSAGE ], invalid.errors[:reviewers]

    too_many = Github::AgentPullRequestAction.new(
      pull_request: @pull_request, kind: "request_review",
      reviewers: (1..16).map { |index| "user#{index}" }.join(", ")
    )
    assert_not too_many.valid?
    assert_equal [ Github::ReviewLogins::INVALID_MESSAGE ], too_many.errors[:reviewers]
  end

  test "request_review normalises logins like the human endpoint" do
    action = Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "request_review", reviewers: " @Alice, alice  @BOB ")

    assert action.valid?, action.errors.full_messages.to_sentence
    assert_equal %w[ alice bob ], action.normalized_reviewers
  end

  test "unknown kinds are rejected" do
    action = Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "merge", body: "x")

    assert_not action.valid?
    assert_equal [ "must be one of: comment, approve, request_changes, request_review" ], action.errors[:kind]
  end

  test "oversized bodies are rejected before the approval payload limit" do
    action = Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "comment", body: "x" * 3501)

    assert_not action.valid?
    assert_equal [ "is too long (maximum is 3500 characters)" ], action.errors[:body]
  end

  test "summaries name the action and the pull request" do
    assert_equal "Approve rails/rails#12",
      Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "approve").summary
    assert_equal "Request changes on rails/rails#12",
      Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "request_changes", body: "Fix it").summary
    assert_equal "Comment on rails/rails#12: Nice work",
      Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "comment", body: "Nice work").summary
    assert_equal "Comment on rails/rails#12: #{"x" * 120}",
      Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "comment", body: "  #{"x" * 200}  ").summary
    assert_equal "Request review on rails/rails#12 from @alice, @bob",
      Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "request_review", reviewers: "alice, bob").summary
  end

  test "payload carries pull_request_id, kind, body, and reviewers" do
    action = Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "request_review", reviewers: " @Alice ")

    assert_equal(
      { "pull_request_id" => @pull_request.id, "kind" => "request_review", "body" => nil, "reviewers" => %w[ alice ] },
      action.payload_hash
    )
    assert_equal action.payload_hash, JSON.parse(action.payload_json)

    comment = Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "comment", body: "  Nice  ", reviewers: "alice")
    assert_equal(
      { "pull_request_id" => @pull_request.id, "kind" => "comment", "body" => "Nice", "reviewers" => nil },
      comment.payload_hash
    )
  end

  test "from_payload rebuilds a valid action" do
    payload = { "pull_request_id" => @pull_request.id, "kind" => "comment", "body" => "Nice", "reviewers" => nil }

    action = Github::AgentPullRequestAction.from_payload(pull_request: @pull_request, payload: payload)

    assert action.valid?, action.errors.full_messages.to_sentence
    assert_equal "comment", action.kind
    assert_equal "Nice", action.normalized_body
  end

  test "perform calls the same client methods as the human controllers" do
    client = mock("write client")
    client.expects(:create_issue_comment).with(@pull_request, body: "Nice")
      .returns("html_url" => "https://github.com/rails/rails/pull/12#issuecomment-1")

    response = Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "comment", body: "Nice").perform(client)

    assert_equal "https://github.com/rails/rails/pull/12#issuecomment-1", response["html_url"]

    review_client = mock("write client")
    review_client.expects(:create_review).with(@pull_request, event: "APPROVE", body: nil).returns({})
    Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "approve").perform(review_client)

    changes_client = mock("write client")
    changes_client.expects(:create_review).with(@pull_request, event: "REQUEST_CHANGES", body: "Fix it").returns({})
    Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "request_changes", body: "Fix it").perform(changes_client)

    reviewers_client = mock("write client")
    reviewers_client.expects(:request_reviewers).with(@pull_request, logins: %w[ alice ]).returns({})
    Github::AgentPullRequestAction.new(pull_request: @pull_request, kind: "request_review", reviewers: "alice").perform(reviewers_client)
  end
end
