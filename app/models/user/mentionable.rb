module User::Mentionable
  include ActionText::Attachable

  def attachable_content_type
    "application/vnd.campfire.mention"
  end

  def to_attachable_partial_path
    "users/mention"
  end

  def to_trix_content_attachment_partial_path
    "users/mention"
  end

  def attachable_plain_text_representation(caption)
    "@#{name}"
  end
end
