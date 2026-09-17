class String
  def all_emoji?
    match?(/\A((\p{Emoji_Presentation}|\p{Extended_Pictographic}|\uFE0F)|(:[a-z0-9_]+:))+\z/u) &&
      scan(/:([a-z0-9_]+):/).flatten.all? { |name| Icons.brand?(name) }
  end
end
