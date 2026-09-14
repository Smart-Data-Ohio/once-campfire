class Autocompletable::UsersController < ApplicationController
  def index
    set_page_and_extract_portion_from find_autocompletable_users.with_attached_avatar.ordered, per_page: 20
    @unique_markdown_mention_names = unique_markdown_mention_names
  end

  private
    def find_autocompletable_users
      params[:query].present? ? users_scope.active.filtered_by(params[:query]) : users_scope.active
    end

    def users_scope
      params[:room_id].present? ? Current.user.rooms.find(params[:room_id]).users : User.all
    end

    def unique_markdown_mention_names
      names = @page.records.filter_map { |user| Message::Markdown.mention_token(user.name) && user.name }
      users_scope.active.where(name: names).group(:name).having("COUNT(*) = 1").count.keys.to_set
    end
end
