class CreateGoogleCalendarTables < ActiveRecord::Migration[8.2]
  def change
    create_table :google_accounts do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :email, null: false
      t.string :refresh_token
      t.string :access_token
      t.datetime :access_token_expires_at
      t.string :disconnected_reason
      t.timestamps
    end

    create_table :event_calendar_entries do |t|
      t.references :event, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :google_event_id, null: false
      t.datetime :synced_at
      t.string :last_error
      t.timestamps

      t.index %i[ event_id user_id ], unique: true
    end
  end
end
