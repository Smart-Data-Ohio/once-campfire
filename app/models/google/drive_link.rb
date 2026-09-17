module Google
  # Extracts a Drive file id from the URL shapes users paste into messages.
  # Mirrors the patterns in drive_link_controller.js; keep the two lists and
  # docs/google-drive.md in sync when either changes.
  module DriveLink
    ACCOUNT_PREFIX = /(?:u\/\d+\/)?/
    private_constant :ACCOUNT_PREFIX

    PATTERNS = [
      %r{\Ahttps://docs\.google\.com/#{ACCOUNT_PREFIX}(?:document|spreadsheets|presentation|forms)/#{ACCOUNT_PREFIX}d/(?<id>[A-Za-z0-9_-]{10,})}i,
      %r{\Ahttps://drive\.google\.com/#{ACCOUNT_PREFIX}file/#{ACCOUNT_PREFIX}d/(?<id>[A-Za-z0-9_-]{10,})}i,
      %r{\Ahttps://drive\.google\.com/#{ACCOUNT_PREFIX}drive/#{ACCOUNT_PREFIX}folders/(?<id>[A-Za-z0-9_-]{10,})}i,
      %r{\Ahttps://drive\.google\.com/#{ACCOUNT_PREFIX}open\?(?:[^#]*&)?id=(?<id>[A-Za-z0-9_-]{10,})(?:&|#|\z)}i
    ].freeze

    class << self
      # Returns the file id for a supported Drive URL, nil otherwise.
      def file_id(url)
        PATTERNS.each do |pattern|
          if (match = url.to_s.match(pattern))
            return match[:id]
          end
        end
        nil
      end

      # True for a bare file id (letters, digits, _ and -, at least 10 chars).
      def valid_id?(id)
        id.to_s.match?(/\A[A-Za-z0-9_-]{10,}\z/)
      end
    end
  end
end
