class Rooms::Events::AttendancesController < ApplicationController
  include RoomScoped

  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }

  before_action :ensure_active_human
  before_action :set_event

  def update
    response = params[:response].presence || params.dig(:attendance, :response)

    unless EventAttendance.responses.key?(response.to_s)
      return redirect_to room_event_path(@room, @event), alert: "Choose going, maybe, or declined."
    end

    unless @event.respondable_by?(Current.user)
      return redirect_to room_event_path(@room, @event), alert: "This event is no longer open for responses."
    end

    apply_to_future = params[:apply_to_future] == "1" || params.dig(:attendance, :apply_to_future) == "1"

    begin
      attendance = @event.respond!(Current.user, response, apply_to_future:)
      redirect_to room_event_path(@room, @event), notice: "Response saved: #{attendance.response}."
    rescue ActiveRecord::RecordInvalid => error
      redirect_to room_event_path(@room, @event), alert: error.record.errors.full_messages.to_sentence
    end
  end

  private
    def set_event
      @event = @room.events.find(params[:event_id])
    end

    def ensure_active_human
      head :forbidden unless Current.user&.active? && !Current.user.bot?
    end
end
