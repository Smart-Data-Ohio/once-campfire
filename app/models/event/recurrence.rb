class Event::Recurrence
  RULES = %w[ daily weekly biweekly monthly ].freeze
  MAX_OCCURRENCES = 52
  SCOPES = %w[ this_event this_and_following ].freeze

  PHRASES = {
    "daily" => "daily",
    "weekly" => "weekly",
    "biweekly" => "every two weeks",
    "monthly" => "monthly"
  }.freeze

  STEP_DAYS = { "daily" => 1, "weekly" => 7, "biweekly" => 14 }.freeze

  class << self
    def phrase(rule)
      PHRASES.fetch(rule.to_s, rule.to_s)
    end

    def label(rule)
      "Repeats #{phrase(rule)}"
    end

    # Every occurrence as [ starts_at, ends_at ], head slot first. Local
    # wall-clock time is preserved across daylight-saving changes, and a
    # monthly series anchors to the head's day of month, clamping to the last
    # day when a month is short (Jan 31 -> Feb 28 -> Mar 31).
    def slots(starts_at:, ends_at:, time_zone:, rule:, until_date:)
      zone = ActiveSupport::TimeZone[time_zone]
      return [] if zone.nil? || starts_at.nil? || until_date.nil?

      first = starts_at.in_time_zone(zone)
      duration = ends_at ? ends_at - starts_at : nil
      head_date = first.to_date
      occurrence_dates =
        if rule.to_s == "monthly"
          monthly_dates(head_date, day_of_month: first.day, until_date:)
        else
          stepped_dates(head_date, step_days: STEP_DAYS.fetch(rule.to_s, 7), until_date:)
        end

      occurrence_dates.map do |date|
        start = zone.local(date.year, date.month, date.day, first.hour, first.min, first.sec)
        [ start, duration ? start + duration : nil ]
      end
    end

    def occurrence_count(starts_at:, time_zone:, rule:, until_date:)
      slots(starts_at:, ends_at: nil, time_zone:, rule:, until_date:).size
    end

    private
      def stepped_dates(head_date, step_days:, until_date:)
        dates = []
        offset = 0
        while (date = head_date + offset) <= until_date
          dates << date
          offset += step_days
        end
        dates
      end

      def monthly_dates(head_date, day_of_month:, until_date:)
        dates = []
        month_start = Date.new(head_date.year, head_date.month, 1)
        loop do
          last_day = Date.new(month_start.year, month_start.month, -1).day
          date = Date.new(month_start.year, month_start.month, [ day_of_month, last_day ].min)
          break if date > until_date

          dates << date
          month_start >>= 1
        end
        dates
      end
  end
end
