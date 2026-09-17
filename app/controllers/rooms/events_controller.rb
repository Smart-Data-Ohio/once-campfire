class Rooms::EventsController < ApplicationController
  include RoomScoped

  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  before_action :ensure_active_human
  before_action :set_event, except: %i[ index new create ]
  before_action :ensure_event_manager, only: %i[ edit update ]
  before_action :ensure_event_canceller, only: :cancel

  def index
    upcoming_scope = @room.events.upcoming
    remaining_by_series = upcoming_scope.where.not(series_id: nil).group(:series_id).count
    representative_ids = remaining_by_series.keys.filter_map do |series_id|
      upcoming_scope.where(series_id:).soonest_first.pick(:id)
    end
    representatives = @room.events.where(id: representative_ids).includes(:organizer, :attendances, :venue).to_a
    @series_counts = representatives.to_h { |event| [ event.id, remaining_by_series.fetch(event.series_id) ] }
    singles = @room.events.upcoming.where(series_id: nil).soonest_first.includes(:organizer, :attendances, :venue).to_a
    @upcoming_events = (singles + representatives).sort_by { |event| [ event.starts_at, event.id ] }
    @past_events = @room.events.past.ordered.includes(:organizer, :attendances, :venue)
    @cancelled_events = @room.events.cancelled.ordered.includes(:organizer, :attendances, :venue)
    preload_venue_streams(@upcoming_events + @past_events.to_a + @cancelled_events.to_a)
  end

  def show
    @attendances = @event.attendances.includes(:user).order(:response, :id)
    @current_response = @event.response_for(Current.user)
  end

  def new
    @event = @room.events.build(time_zone: "UTC")
  end

  def create
    @event = @room.events.build(event_attributes.merge(organizer: Current.user))

    if @event.save
      notice = @event.recurrence_rule.present? ? "Repeating event scheduled." : "Event scheduled."
      redirect_to room_event_path(@room, @event), notice:
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    @event.update_with_scope!(event_attributes, scope: params[:update_scope], actor: Current.user)
    redirect_to room_event_path(@room, @event), notice: "Event updated."
  rescue ActiveRecord::RecordInvalid
    render :edit, status: :unprocessable_content
  end

  def cancel
    if @event.cancel_with_scope!(scope: params[:cancel_scope], actor: Current.user)
      redirect_to room_event_path(@room, @event), notice: "Event cancelled."
    else
      redirect_to room_event_path(@room, @event), notice: "Event was already cancelled."
    end
  end

  private
    # Preloads the live stream behind stage venues so rows read
    # `venue.live_stream` without a query each. Nested `includes` cannot
    # express this: venues preload as Room, which has no streams association.
    # Only the live row is loaded, never the venue's stream history.
    def preload_venue_streams(events)
      venues = events.filter_map(&:venue).select(&:stage?)
      ActiveRecord::Associations::Preloader.new(records: venues, associations: :live_streams).call
    end

    def set_event
      @event = @room.events.find(params[:id])
    end

    def ensure_active_human
      head :forbidden unless Current.user&.active? && !Current.user.bot?
    end

    def ensure_event_manager
      head :forbidden unless @event.manageable_by?(Current.user)
    end

    def ensure_event_canceller
      head :forbidden unless @event.cancellable_by?(Current.user)
    end

    def event_attributes
      permitted = params.require(:event).permit(:title, :description, :starts_at, :ends_at, :time_zone, :recurrence_rule, :recurrence_until, :venue_room_id)
      # The zone is fixed when the event is scheduled. Edits keep reading the
      # posted times in that zone, so an editor elsewhere cannot move the event
      # by saving the form untouched.
      zone = @event ? @event.time_zone : (permitted[:time_zone].presence || "UTC")
      permitted[:time_zone] = zone
      permitted[:starts_at] = parse_event_time(permitted[:starts_at], zone)
      permitted[:ends_at] = parse_event_time(permitted[:ends_at], zone)
      permitted
    end

    # The form posts zone-less datetime-local values, so interpret them in the
    # event's own time zone rather than the server zone.
    def parse_event_time(value, zone)
      return if value.blank?

      (ActiveSupport::TimeZone[zone] || Time.zone).parse(value.to_s)
    rescue ArgumentError, TypeError
    end
end
