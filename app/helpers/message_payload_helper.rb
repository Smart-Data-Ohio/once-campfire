module MessagePayloadHelper
  # JSON for a message is deliberately assembled here instead of relying on a
  # model's as_json. A reply and a forward contain links whose visibility is
  # specific to the requesting member, so a shared fragment cache must not be
  # allowed to decide whether those links are present.
  def message_payload(message, include_thread_summary: true)
    return if message.blank?

    {
      id: message.id,
      client_message_id: message.client_message_id,
      created_at: message.created_at&.utc,
      updated_at: message.updated_at&.utc,
      body: {
        plain_text: message.plain_text_body,
        html: message_html(message),
        markdown_source: message.markdown_source
      }.compact,
      creator: user_payload(message.creator),
      room: { id: message.room_id },
      thread_context: message.thread_message? ? thread_payload(message.thread) : nil,
      thread_summary: include_thread_summary ? thread_summary_payload(message) : nil,
      reply_to: reply_payload(message),
      forwarded: forwarded_payload(message),
      url: message_permalink_url(message)
    }.compact
  end

  # Reuse thread payloads for the duration of the block. Building one costs
  # several queries (membership lookup, message count, member count, and the
  # permission checks), and a list of messages from a single thread repeats all
  # of it per message. Opt-in rather than automatic so that an action which
  # mutates a thread and then re-renders it cannot serve a stale payload.
  def caching_thread_payloads
    previous, @thread_payload_cache = @thread_payload_cache, {}
    yield
  ensure
    @thread_payload_cache = previous
  end

  def thread_payload(thread, include_work_history: false, include_work_owner_options: false)
    return if thread.blank?

    if @thread_payload_cache
      @thread_payload_cache[[ thread.id, include_work_history, include_work_owner_options ]] ||=
        build_thread_payload(thread, include_work_history:, include_work_owner_options:)
    else
      build_thread_payload(thread, include_work_history:, include_work_owner_options:)
    end
  end

  def message_permalink_url(message)
    if message.thread_message?
      room_url(message.room, thread: message.thread_id, message_id: message.id)
    else
      room_at_message_url(message.room, message)
    end
  end

  def message_actions_payload(message)
    {
      can_edit: Current.user == message.creator && !(message.thread_message? && message.thread.locked?),
      can_delete: Current.user == message.creator || Current.user.administrator?,
      edit_source: message.editable_markdown_source,
      edit_format: message.markdown? ? "markdown" : "rich_text",
      copy_text: message.plain_text_body,
      thread_url: message.channel_thread && room_thread_url(message.room, message.channel_thread),
      thread_summary: message.channel_thread && thread_payload(message.channel_thread),
      forward_url: if message.thread_message?
        room_thread_message_forwards_url(message.room, message.thread, message, format: :json)
                   else
        room_message_forwards_url(message.room, message, format: :json)
                   end,
      forward_destinations_url: if message.thread_message?
        room_thread_message_forward_destinations_url(message.room, message.thread, message, format: :json)
                                else
        room_message_forward_destinations_url(message.room, message, format: :json)
                                end,
      reactions: reaction_payload(message)
    }.compact
  end

  private
    def message_html(message)
      renderer = respond_to?(:view_context) ? view_context : self

      if message.markdown?
        renderer.markdown_message_presentation(message.body.body).to_s
      else
        message.body.to_s
      end
    end

    def user_payload(user)
      return if user.blank?

      {
        id: user.id,
        name: user.name,
        role: user.role,
        avatar_url: fresh_user_avatar_url(user)
      }
    end

    def work_owner_payload(owner)
      return if owner.blank?

      user_payload(owner).merge(active: owner.active?, human: !owner.bot?, agent: owner.bot?)
    end

    def work_agent_owner_payload(user, agent)
      work_owner_payload(user).merge(provider: agent.provider, description: agent.description).compact
    end

    def work_owner_options(thread)
      memberships = thread.room.memberships.includes(:user).to_a
      agents_by_user_id = Agent.where(user_id: memberships.map(&:user_id)).index_by(&:user_id)
      humans = []
      agents = []

      memberships.each do |membership|
        user = membership.user
        next unless user&.active?

        if user.bot?
          agent = agents_by_user_id[user.id]
          next unless agent&.active? && agent.can?(:post_messages, thread.room)

          agents << work_agent_owner_payload(user, agent)
        else
          humans << work_owner_payload(user)
        end
      end

      humans.sort_by! { |owner| owner[:name].to_s.downcase }
      agents.sort_by! { |owner| owner[:name].to_s.downcase }
      humans + agents
    end

    def work_thread_event_payloads(thread)
      thread.work_thread_events.ordered.includes(:actor).map do |event|
        {
          id: event.id,
          event_type: event.event_type,
          created_at: event.created_at&.utc,
          actor: user_payload(event.actor),
          before: event.before_state,
          after: event.after_state,
          note: event.note
        }.compact
      end
    end

    def compact_message_payload(message)
      return if message.blank?

      {
        id: message.id,
        url: message_permalink_url(message),
        deleted: false,
        creator: user_payload(message.creator),
        body: {
          plain_text: message.plain_text_body,
          html: message_html(message)
        }
      }
    end

    def reply_payload(message)
      source = message.reply_to_message
      return unless source.present? || message.reply_target_deleted_at.present?

      compact_message_payload(source).to_h.merge(
        deleted: source.blank?,
        notify_author: message.reply_notify_author?
      )
    end

    def forwarded_payload(message)
      return unless message.forwarded?

      {
        label: "Forwarded",
        note: message.forward_note
      }.compact
    end

    def thread_summary_payload(message)
      thread = message.channel_thread
      thread.present? ? thread_payload(thread) : nil
    end

    def build_thread_payload(thread, include_work_history: false, include_work_owner_options: false)
      membership = Current.user && thread.membership_for(Current.user)
      # Explicit nulls tell an open panel to clear a deleted starter or old state.
      {
        id: thread.id,
        name: thread.name,
        status: thread.status,
        room_id: thread.room_id,
        parent_message_id: thread.parent_message_id,
        last_activity_at: thread.last_activity_at&.utc,
        closed_at: thread.closed_at&.utc,
        locked_at: thread.locked_at&.utc,
        auto_archive_after_minutes: thread.auto_archive_after_minutes,
        work: thread.work?,
        work_status: thread.work_status,
        work_owner_id: thread.work_owner_id,
        work_owner: work_owner_payload(thread.work_owner),
        work_owner_active: thread.work_owner_active?,
        work_history: include_work_history ? work_thread_event_payloads(thread) : nil,
        work_owner_options: include_work_owner_options ? work_owner_options(thread) : nil,
        joined: membership.present?,
        unread: membership&.unread?,
        involvement: membership&.involvement,
        message_count: thread.messages.count,
        member_count: thread.memberships.count,
        creator: user_payload(thread.creator),
        # `url` is the JSON/thread API endpoint consumed by the panel. Human
        # permalinks use `permalink_url`, which opens the parent room and its
        # normal composer instead of the standalone nested-message page.
        url: room_thread_url(thread.room, thread),
        permalink_url: room_url(thread.room, thread: thread.id),
        permissions: thread_permissions_payload(thread)
      }
    end

    def thread_permissions_payload(thread)
      membership = Current.user && thread.membership_for(Current.user)
      settings = thread.settings_manageable_by?(Current.user)
      lifecycle = thread.lifecycle_manageable_by?(Current.user)
      work_manageable = thread.work_manageable_by?(Current.user)
      work_assignment = thread.work_assignment_manageable_by?(Current.user)

      {
        can_rename: settings,
        can_close: settings,
        can_reopen: thread.locked? ? lifecycle : membership.present?,
        can_lock: lifecycle,
        can_unlock: lifecycle,
        can_delete: lifecycle,
        can_convert_work: !thread.work? && thread.work_conversion_manageable_by?(Current.user),
        can_manage_work: thread.work? && work_manageable,
        can_update_work_status: thread.work? && thread.work_status_manageable_by?(Current.user),
        can_assign_work: thread.work? && work_assignment,
        can_remove_work: thread.work? && work_assignment
      }
    end

    # Reads the boosts association in memory. A GROUP BY plus a pluck meant two
    # round trips even when the rows were already loaded.
    def reaction_payload(message)
      by_content = message.boosts.group_by(&:content)
      current_user_id = Current.user&.id

      EmojiHelper::REACTIONS.to_h do |character, title|
        boosts = by_content[character] || []
        [ character, {
          title:,
          count: boosts.map(&:booster_id).compact.uniq.size,
          active: boosts.any? { |boost| boost.booster_id == current_user_id }
        } ]
      end
    end
end
