module Twitter
  # Formats stored post text as card HTML: escaped, with line breaks
  # preserved and URLs, @mentions, and #hashtags linked to x.com. The input
  # is untrusted API content, so every emitted anchor is built here from
  # validated parts and everything else is escaped; stored text is never
  # marked html_safe.
  module PostFormatter
    URL_PATTERN = %r|https?://[^\s<>"'`\])}]+|
    TOKEN_PATTERN = /((?<!\w)@[A-Za-z0-9_]{1,15}\b|(?<!\w)#[\p{Alnum}_]+)/u
    TRAILING_PUNCTUATION = /[.,;:!?]+$/

    # Above this the card clamps to 12 lines behind a "Show more" toggle;
    # below it the text renders in full. Line count depends on width, so this
    # is a character heuristic, not a line measurement.
    CLAMP_CHARS = 480
    CLAMP_BREAKS = 12

    class << self
      def format(text)
        formatted = text.to_s.split(/(\s+)/, -1).map do |part|
          part.match?(/\A\s/) ? part : format_word(part)
        end.join

        ActiveSupport::SafeBuffer.new(formatted.gsub(/\r?\n/, "<br>"))
      end

      def clamp?(text)
        text = text.to_s
        text.length > CLAMP_CHARS || text.count("\n") >= CLAMP_BREAKS
      end

      # Link-free rendering for the clamped <summary> preview: interactive
      # content inside a summary fights its toggle, so links appear only in
      # the expanded body.
      def plain(text)
        ActiveSupport::SafeBuffer.new(ERB::Util.html_escape(text.to_s).gsub(/\r?\n/, "<br>"))
      end

      private
        # Links the URLs a word contains, then the mentions and hashtags in
        # the text around them; mentions inside a URL are never linked.
        def format_word(word)
          output = +""
          rest = word

          while (match = rest.match(URL_PATTERN))
            output << format_text_chunk(rest[0...match.begin(0)])
            url = match[0].sub(TRAILING_PUNCTUATION, "")
            output << link(url)
            output << format_text_chunk(match[0].delete_prefix(url))
            rest = rest[match.end(0)..]
          end

          output << format_text_chunk(rest)
          output
        end

        # Splitting on a single capture group puts the matched tokens at odd
        # indices and the plain gaps at even ones; only the gaps are escaped.
        def format_text_chunk(chunk)
          chunk.split(TOKEN_PATTERN, -1).map.with_index do |part, index|
            if index.odd?
              link_token(part)
            else
              ERB::Util.html_escape(part)
            end
          end.join
        end

        def link_token(token)
          if token.start_with?("@")
            mention_link(token[1..])
          else
            hashtag_link(token[1..])
          end
        end

        def link(url)
          escaped = ERB::Util.html_escape(url)
          %(<a href="#{escaped}" target="_blank" rel="noopener noreferrer">#{escaped}</a>)
        end

        def mention_link(handle)
          %(<a href="https://x.com/#{handle}" target="_blank" rel="noopener noreferrer">@#{handle}</a>)
        end

        def hashtag_link(tag)
          encoded = ERB::Util.url_encode(tag)
          escaped = ERB::Util.html_escape(tag)
          %(<a href="https://x.com/hashtag/#{encoded}" target="_blank" rel="noopener noreferrer">##{escaped}</a>)
        end
    end
  end
end
