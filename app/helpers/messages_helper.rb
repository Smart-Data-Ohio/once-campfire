module MessagesHelper
  def message_area_tag(room, thread: nil, anchor_message_id: nil, &)
    area_id = thread ? dom_id(thread, :message_area) : "message-area"
    controller = thread ? "messages drop-target" : "messages presence drop-target"
    actions = [ messages_actions, drop_target_actions ]
    actions << presence_actions unless thread

    tag.div id: area_id, class: "message-area", contents: true, data: {
      controller: controller,
      action: actions.join(" "),
      messages_first_of_day_class: "message--first-of-day",
      messages_formatted_class: "message--formatted",
      messages_me_class: "message--me",
      messages_mentioned_class: "message--mentioned",
      messages_threaded_class: "message--threaded",
      messages_page_url_value: thread ? room_thread_messages_url(room, thread) : room_messages_url(room),
      messages_anchor_message_id_value: anchor_message_id
    }, &
  end

  def messages_tag(room, thread: nil, anchor_message_id: nil, &)
    messages_id = thread ? dom_id(thread, :messages) : dom_id(room, :messages)
    controller = thread ? "maintain-scroll" : "maintain-scroll refresh-room"
    actions = [ maintain_scroll_actions ]
    actions << refresh_room_actions unless thread

    tag.div id: messages_id, class: "messages", data: {
      controller: controller,
      action: actions.join(" "),
      messages_target: "messages",
      messages_anchor_message_id_value: (anchor_message_id if thread),
      refresh_room_loaded_at_value: room.updated_at.to_fs(:epoch),
      refresh_room_url_value: (room_refresh_url(room) unless thread)
    }, &
  end

  def message_tag(message, &)
    message_timestamp_milliseconds = message.created_at.to_fs(:epoch)

    tag.div id: dom_id(message),
      class: "message #{"message--emoji" if message.plain_text_body.all_emoji?}",
      data: {
        controller: "reply",
        user_id: message.creator_id,
        message_id: message.id,
        room_id: message.room_id,
        thread_id: message.thread_id,
        message_timestamp: message_timestamp_milliseconds,
        message_updated_at: message.updated_at.to_fs(:epoch),
        sort_value: message_timestamp_milliseconds,
        messages_target: "message",
        search_results_target: "message",
        refresh_room_target: ("message" unless message.thread_message?),
        reply_composer_outlet: message.thread_message? ? "##{dom_id(message.thread, :composer)}" : "#composer"
      }, &
  rescue Exception => e
    Sentry.capture_exception(e, extra: { message: message })
    Rails.logger.error "Exception while rendering message #{message.class.name}##{message.id}, failed with: #{e.class} `#{e.message}`"

    render "messages/unrenderable"
  end

  # The REST endpoint is used for edits/deletes, while the room permalink
  # keeps a normal channel message anchored in its conversation.
  def message_action_url(message)
    if message.thread_message?
      room_thread_message_url(message.room, message.thread, message)
    else
      room_message_url(message.room, message)
    end
  end

  def message_link_url(message)
    if message.thread_message?
      room_url(message.room, thread: message.thread_id, message_id: message.id)
    else
      room_at_message_url(message.room, message)
    end
  end

  def message_timestamp(message, **attributes)
    local_datetime_tag message.created_at, **attributes
  end

  def message_presentation(message)
    case message.content_type
    when "attachment"
      message_attachment_presentation(message)
    when "sound"
      message_sound_presentation(message)
    else
      if message.markdown?
        markdown_message_presentation(message.body.body)
      else
        auto_link h(ContentFilters::TextMessagePresentationFilters.apply(message.body.body)), html: { target: "_blank" }
      end
    end
  rescue Exception => e
    Sentry.capture_exception(e, extra: { message: message })
    Rails.logger.error "Exception while generating message representation for #{message.class.name}##{message.id}, failed with: #{e.class} `#{e.message}`"

    ""
  end

  def markdown_message_presentation(content)
    rendered = content.render_attachments do |attachment|
      attachment.node.tap do |node|
        if attachment.attachable.is_a?(User)
          node.inner_html = render partial: "users/mention", formats: :html, locals: { user: attachment.attachable }
        end
      end
    end
    tag.div Message::Markdown.sanitize_presentation(rendered.to_html).html_safe, class: "markdown-body"
  end

  private
    def messages_actions
      "turbo:before-stream-render@document->messages#beforeStreamRender keydown.up@document->messages#editMyLastMessage"
    end

    def maintain_scroll_actions
      "turbo:before-stream-render@document->maintain-scroll#beforeStreamRender"
    end

    def refresh_room_actions
      "visibilitychange@document->refresh-room#visibilityChanged online@window->refresh-room#online"
    end

    def presence_actions
      "visibilitychange@document->presence#visibilityChanged"
    end

    def message_attachment_presentation(message)
      Messages::AttachmentPresentation.new(message, context: self).render
    end

    def message_sound_presentation(message)
      sound = message.sound

      tag.div class: "sound", data: { controller: "sound", action: "messages:play->sound#play", sound_url_value: asset_path(sound.asset_path) } do
        play_button + (sound.image ? sound_image_tag(sound.image) : sound.text)
      end
    end

    def play_button
      tag.button "🔊", class: "btn btn--plain", data: { action: "sound#play" }
    end

    def sound_image_tag(image)
      image_tag image.asset_path, width: image.width, height: image.height, class: "align--middle"
    end

    def message_author_title(author)
      [ author.name, author.bio ].compact_blank.join(" – ")
    end
end
