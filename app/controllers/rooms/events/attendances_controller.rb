class Rooms::Events::AttendancesController < ApplicationController
  include RoomScoped

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

    attendance = @event.attendances.find_or_initialize_by(user: Current.user)
    attendance.response = response

    if attendance.save
      redirect_to room_event_path(@room, @event), notice: "Response saved: #{attendance.response}."
    else
      redirect_to room_event_path(@room, @event), alert: attendance.errors.full_messages.to_sentence
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
