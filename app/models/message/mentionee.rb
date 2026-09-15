module Message::Mentionee
  extend ActiveSupport::Concern

  def mentionees
    return forward_note_mentionees if forwarded?

    room.users.where(id: mentioned_users.map(&:id))
  end

  private
    # Forwarded bodies are a snapshot. Mentions in that snapshot must never
    # notify people in the destination conversation; only a newly supplied
    # forward note may notify its explicit destination-room mentions.
    def forward_note_mentionees
      names = forward_note.to_s.scan(Message::Markdown::MENTION_TOKEN_PATTERN).map { |match| match.last }.uniq
      return User.none if names.empty?

      # Keep the normal mentionee contract: callers need an Active Record
      # relation for scopes such as `active_bots` and IDs for push delivery.
      # A name may only resolve when it identifies exactly one active member of
      # the destination room.
      uniquely_named_members = room.users.active.where(name: names).group(:name).having("COUNT(*) = 1").select(:name)
      room.users.active.where(name: uniquely_named_members)
    end

    def mentioned_users
      if body.body
        body.body.attachables.grep(User).uniq
      else
        []
      end
    end
end
