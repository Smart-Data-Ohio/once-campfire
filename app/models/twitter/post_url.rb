module Twitter
  # Matches X/Twitter post URLs in message text. Accepts the canonical
  # /<handle>/status/<id> form (and the rare /statuses/ plural) plus the
  # handle-less /i/status/<id> and /i/web/status/<id> forms, on x.com and
  # twitter.com with optional www./mobile. subdomains, any scheme, and any
  # trailing path, query, or fragment (e.g. /photo/1, ?s=20).
  module PostUrl
    PATTERN = %r{
      https?://(?:www\.|mobile\.)?(?:twitter\.com|x\.com)/
      (?:
        i/(?:web/)?status/
        |
        (?<handle>[A-Za-z0-9_]{1,15})/status(?:es)?/
      )
      (?<id>\d{1,25})\b
    }x

    MAX_PER_MESSAGE = 4

    Reference = Data.define(:handle, :post_id)

    class << self
      # Unique post ids referenced by the given text, in order of appearance,
      # capped at MAX_PER_MESSAGE. Handles are kept for the API request but
      # dedupe is by id: the same post linked twice is one card.
      def extract(text)
        return [] if text.blank?

        references = []
        text.to_s.scan(PATTERN) do
          match = Regexp.last_match
          post_id = match[:id]
          next if references.any? { |reference| reference.post_id == post_id }

          references << Reference.new(match[:handle], post_id)
          break if references.size >= MAX_PER_MESSAGE
        end
        references
      end

      def post_url?(url)
        url.to_s.match?(PATTERN)
      end
    end
  end
end
