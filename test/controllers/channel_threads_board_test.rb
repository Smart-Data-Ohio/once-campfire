require "test_helper"

class ChannelThreadsBoardTest < ActionDispatch::IntegrationTest
  setup do
    @room = Rooms::Board.create_for({ name: "Launch", creator: users(:david) },
      users: [ users(:david), users(:jz), users(:kevin) ])
    @creator = users(:jz)
    @post = ChannelThread.create!(room: @room, creator: @creator, name: "Ship it", work_status: "planned")
    ThreadMembership.join!(@post, @creator)
  end

  test "new post form renders in boards and 404s in channels and for non-members" do
    sign_in :jz
    get new_room_thread_url(@room)
    assert_response :success
    assert_select "form[action='#{room_threads_path(@room)}']"

    get new_room_thread_url(rooms(:designers))
    assert_response :not_found

    sign_in :jason
    assert_raises ActiveRecord::RecordNotFound do
      get new_room_thread_url(@room)
    end
  end

  test "creates a post with a first message, owner, status, and tags" do
    sign_in :jz

    assert_difference -> { ChannelThread.count }, 1 do
      assert_difference -> { Message.thread_messages.count }, 1 do
        post room_threads_url(@room), params: {
          thread: { name: "Launch checklist", work_status: "in_progress",
            work_owner_id: users(:kevin).id, tags: "Launch, api",
            first_message: "The brief for launch." }
        }
      end
    end

    post = ChannelThread.ordered.first
    assert_redirected_to room_thread_path(@room, post)
    assert_equal "Launch checklist", post.name
    assert_equal "in_progress", post.work_status
    assert_equal users(:kevin).id, post.work_owner_id
    assert_equal %w[ api launch ], post.tag_names
    assert_equal "The brief for launch.", post.messages.sole.plain_text_body
    assert_equal @creator.id, post.creator_id
  end

  test "creates a post without a first message and defaults to planned" do
    sign_in :jz

    assert_difference -> { ChannelThread.count }, 1 do
      assert_no_difference -> { Message.count } do
        post room_threads_url(@room, format: :json), params: {
          thread: { name: "Messageless post", first_message: "  " }
        }
      end
    end

    assert_response :created
    post = ChannelThread.find(response.parsed_body.dig("thread", "id"))
    assert_equal "planned", post.work_status
    assert_nil post.work_owner_id
    assert_empty post.messages
  end

  test "creates a post with an agent owner through the assignment path" do
    agent_user = User.create_bot!(name: "Board Worker")
    agent = agent_user.create_agent!(kind: :workspace, owner: users(:david))
    @room.memberships.grant_to(agent_user)
    AgentGrant.create!(agent: agent, room: @room, granted_by: users(:david), capability: "post_messages")

    sign_in :jz
    assert_difference -> { agent.agent_events.where(event_type: "work_assigned").count }, 1 do
      post room_threads_url(@room, format: :json), params: {
        thread: { name: "Agent post", work_owner_id: agent_user.id }
      }
    end

    assert_response :created
    post = ChannelThread.find(response.parsed_body.dig("thread", "id"))
    assert_equal agent_user.id, post.work_owner_id
    assert_equal "work_assignment", post.work_thread_events.ordered.first.event_type
  end

  test "rejects posts with invalid titles, owners, statuses, and tags" do
    sign_in :jz

    assert_no_difference -> { ChannelThread.count } do
      post room_threads_url(@room), params: { thread: { name: "", first_message: "No title" } }
    end
    assert_response :unprocessable_entity
    assert_match "Name can&#39;t be blank", response.body

    assert_no_difference -> { ChannelThread.count } do
      post room_threads_url(@room, format: :json), params: {
        thread: { name: "Bad owner", work_owner_id: users(:jason).id }
      }
    end
    assert_response :unprocessable_entity

    assert_no_difference -> { ChannelThread.count } do
      post room_threads_url(@room, format: :json), params: {
        thread: { name: "Bad status", work_status: "shipping" }
      }
    end
    assert_response :unprocessable_entity

    assert_no_difference -> { ChannelThread.count } do
      post room_threads_url(@room, format: :json), params: {
        thread: { name: "Bad tags", tags: "one, two, three, four, five, six" }
      }
    end
    assert_response :unprocessable_entity
  end

  test "non-members cannot create posts" do
    sign_in :jason

    assert_no_difference -> { ChannelThread.count } do
      assert_raises ActiveRecord::RecordNotFound do
        post room_threads_url(@room, format: :json), params: { thread: { name: "Intruder" } }
      end
    end
  end

  test "a new post notifies everything-followers and always the human owner" do
    @room.memberships.grant_to(users(:jason))
    @room.memberships.find_by!(user: users(:jason)).update!(involvement: "everything")
    @room.memberships.find_by!(user: users(:kevin)).update!(involvement: "nothing")

    sign_in :jz
    post room_threads_url(@room), params: {
      thread: { name: "Notified post", work_owner_id: users(:kevin).id, first_message: "Read me." }
    }

    post = ChannelThread.ordered.first
    assert_equal 1, ActivityItem.where(user: users(:jason), event_type: "thread_activity").count
    assert_equal post.messages.sole.id, ActivityItem.find_by!(user: users(:jason)).source_id
    assert_equal 1, ActivityItem.where(user: users(:kevin), event_type: "thread_activity").count
    assert_empty ActivityItem.where(user: @creator)
  end

  test "a messageless post creates no inbox items but marks the board unread" do
    sign_in :jz
    post room_threads_url(@room, format: :json), params: { thread: { name: "Quiet post" } }
    assert_response :created

    assert_empty ActivityItem.all
    assert @room.memberships.find_by!(user: users(:kevin)).unread?
    assert @room.memberships.find_by!(user: users(:david)).unread?
    assert_not @room.memberships.find_by!(user: @creator).unread?
  end

  test "post owner, creator, board creator, and admins can change the status" do
    @post.update!(work_owner_id: users(:kevin).id)

    { kevin: "in_progress", jz: "blocked", david: "done" }.each do |user, status|
      sign_in user
      patch room_thread_url(@room, @post, format: :json), params: { thread: { work_status: status } }
      assert_response :success
      assert_equal status, @post.reload.work_status
    end

    @post.update!(work_owner_id: users(:jz).id)
    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_status: "planned" } }
    assert_response :forbidden
    assert_equal "done", @post.reload.work_status
  end

  test "post creator, board creator, and admins can assign the owner" do
    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_owner_id: users(:kevin).id } }
    assert_response :success
    assert_equal users(:kevin).id, @post.reload.work_owner_id

    sign_in :david
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_owner_id: "" } }
    assert_response :success
    assert_nil @post.reload.work_owner_id

    @post.update!(work_owner_id: users(:kevin).id)
    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_owner_id: users(:jz).id } }
    assert_response :forbidden
    assert_equal users(:kevin).id, @post.reload.work_owner_id
  end

  test "the owning agent can change the status but cannot reassign" do
    agent = agents(:bender_agent)
    @room.memberships.grant_to(users(:bender))
    AgentGrant.create!(agent: agent, room: @room, granted_by: users(:david), capability: "post_messages")
    AgentGrant.create!(agent: agent, room: @room, granted_by: users(:david), capability: "manage_threads")
    @post.update_work!(actor: @creator, work_owner_id: users(:bender).id)
    headers = { "Authorization" => "Bearer bender-test-secret-1234", "Content-Type" => "application/json" }

    patch "/agents/work/#{@post.id}", headers: headers,
      params: { work_status: "in_progress", work_owner_id: users(:kevin).id }.to_json
    assert_response :success
    assert_equal "in_progress", @post.reload.work_status
    assert_equal users(:bender).id, @post.reload.work_owner_id
  end

  test "the owning agent without manage_threads cannot change the status" do
    agent = agents(:bender_agent)
    @room.memberships.grant_to(users(:bender))
    AgentGrant.create!(agent: agent, room: @room, granted_by: users(:david), capability: "post_messages")
    @post.update_work!(actor: @creator, work_owner_id: users(:bender).id)
    headers = { "Authorization" => "Bearer bender-test-secret-1234", "Content-Type" => "application/json" }

    patch "/agents/work/#{@post.id}", headers: headers, params: { work_status: "in_progress" }.to_json
    assert_response :forbidden
    assert_equal "planned", @post.reload.work_status
  end

  test "post owner can edit the title and tags like the status managers" do
    @post.update!(work_owner_id: users(:kevin).id)

    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { name: "Renamed", tags: "renamed, api" } }
    assert_response :success
    assert_equal "Renamed", @post.reload.name
    assert_equal %w[ api renamed ], @post.tag_names

    @post.update!(work_owner_id: users(:jz).id)
    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { name: "Hijacked", tags: "hijack" } }
    assert_response :forbidden
    assert_equal "Renamed", @post.reload.name

    patch room_thread_url(@room, @post, format: :json), params: { thread: { tags: "hijack" } }
    assert_response :forbidden
    assert_equal %w[ api renamed ], @post.reload.tag_names
  end

  test "result edits follow the status rule and write a result_updated event" do
    @post.update!(work_owner_id: users(:kevin).id)

    sign_in :kevin
    assert_difference -> { @post.work_thread_events.where(event_type: "result_updated").count }, 1 do
      patch room_thread_url(@room, @post), params: { thread: { result_markdown: "## Outcome" } }
    end
    assert_redirected_to room_thread_path(@room, @post)
    assert_equal "## Outcome", @post.reload.result_markdown

    get room_thread_url(@room, @post)
    assert_response :success
    assert_select ".board-post__result-body", text: /Outcome/
    assert_select ".board-post__history", text: /Kevin updated the result/

    @post.update!(work_owner_id: users(:jz).id)
    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { result_markdown: "Hijacked" } }
    assert_response :forbidden
    assert_equal "## Outcome", @post.reload.result_markdown
  end

  test "stopping work tracking is rejected for posts" do
    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_status: "", work_owner_id: "" } }
    assert_response :unprocessable_entity
    assert_equal "planned", @post.reload.work_status

    @post.update!(work_owner_id: users(:kevin).id)
    sign_in :kevin
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_status: "" } }
    assert_response :forbidden
    assert_equal "planned", @post.reload.work_status
  end

  test "auto-archive changes are rejected for posts" do
    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { auto_archive_after_minutes: 60 } }
    assert_response :unprocessable_entity
    assert_match "not available for board posts", response.parsed_body.fetch("error")
    assert_equal ChannelThread::DEFAULT_AUTO_ARCHIVE_AFTER_MINUTES, @post.reload.auto_archive_after_minutes
  end

  test "only the board creator and admins can close, lock, or delete a post" do
    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { status: "closed" } }
    assert_response :forbidden
    assert_predicate @post.reload, :active?

    sign_in :david
    patch room_thread_url(@room, @post, format: :json), params: { thread: { status: "closed" } }
    assert_response :success
    assert_predicate @post.reload, :closed?

    patch room_thread_url(@room, @post, format: :json), params: { thread: { status: "locked" } }
    assert_response :success
    assert_predicate @post.reload, :locked?

    sign_in :kevin
    delete room_thread_url(@room, @post, format: :json)
    assert_response :forbidden

    sign_in :david
    delete room_thread_url(@room, @post, format: :json)
    assert_response :no_content
    assert_not ChannelThread.exists?(@post.id)
  end

  test "members can reply in a post and join or leave it from the page" do
    sign_in :kevin
    post room_thread_messages_url(@room, @post, format: :json), params: {
      message: { markdown_source: "A member reply", client_message_id: "board-reply" }
    }
    assert_response :created
    assert_equal "A member reply", @post.messages.sole.plain_text_body

    post join_room_thread_url(@room, @post)
    assert_redirected_to room_thread_path(@room, @post)
    assert @post.memberships.exists?(user: users(:kevin))

    delete leave_room_thread_url(@room, @post)
    assert_redirected_to room_thread_path(@room, @post)
    assert_not @post.memberships.exists?(user: users(:kevin))

    sign_in :jason
    assert_raises ActiveRecord::RecordNotFound do
      post room_thread_messages_url(@room, @post, format: :json), params: {
        message: { markdown_source: "An intruder reply", client_message_id: "board-intruder" }
      }
    end
  end

  test "any member can link and unlink but non-members cannot" do
    sign_in :kevin
    post thread_work_links_url(@post), params: {
      kind: "drive_file", drive_url: "https://drive.google.com/file/d/board1234567"
    }
    assert_redirected_to room_thread_path(@room, @post)
    link = @post.reload.work_thread_links.sole
    assert_predicate link, :drive_file?
    assert_equal "https://drive.google.com/file/d/board1234567", link.url

    get room_thread_url(@room, @post)
    assert_response :success
    assert_match "drive.google.com", response.body

    delete thread_work_link_url(@post, link)
    assert_redirected_to room_thread_path(@room, @post)
    assert_empty @post.reload.work_thread_links

    sign_in :jason
    post thread_work_links_url(@post), params: {
      kind: "drive_file", drive_url: "https://drive.google.com/file/d/board4567890"
    }
    assert_response :not_found
    assert_empty @post.reload.work_thread_links
  end

  test "board page renders the list with rows, filters, and a new-post link" do
    @post.update!(work_owner_id: users(:kevin).id)
    @post.tag_names = "api, launch"
    @post.save!
    @post.post_message!(creator: @creator, attributes: { markdown_source: "First", client_message_id: "row-first" })
    done = ChannelThread.create!(room: @room, creator: @creator, name: "Finished", work_status: "done")
    ThreadMembership.join!(done, @creator)

    sign_in :jz
    get room_url(@room)
    assert_response :success
    assert_select "#board_posts .board-row", count: 1
    assert_select "##{ActionView::RecordIdentifier.dom_id(@post, :board_row)}", text: /Ship it/
    assert_select ".board-row__status", text: "Planned"
    assert_select ".board-row__owner", text: /Kevin/
    assert_select ".board-tag", text: "api"
    assert_select ".board-row__meta", text: /1 reply/
    assert_select "a[href='#{new_room_thread_path(@room)}']", text: "New post"

    get room_url(@room, status: "done")
    assert_select "#board_posts .board-row", count: 1
    assert_select "##{ActionView::RecordIdentifier.dom_id(done, :board_row)}"

    get room_url(@room, status: "all", owner: "me")
    assert_select "#board_posts .board-row", count: 0

    get room_url(@room, status: "all", owner: users(:kevin).id)
    assert_select "#board_posts .board-row", count: 1

    get room_url(@room, status: "all", tag: "launch")
    assert_select "#board_posts .board-row", count: 1

    get room_url(@room, status: "all", tag: "missing")
    assert_select "#board_posts .board-row", count: 0
  end

  test "board rendering groups posts into read-only status columns" do
    @post.update!(work_status: "in_progress")
    done = ChannelThread.create!(room: @room, creator: @creator, name: "Finished", work_status: "done")
    ThreadMembership.join!(done, @creator)

    sign_in :jz
    get room_url(@room, view: "board")
    assert_response :success
    assert_select ".board__column", count: 4
    assert_select ".board__column[aria-label='In progress'] ##{ActionView::RecordIdentifier.dom_id(@post, :board_row)}"
    assert_select ".board__column[aria-label='Done'] ##{ActionView::RecordIdentifier.dom_id(done, :board_row)}"
    assert_select ".board__column[aria-label='Planned'] .board-row", count: 0
    assert_select "form.board__filters select[name='status']", count: 0

    get room_url(@room, view: "board", status: "done")
    assert_select ".board__column[aria-label='In progress'] .board-row", count: 1
  end

  test "post page shows the board header, result, and manage controls without tracking controls" do
    @post.update!(result_markdown: "## Outcome", result_updated_at: Time.current, result_updated_by_id: @creator.id)
    @post.update!(run_url: "https://example.test/runs/1")

    sign_in :david
    get room_thread_url(@room, @post)
    assert_response :success
    assert_select ".board-post__header h1", text: "Ship it"
    assert_select ".board-post__work", text: /Planned/
    assert_select ".board-post__result-body", text: /Outcome/
    assert_select ".board-post__run a[href='https://example.test/runs/1'][rel='noopener noreferrer']", text: "Run"
    assert_select ".board-post__manage"
    assert_no_match "Stop tracking work", response.body
    assert_no_match "Auto-close after", response.body
  end

  test "a status change replaces the post row over the room stream" do
    @post.update!(work_owner_id: users(:kevin).id)

    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { work_status: "in_progress" } }
    assert_response :success

    assert_rendered_turbo_stream_broadcast @room, :messages, action: "replace", target: [ @post, :board_row ] do
      assert_select ".board-row__status", text: "In progress"
    end
  end

  test "a new post prepends into the board list" do
    sign_in :jz
    post room_threads_url(@room, format: :json), params: { thread: { name: "Prepended post" } }
    assert_response :created

    post = ChannelThread.find(response.parsed_body.dig("thread", "id"))
    streams = capture_turbo_stream_broadcasts([ @room, :messages ])
    prepend = streams.find do |stream|
      stream["action"] == "prepend" && stream.to_html.include?(ActionView::RecordIdentifier.dom_id(post, :board_row))
    end
    assert_equal "board_posts", prepend["target"]
    assert_match "Prepended post", prepend.to_html
  end

  test "a tag change replaces the post row over the room stream" do
    sign_in :jz
    patch room_thread_url(@room, @post, format: :json), params: { thread: { tags: "shiny" } }
    assert_response :success

    assert_rendered_turbo_stream_broadcast @room, :messages, action: "replace", target: [ @post, :board_row ] do
      assert_select ".board-tag", text: "shiny"
    end
  end

  test "bot posting API returns 422 in a board" do
    @room.memberships.grant_to(users(:bender))

    post room_bot_messages_url(@room, users(:bender).bot_key), params: +"Board root message"
    assert_response :unprocessable_entity
    assert_empty @room.root_messages

    post room_bot_messages_url(rooms(:watercooler), users(:bender).bot_key), params: +"Channel root message"
    assert_response :created
  end
end
