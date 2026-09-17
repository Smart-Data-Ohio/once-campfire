require "net/http"

module Twitter
  # Read-only fxtwitter JSON API client backing X post cards. Fetches one
  # post and persists the card fields on the record.
  #
  # Never raises for expected failures (HTTP errors, missing posts, network
  # problems): those are recorded as fetch_error so the card can say the
  # post could not be loaded. Everything from the API is untrusted: text is
  # stripped of tags, media URLs must be twimg hosts, and the response
  # body is never logged.
  class PostFetcher
    API_HOST = "api.fxtwitter.com"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    MAX_BODY_BYTES = 2.megabytes
    MAX_MEDIA = 4

    ALLOWED_MEDIA_HOSTS = %w[ pbs.twimg.com video.twimg.com ].freeze

    class FetchError < StandardError; end

    def initialize(post)
      @post = post
    end

    def fetch
      tweet = fetch_tweet

      @post.update!(
        card_attributes(tweet).merge(fetched_at: Time.current, fetch_error: nil)
      )
    rescue FetchError => error
      @post.update!(fetched_at: Time.current, fetch_error: error.message)
    rescue StandardError => error
      Rails.logger.warn "Twitter::PostFetcher failed for post #{@post.post_id}: #{error.class}"
      @post.update!(fetched_at: Time.current, fetch_error: "Could not reach X (#{error.class.name.demodulize.titleize})")
    end

    private
      def card_attributes(tweet)
        author = tweet["author"].is_a?(Hash) ? tweet["author"] : {}
        handle = clean_handle(author["screen_name"])

        {
          url: canonical_url(tweet, handle),
          author_handle: handle,
          author_name: clean_text(author["name"]),
          author_avatar_url: twimg_url(author["avatar_url"]),
          text: clean_text(tweet["text"]),
          posted_at: posted_at_from(tweet),
          replies: clean_count(tweet["replies"]),
          reposts: clean_count(tweet["retweets"]),
          likes: clean_count(tweet["likes"]),
          media: clean_media(tweet["media"]),
          quote: clean_quote(tweet["quote"])
        }
      end

      def fetch_tweet
        response = get(request_path)

        case response
        when Net::HTTPSuccess
          parse_tweet(response)
        when Net::HTTPNotFound
          raise FetchError, "Post not found on X"
        else
          raise FetchError, "fxtwitter returned #{response.code}"
        end
      end

      # The handle in the path is cosmetic (the API resolves by id), but
      # handle links keep their handle and handle-less /i/ links use the /i/
      # form, which the API answers the same way.
      def request_path
        handle = PostUrl.extract(@post.url).first&.handle || "i"
        "/#{handle}/status/#{@post.post_id}"
      end

      def get(path)
        uri = URI::HTTPS.build(host: API_HOST, path: path)

        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.get(uri.request_uri, { "User-Agent" => "Campfire-X-Post-Cards", "Accept" => "application/json" })
        end
      end

      def parse_tweet(response)
        if response["Content-Length"].to_i > MAX_BODY_BYTES
          raise FetchError, "Post response too large"
        end

        body = response.body.to_s
        if body.bytesize > MAX_BODY_BYTES
          raise FetchError, "Post response too large"
        end

        data = JSON.parse(body)
        tweet = data.is_a?(Hash) ? data["tweet"] : nil

        if tweet.is_a?(Hash)
          tweet
        elsif data.is_a?(Hash) && data["code"] == 404
          raise FetchError, "Post not found on X"
        else
          raise FetchError, "Could not load this post"
        end
      rescue JSON::ParserError
        raise FetchError, "Could not load this post"
      end

      def canonical_url(tweet, handle)
        return @post.view_url if handle.blank?

        expected_id = tweet["id"].to_s.presence || @post.post_id
        "https://x.com/#{handle}/status/#{expected_id}"
      end

      def posted_at_from(tweet)
        timestamp = tweet["created_timestamp"]
        return Time.zone.at(timestamp) if timestamp.is_a?(Numeric)

        Time.zone.parse(tweet["created_at"].to_s)
      rescue StandardError
        nil
      end

      def clean_text(value)
        stripped = sanitizer.sanitize(value.to_s).strip
        stripped.presence&.truncate(Post::MAX_TEXT_CHARS, omission: "")
      end

      def clean_handle(value)
        handle = value.to_s.strip
        handle if handle.match?(/\A[A-Za-z0-9_]{1,15}\z/)
      end

      def clean_count(value)
        value.is_a?(Numeric) ? value.to_i : nil
      end

      # Photos carry url/width/height (no thumbnail); videos and gifs carry
      # url plus thumbnail_url. Only twimg URLs survive; anything else is
      # dropped, and the card renders without that media.
      def clean_media(media)
        return [] unless media.is_a?(Hash)

        entries = Array(media["photos"]) + Array(media["videos"])
        entries.filter_map { |entry| clean_media_entry(entry) }.first(MAX_MEDIA)
      end

      def clean_media_entry(entry)
        return unless entry.is_a?(Hash)
        return unless entry["type"].to_s.in?(%w[ photo video gif ])

        url = twimg_url(entry["url"])
        return if url.nil?

        thumbnail_url = entry["type"] == "photo" ? nil : twimg_url(entry["thumbnail_url"])
        return if entry["type"] != "photo" && thumbnail_url.nil?

        {
          "type" => entry["type"],
          "url" => url,
          "thumbnail_url" => thumbnail_url,
          "width" => positive_integer(entry["width"]),
          "height" => positive_integer(entry["height"]),
          "alt" => entry["altText"].presence || entry["alt"].presence
        }
      end

      def clean_quote(quote)
        return unless quote.is_a?(Hash)

        author = quote["author"].is_a?(Hash) ? quote["author"] : {}
        text = clean_text(quote["text"])
        return if text.blank?

        {
          "url" => quote_url(quote["url"]),
          "author_name" => clean_text(author["name"]),
          "author_handle" => clean_handle(author["screen_name"]),
          "text" => text
        }
      end

      def quote_url(value)
        PostUrl.post_url?(value) ? value.to_s : nil
      end

      def twimg_url(value)
        return if value.blank?

        parsed = URI.parse(value.to_s)
        value.to_s if parsed.is_a?(URI::HTTPS) && parsed.host.in?(ALLOWED_MEDIA_HOSTS)
      rescue URI::InvalidURIError
        nil
      end

      def positive_integer(value)
        integer = value.is_a?(Numeric) ? value.to_i : Integer(value.to_s, exception: false)
        integer if integer.is_a?(Integer) && integer.positive?
      end

      def sanitizer
        @sanitizer ||= ActionView::Base.full_sanitizer
      end
  end
end
