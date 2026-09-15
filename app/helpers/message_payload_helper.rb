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

  def thread_payload(thread)
    return if thread.blank?

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

    def thread_permissions_payload(thread)
      membership = Current.user && thread.membership_for(Current.user)
      settings = thread.settings_manageable_by?(Current.user)
      lifecycle = thread.lifecycle_manageable_by?(Current.user)

      {
        can_rename: settings,
        can_close: settings,
        can_reopen: thread.locked? ? lifecycle : membership.present?,
        can_lock: lifecycle,
        can_unlock: lifecycle,
        can_delete: lifecycle
      }
    end

    def reaction_payload(message)
      counts = message.boosts.group(:content).distinct.count(:booster_id)
      active = message.boosts.where(booster: Current.user).pluck(:content).to_set

      EmojiHelper::REACTIONS.to_h do |character, title|
        [ character, { title:, count: counts.fetch(character, 0), active: active.include?(character) } ]
      end
    end
end
