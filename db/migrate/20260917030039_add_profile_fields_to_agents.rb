class AddProfileFieldsToAgents < ActiveRecord::Migration[8.2]
  def change
    change_column :agents, :description, :text
    add_column :agents, :status, :string, null: false, default: "idle"
    add_column :agents, :status_note, :string
    add_column :agents, :status_changed_at, :datetime
    add_column :agents, :last_seen_at, :datetime
  end
end
