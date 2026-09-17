class Rooms::StagesController < RoomsController
  before_action :set_room, only: %i[ show edit update ]
  before_action :ensure_can_administer, only: %i[ update ]
  before_action :remember_last_room_visited, only: :show
  before_action :ensure_permission_to_create_rooms, only: %i[ new create ]

  DEFAULT_ROOM_NAME = "New stage channel"

  def show
    redirect_to room_url(@room)
  end

  def new
    @room  = Rooms::Stage.new(name: DEFAULT_ROOM_NAME)
    @users = User.active.ordered
  end

  def create
    room = Rooms::Stage.create_for(room_params, users: grantees)

    broadcast_create_room(room)
    redirect_to room_url(room)
  end

  def edit
    selected_user_ids = @room.users.pluck(:id)
    @selected_users, @unselected_users = User.active.ordered.partition { |user| selected_user_ids.include?(user.id) }
  end

  def update
    @room.update! room_params
    @room.memberships.revise(granted: grantees, revoked: revokees)
    @room.memberships.where(stage_role: nil).update_all(stage_role: "listener")

    broadcast_update_room
    redirect_to room_url(@room)
  end

  private
    # Stage rooms keep their type: only stage rooms are in reach here, and the
    # open/closed/voice namespaces keep stage rooms out of reach in return.
    def room_scope
      Current.user.rooms.where(type: "Rooms::Stage")
    end

    def grantees
      User.where(id: grantee_ids)
    end

    def revokees
      @room.users.where.not(id: grantee_ids)
    end

    def grantee_ids
      params.fetch(:user_ids, [])
    end

    def broadcast_create_room(room)
      each_user_and_html_for(room) do |user, html|
        broadcast_prepend_to user, :rooms, target: :voice_rooms, html: html
      end
    end

    def broadcast_update_room
      each_user_and_html_for(@room) do |user, html|
        broadcast_replace_to user, :rooms, target: [ @room, :list ], html: html
      end
    end

    def each_user_and_html_for(room)
      # Optimization to avoid rendering the same partial for every user
      html = render_to_string(partial: "users/sidebars/rooms/stage", locals: { room: room })

      room.users.each { |user| yield user, html }
    end
end
