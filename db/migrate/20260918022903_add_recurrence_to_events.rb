class AddRecurrenceToEvents < ActiveRecord::Migration[8.2]
  def change
    add_column :events, :recurrence_rule, :string
    add_column :events, :recurrence_until, :date
    add_column :events, :series_id, :integer
    add_index :events, :series_id
  end
end
