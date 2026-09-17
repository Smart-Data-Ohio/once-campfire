# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.2].define(version: 2026_09_16_030000) do
  create_table "accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "custom_styles"
    t.string "join_code", null: false
    t.string "name", null: false
    t.json "settings"
    t.integer "singleton_guard", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["singleton_guard"], name: "index_accounts_on_singleton_guard", unique: true
  end

  create_table "action_text_rich_texts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "activity_items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.datetime "handled_at"
    t.datetime "read_at"
    t.integer "source_id", null: false
    t.string "source_type", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["event_type", "created_at"], name: "index_activity_items_on_event_type_and_created_at"
    t.index ["source_type", "source_id"], name: "index_activity_items_on_source"
    t.index ["user_id", "read_at", "handled_at", "created_at"], name: "index_activity_items_on_user_and_state"
    t.index ["user_id", "source_type", "source_id"], name: "index_activity_items_on_user_and_source", unique: true
  end

  create_table "agent_credentials", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.datetime "created_at", null: false
    t.integer "created_by_id", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "last_used_ip"
    t.string "name", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.string "token_last_four", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "revoked_at"], name: "index_agent_credentials_on_agent_id_and_revoked_at"
    t.index ["token_digest"], name: "index_agent_credentials_on_token_digest", unique: true
  end

  create_table "agent_grants", force: :cascade do |t|
    t.integer "agent_id", null: false
    t.string "capability", null: false
    t.datetime "created_at", null: false
    t.integer "granted_by_id", null: false
    t.datetime "revoked_at"
    t.integer "room_id"
    t.datetime "updated_at", null: false
    t.index ["agent_id", "capability"], name: "index_agent_grants_on_agent_capability_active_workspace", unique: true, where: "revoked_at IS NULL AND room_id IS NULL"
    t.index ["agent_id", "revoked_at"], name: "index_agent_grants_on_agent_id_and_revoked_at"
    t.index ["agent_id", "room_id", "capability"], name: "index_agent_grants_on_agent_room_capability_active", unique: true, where: "revoked_at IS NULL AND room_id IS NOT NULL"
  end

  create_table "agents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description"
    t.string "kind", default: "personal", null: false
    t.integer "owner_id"
    t.string "provider"
    t.string "runtime"
    t.datetime "suspended_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["owner_id", "kind"], name: "index_agents_on_owner_id_and_kind"
    t.index ["user_id"], name: "index_agents_on_user_id", unique: true
  end

  create_table "bans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["ip_address"], name: "index_bans_on_ip_address"
    t.index ["user_id"], name: "index_bans_on_user_id"
  end

  create_table "boosts", force: :cascade do |t|
    t.integer "booster_id", null: false
    t.string "content", limit: 16, null: false
    t.datetime "created_at", null: false
    t.integer "message_id", null: false
    t.datetime "updated_at", null: false
    t.index ["booster_id"], name: "index_boosts_on_booster_id"
    t.index ["message_id"], name: "index_boosts_on_message_id"
  end

  create_table "channel_threads", force: :cascade do |t|
    t.integer "auto_archive_after_minutes", default: 4320, null: false
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.integer "creator_id", null: false
    t.datetime "last_activity_at", null: false
    t.datetime "locked_at"
    t.string "name", null: false
    t.integer "parent_message_id"
    t.integer "room_id", null: false
    t.datetime "updated_at", null: false
    t.integer "work_owner_id"
    t.string "work_status"
    t.index ["creator_id"], name: "index_channel_threads_on_creator_id"
    t.index ["parent_message_id"], name: "index_channel_threads_on_parent_message_id", unique: true, where: "parent_message_id IS NOT NULL"
    t.index ["room_id", "closed_at", "locked_at"], name: "index_channel_threads_on_room_id_and_closed_at_and_locked_at"
    t.index ["room_id", "last_activity_at"], name: "index_channel_threads_on_room_id_and_last_activity_at"
    t.index ["room_id", "work_status", "last_activity_at"], name: "index_channel_threads_on_room_and_work_status_and_activity"
    t.index ["work_owner_id"], name: "index_channel_threads_on_work_owner_id"
  end

  create_table "huddle_cleanups", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "enqueued_at"
    t.integer "huddle_grant_id"
    t.string "identity"
    t.datetime "last_attempted_at"
    t.datetime "next_attempt_at"
    t.string "operation", null: false
    t.string "room_name", null: false
    t.datetime "updated_at", null: false
    t.index ["completed_at", "next_attempt_at"], name: "index_huddle_cleanups_on_completed_at_and_next_attempt_at"
    t.index ["huddle_grant_id"], name: "index_huddle_cleanups_on_huddle_grant_id"
    t.index ["operation", "huddle_grant_id"], name: "index_huddle_cleanups_on_unique_participant_removal", unique: true, where: "operation = 'remove_participant'"
    t.index ["operation", "room_name"], name: "index_huddle_cleanups_on_unique_room_deletion", unique: true, where: "operation = 'delete_room'"
  end

  create_table "huddle_grants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "identity", null: false
    t.datetime "last_issued_at"
    t.datetime "last_seen_at"
    t.integer "membership_id", null: false
    t.datetime "revoked_at"
    t.integer "room_id", null: false
    t.string "room_name", null: false
    t.integer "session_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["identity"], name: "index_huddle_grants_on_identity", unique: true
    t.index ["membership_id"], name: "index_huddle_grants_on_membership_id"
    t.index ["room_id", "last_seen_at"], name: "index_huddle_grants_on_room_and_last_seen_at"
    t.index ["room_id"], name: "index_huddle_grants_on_room_id"
    t.index ["session_id", "membership_id"], name: "index_active_huddle_grants_on_session_and_membership", unique: true, where: "revoked_at IS NULL"
    t.index ["session_id"], name: "index_huddle_grants_on_session_id"
    t.index ["user_id"], name: "index_huddle_grants_on_user_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.datetime "connected_at"
    t.integer "connections", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "involvement", default: "mentions"
    t.integer "room_id", null: false
    t.datetime "unread_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["room_id", "created_at"], name: "index_memberships_on_room_id_and_created_at"
    t.index ["room_id", "user_id"], name: "index_memberships_on_room_id_and_user_id", unique: true
    t.index ["room_id"], name: "index_memberships_on_room_id"
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.string "client_message_id", null: false
    t.datetime "created_at", null: false
    t.integer "creator_id", null: false
    t.text "forward_note"
    t.datetime "forwarded_at"
    t.integer "forwarded_from_message_id"
    t.text "markdown_source"
    t.boolean "reply_notify_author", default: true, null: false
    t.datetime "reply_target_deleted_at"
    t.integer "reply_to_message_id"
    t.integer "room_id", null: false
    t.integer "thread_id"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_messages_on_creator_id"
    t.index ["forwarded_from_message_id"], name: "index_messages_on_forwarded_from_message_id"
    t.index ["reply_to_message_id"], name: "index_messages_on_reply_to_message_id"
    t.index ["room_id"], name: "index_messages_on_room_id"
    t.index ["thread_id"], name: "index_messages_on_thread_id"
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.string "auth_key"
    t.datetime "created_at", null: false
    t.string "endpoint"
    t.string "p256dh_key"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["endpoint", "p256dh_key", "auth_key"], name: "idx_on_endpoint_p256dh_key_auth_key_7553014576"
    t.index ["user_id"], name: "index_push_subscriptions_on_user_id"
  end

  create_table "rooms", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "creator_id", null: false
    t.string "name"
    t.string "type", null: false
    t.datetime "updated_at", null: false
  end

  create_table "searches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "query", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_searches_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "last_active_at", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["token"], name: "index_sessions_on_token", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "thread_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "involvement", default: "mentions", null: false
    t.datetime "joined_at", null: false
    t.integer "thread_id", null: false
    t.datetime "unread_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["thread_id", "unread_at"], name: "index_thread_memberships_on_thread_id_and_unread_at"
    t.index ["thread_id", "user_id"], name: "index_thread_memberships_on_thread_id_and_user_id", unique: true
    t.index ["user_id"], name: "index_thread_memberships_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.text "bio"
    t.string "bot_token"
    t.datetime "created_at", null: false
    t.string "email_address"
    t.string "name", null: false
    t.string "password_digest"
    t.integer "role", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["bot_token"], name: "index_users_on_bot_token", unique: true
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "webhooks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_webhooks_on_user_id"
  end

  create_table "work_thread_events", force: :cascade do |t|
    t.integer "actor_id"
    t.integer "channel_thread_id", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.integer "from_owner_id"
    t.string "from_owner_name"
    t.string "from_status"
    t.json "metadata"
    t.integer "to_owner_id"
    t.string "to_owner_name"
    t.string "to_status"
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_work_thread_events_on_actor_id"
    t.index ["channel_thread_id", "created_at"], name: "index_work_thread_events_on_thread_and_created_at"
    t.index ["channel_thread_id"], name: "index_work_thread_events_on_channel_thread_id"
    t.index ["event_type", "created_at"], name: "index_work_thread_events_on_type_and_created_at"
  end

  create_table "workspace_presence_leases", force: :cascade do |t|
    t.string "connection_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.integer "session_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["connection_id"], name: "index_workspace_presence_leases_on_connection_id", unique: true
    t.index ["expires_at"], name: "index_workspace_presence_leases_on_expires_at"
    t.index ["session_id"], name: "index_workspace_presence_leases_on_session_id"
    t.index ["user_id"], name: "index_workspace_presence_leases_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "activity_items", "users", on_delete: :cascade
  add_foreign_key "bans", "users"
  add_foreign_key "boosts", "messages"
  add_foreign_key "channel_threads", "messages", column: "parent_message_id", on_delete: :nullify
  add_foreign_key "channel_threads", "rooms"
  add_foreign_key "channel_threads", "users", column: "creator_id"
  add_foreign_key "channel_threads", "users", column: "work_owner_id", on_delete: :nullify
  add_foreign_key "messages", "channel_threads", column: "thread_id", on_delete: :cascade
  add_foreign_key "messages", "messages", column: "forwarded_from_message_id", on_delete: :nullify
  add_foreign_key "messages", "messages", column: "reply_to_message_id", on_delete: :nullify
  add_foreign_key "messages", "rooms"
  add_foreign_key "messages", "users", column: "creator_id"
  add_foreign_key "push_subscriptions", "users"
  add_foreign_key "searches", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "thread_memberships", "channel_threads", column: "thread_id", on_delete: :cascade
  add_foreign_key "thread_memberships", "users", on_delete: :cascade
  add_foreign_key "webhooks", "users"
  add_foreign_key "work_thread_events", "channel_threads", on_delete: :cascade
  add_foreign_key "work_thread_events", "users", column: "actor_id", on_delete: :nullify
  add_foreign_key "workspace_presence_leases", "sessions", on_delete: :cascade
  add_foreign_key "workspace_presence_leases", "users", on_delete: :cascade

  # Virtual tables defined in this database.
  # Note that virtual tables may not work with other database engines. Be careful if changing database.
  create_virtual_table "message_search_index", "fts5", ["body", "tokenize=porter"]
end
