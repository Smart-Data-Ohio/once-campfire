require "test_helper"

class MessageConversationsTest < ActiveSupport::TestCase
  test "deleting a replied-to message leaves a body-less tombstone" do
    room = rooms(:designers)
    source = room.root_messages.create!(creator: users(:jason), markdown_source: "Original body", client_message_id: "reply-source")
    reply = room.root_messages.create!(creator: users(:jz), markdown_source: "Reply body", reply_to_message: source, client_message_id: "reply-child")

    source.destroy!

    reply.reload
    assert reply.reply?
    assert_nil reply.reply_to_message_id
    assert_nil reply.reply_to_message
    assert reply.reply_target_deleted_at.present?
    assert_equal "Reply body", reply.plain_text_body
  end

  test "replies must remain in their root stream or thread, except a thread starter" do
    room = rooms(:designers)
    starter = room.root_messages.create!(creator: users(:jason), markdown_source: "Starter", client_message_id: "starter")
    other_root = room.root_messages.create!(creator: users(:jason), markdown_source: "Elsewhere", client_message_id: "other-root")
    thread = ChannelThread.create!(room:, creator: users(:jz), parent_message: starter, name: "Discussion")
    ThreadMembership.join!(thread, users(:jz))

    reply_to_starter = Message.new(room:, thread:, creator: users(:jz), markdown_source: "Allowed", reply_to_message: starter, client_message_id: "thread-starter-reply")
    assert_predicate reply_to_starter, :valid?

    reply_to_other_root = Message.new(room:, thread:, creator: users(:jz), markdown_source: "Rejected", reply_to_message: other_root, client_message_id: "thread-other-root-reply")
    assert_not_predicate reply_to_other_root, :valid?
    assert_includes reply_to_other_root.errors[:reply_to_message], "must be in the same conversation"
  end

  test "legacy Action Text has editable Markdown and keeps opaque attachments when saved" do
    room = rooms(:designers)
    legacy = room.root_messages.create!(
      creator: users(:jz),
      body: %(<div><strong>Bold</strong> <a href="https://example.test">link</a></div><div>#{mention_attachment_for(:david)}</div><action-text-attachment content-type="application/vnd.actiontext.opengraph-embed" url="https://example.test/card" filename="Example"></action-text-attachment>),
      client_message_id: "legacy-source"
    )

    source = legacy.editable_markdown_source
    assert_includes source, "**Bold**"
    assert_includes source, "[link](<https://example.test>)"
    assert_includes source, "@[David]"

    legacy.preserve_legacy_attachments_on_next_markdown_render!
    legacy.update!(markdown_source: "**Changed** @[David]")

    assert legacy.markdown?
    assert_includes legacy.body.body.to_html, "application/vnd.actiontext.opengraph-embed"
    assert_includes legacy.body.body.to_html, users(:david).attachable_sgid
  end

  test "legacy Markdown round trips literal punctuation, code fences, and link destinations" do
    room = rooms(:designers)
    literal = "literal * _ [brackets] \\"
    inline_code = "inline ` code"
    fenced_code = "before\n``` inside"
    href = "https://example.test/a_(b)"
    legacy = room.root_messages.create!(
      creator: users(:jz),
      body: <<~HTML,
        <p>#{literal}</p>
        <p><code>#{inline_code}</code></p>
        <pre><code>#{fenced_code}</code></pre>
        <p><a href="#{href}">A link</a></p>
      HTML
      client_message_id: "legacy-literal-round-trip"
    )

    source = legacy.editable_markdown_source
    assert_includes source, "literal \\* \\_ \\[brackets\\] \\\\"
    assert_includes source, "``inline ` code``"
    assert_includes source, "````\nbefore\n``` inside\n````"
    assert_includes source, "[A link](<https://example.test/a_(b)>)"

    legacy.update!(markdown_source: source)

    assert_includes legacy.plain_text_body, literal
    assert_includes legacy.plain_text_body, inline_code
    assert_includes legacy.plain_text_body, fenced_code
    assert_includes legacy.body.body.to_html, "href=\"#{href}\""
  end

  test "thread push notification opens the parent room at the thread message" do
    room = rooms(:designers)
    thread = ChannelThread.create!(room:, creator: users(:jz), name: "Push target")
    ThreadMembership.join!(thread, users(:jz))
    ThreadMembership.join!(thread, users(:jason)).update!(involvement: "everything")
    ThreadMembership.join!(thread, users(:kevin)).update!(involvement: "everything")
    memberships(:kevin_designers).update!(involvement: "invisible")
    message = thread.post_message!(creator: users(:jz), attributes: { markdown_source: "Open here", client_message_id: "thread-push-target" })

    Rails.configuration.x.web_push_pool.expects(:queue).once.with do |payload, subscriptions|
      assert_equal Rails.application.routes.url_helpers.room_path(room, thread: thread.id, message_id: message.id), payload[:path]
      assert_equal [ users(:jason).id ], subscriptions.order(:id).pluck(:user_id)
      true
    end

    ChannelThread::MessagePusher.new(thread:, message:).push
  end
end
