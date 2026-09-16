module Github
  # Matches GitHub pull request URLs in message text. Accepts both the
  # canonical /pull/<number> form and /pulls/<number> variants, with any
  # trailing path, query, or fragment (e.g. /files, ?diff=split).
  module PullRequestUrl
    PATTERN = %r{
      https://github\.com/
      (?<owner>[A-Za-z0-9_.-]+)/
      (?<repo>[A-Za-z0-9_.-]+)/
      (?:pull|pulls)/
      (?<number>\d+)\b
    }x

    Reference = Data.define(:owner, :repo, :number)

    class << self
      # Unique (owner, repo, number) triples referenced by the given text.
      def extract(text)
        return [] if text.blank?

        text.to_s.scan(PATTERN).map { |owner, repo, number|
          Reference.new(owner, repo, number.to_i)
        }.uniq
      end

      def pull_request_url?(url)
        url.to_s.match?(PATTERN)
      end
    end
  end
end
