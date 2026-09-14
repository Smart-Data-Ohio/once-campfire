json.name h(user.name)
json.markdown_display_name user.name
json.value      user.id
json.avatar_url fresh_user_avatar_url(user)
json.sgid       user.attachable_sgid
json.mention_token Message::Markdown.mention_token(user.name) if @unique_markdown_mention_names&.include?(user.name)
