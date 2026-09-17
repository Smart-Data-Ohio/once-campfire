class Rooms::EventsController < ApplicationController
  include RoomScoped

  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  before_action :ensure_active_human
  before_action :set_event, except: %i[ index new create ]
  before_action :ensure_event_manager, only: %i[ edit update ]
  before_action :ensure_event_canceller, only: :cancel

  def index
    @upcoming_events = @room.events.upcoming.soonest_first.includes(:organizer, :attendances)
    @past_events = @room.events.past.ordered.includes(:organizer, :attendances)
    @cancelled_events = @room.events.cancelled.ordered.includes(:organizer, :attendances)
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
      redirect_to room_event_path(@room, @event), notice: "Event scheduled."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    @event.update_with_announcement!(event_attributes, actor: Current.user)
    redirect_to room_event_path(@room, @event), notice: "Event updated."
  rescue ActiveRecord::RecordInvalid
    render :edit, status: :unprocessable_content
  end

  def cancel
    if @event.cancel!(actor: Current.user)
      redirect_to room_event_path(@room, @event), notice: "Event cancelled."
    else
      redirect_to room_event_path(@room, @event), notice: "Event was already cancelled."
    end
  end

  private
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
      permitted = params.require(:event).permit(:title, :description, :starts_at, :ends_at, :time_zone)
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
