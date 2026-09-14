json.cache! message do
  json.(message, :id)

  json.created_at message.created_at.utc

  json.body do
    json.plain_text message.plain_text_body
    json.html(message.markdown? ? markdown_message_presentation(message.body.body) : message.body.to_s)
    json.markdown_source message.markdown_source if message.markdown?
  end

  json.creator message.creator, partial: "users/user", as: :user

  json.room do
    json.id message.room_id
  end

  json.url room_message_url(message.room, message)
end
