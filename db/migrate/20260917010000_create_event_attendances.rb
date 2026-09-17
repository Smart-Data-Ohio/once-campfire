class CreateEventAttendances < ActiveRecord::Migration[8.2]
  def change
    create_table :event_attendances do |t|
      t.integer :event_id, null: false
      t.integer :user_id, null: false
      t.string :response, null: false
      t.timestamps

      t.index [ :event_id, :user_id ], unique: true
    end
  end
end
