module Github
  # Shared normaliser for the review-request login lists used by the human
  # PR-thread endpoint and the agent write-action API. Splits on commas or
  # whitespace, strips one leading @, downcases for comparison, and dedupes.
  # Returns nil when any login is invalid or there are more than
  # MAX_REVIEWERS unique logins, and an empty array for blank input.
  module ReviewLogins
    LOGIN_PATTERN = /\A[a-z\d](?:[a-z\d]|-(?=[a-z\d])){0,38}\z/i
    MAX_REVIEWERS = 15
    INVALID_MESSAGE = "Enter GitHub usernames separated by commas.".freeze

    def self.normalize(submitted)
      tokens = case submitted
      when Array then submitted.flat_map { |item| item.to_s.split(/[\s,]+/) }
      else submitted.to_s.split(/[\s,]+/)
      end
      logins = tokens.reject(&:empty?).map { |token| token.sub(/\A@/, "").downcase }
      return nil if logins.any? { |login| !LOGIN_PATTERN.match?(login) }

      logins = logins.uniq
      return nil if logins.size > MAX_REVIEWERS

      logins
    end
  end
end
