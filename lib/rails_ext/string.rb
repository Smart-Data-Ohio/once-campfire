class String
  def all_emoji?
    self.match? /\A((\p{Emoji_Presentation}|\p{Extended_Pictographic}|\uFE0F)|(:[a-z0-9_]+:))+\z/u
  end
end
