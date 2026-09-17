Rails.application.routes.draw do
  root "welcome#show"

  namespace :internal do
    post "huddle/authorize", to: "huddle#authorize"
    get "huddle/grants/:id", to: "huddle#show"
  end

  resource :first_run

  resource :session do
    scope module: "sessions" do
      resources :transfers, only: %i[ show update ]
    end
  end

  resource :account do
    scope module: "accounts" do
      resources :users

      resources :bots do
        scope module: "bots" do
          resource :key, only: :update
          resources :credentials, only: %i[ index create destroy ]
          resources :grants, only: %i[ index create destroy ]
          resource :github_connection, only: %i[ create destroy ]
        end
      end

      resources :icons, only: %i[ index create destroy ]

      resource :join_code, only: :create
      resource :logo, only: %i[ show destroy ]
      resource :custom_styles, only: %i[ edit update ]
    end
  end

  direct :fresh_account_logo do |options|
    route_for :account_logo, v: Current.account&.updated_at&.to_fs(:number), size: options[:size]
  end

  get "join/:join_code", to: "users#new", as: :join
  post "join/:join_code", to: "users#create"

  resources :qr_code, only: :show

  resources :users, only: :show do
    get :huddle_presence, on: :collection, to: "users/huddle_presence#show"

    scope module: "users" do
      resource :avatar, only: %i[ show destroy ]
      resource :ban, only: %i[ create destroy ]

      scope defaults: { user_id: "me" } do
        resource :sidebar, only: :show
        resource :profile
        resources :push_subscriptions do
          scope module: "push_subscriptions" do
            resources :test_notifications, only: :create
          end
        end
      end
    end
  end

  namespace :autocompletable do
    resources :users, only: :index
    resources :icons, only: :index
  end

  get "icons/:name", to: "workspace_icons#show", as: :workspace_icon

  get "agents", to: "agents/directory#index"
  get "agents/me", to: "agents#me", defaults: { format: :json }
  patch "agents/me", to: "agents#update", defaults: { format: :json }
  get "agents/events", to: "agents/events#index", defaults: { format: :json }
  post "agents/events/:id/ack", to: "agents/events#ack", defaults: { format: :json }, as: :ack_agents_event
  get "agents/:id/events", to: "agents/events#ledger", as: :agent_events
  get "agents/approvals", to: "agents/approvals#index", defaults: { format: :json }
  post "agents/approvals", to: "agents/approvals#create", defaults: { format: :json }
  get "agents/approvals/:id", to: "agents/approvals#show", defaults: { format: :json }
  delete "agents/approvals/:id", to: "agents/approvals#destroy", defaults: { format: :json }
  get "agents/:id/approvals", to: "agents/approvals#for_agent", as: :agent_approvals
  patch "agent_approvals/:id", to: "agent_approvals#update", as: :agent_approval
  get "agents/work", to: "agents/work#index", defaults: { format: :json }, as: :agents_work
  get "agents/work/:id", to: "agents/work#show", defaults: { format: :json }, as: :agents_work_thread
  patch "agents/work/:id", to: "agents/work#update", defaults: { format: :json }
  post "rooms/:room_id/agents/messages", to: "agents/messages#create", defaults: { format: :json }, as: :room_agent_messages
  post "rooms/:room_id/agents/github/pull_request_actions", to: "agents/github/pull_request_actions#create",
    defaults: { format: :json }, as: :room_agent_github_pull_request_actions

  direct :fresh_user_avatar do |user, options|
    route_for :user_avatar, user.avatar_token, v: user.updated_at.to_fs(:number)
  end

  resources :rooms do
    resources :messages do
      post :preview, on: :collection
      get :actions, on: :member
      get :forward_source, on: :member, controller: "message_forward_sources"
      resources :forwards, controller: "message_forwards", only: :create
      get "forwards/destinations", to: "message_forwards#destinations", as: :forward_destinations
    end

    resources :threads, controller: "channel_threads", only: %i[ index show new create update destroy ] do
      get :content, on: :member
      resources :messages, controller: "channel_thread_messages", only: %i[ index show create update destroy ] do
        get :actions, on: :member
        get :forward_source, on: :member, controller: "message_forward_sources"
        resources :forwards, controller: "message_forwards", only: :create
        get "forwards/destinations", to: "message_forwards#destinations", as: :forward_destinations
      end
      post :join, on: :member
      delete :leave, on: :member
      post :read, on: :member
      patch :read, on: :member
    end

    nested do
      scope path: ":bot_key", as: :bot, defaults: { format: :json } do
        resources :messages, controller: "messages/by_bots", only: %i[ index create update destroy ] do
          resources :boosts, controller: "messages/boosts/by_bots", only: %i[ create destroy ]
        end
      end
    end

    scope module: "rooms" do
      resources :members, only: :index
      resources :events, only: %i[ index show new create edit update ] do
        patch :cancel, on: :member
        resource :attendance, only: %i[ show update ], controller: "events/attendances"
      end
      namespace :stage do
        resource :hand, only: %i[ create destroy ], controller: "hands"
        resource :stream, only: %i[ create destroy ], controller: "streams"
        patch "roles/:membership_id", to: "roles#update", as: :role
      end
      resource :huddle, only: %i[ show create ] do
        get :participants
      end
      resource :refresh, only: :show
      resource :settings, only: :show
      resource :involvement, only: %i[ show update ]
      resources :github_subscriptions, only: %i[ create update destroy ]
    end

    namespace :github do
      resources :pull_request_threads, only: :create
      resources :pull_request_comments, only: :create
      resources :pull_request_reviews, only: :create
      resources :pull_request_review_requests, only: :create
      resources :pull_request_write_actions, only: :show
    end

    # Per-viewer card frame for private-repository PRs. Served from the
    # Rooms::Github namespace (room-membership scoped) rather than the
    # shared Github namespace above, because the response differs per
    # viewer while the surrounding message HTML is cached across viewers.
    get "github/pull_requests/:id/card", to: "rooms/github/pull_request_cards#show", as: :github_pull_request_card

    get "@:message_id", to: "rooms#show", as: :at_message
  end

  namespace :rooms do
    resources :opens
    resources :closeds
    resources :directs
    resources :voices
    resources :stages
    resources :boards
  end

  resources :messages do
    resources :forwards, controller: "message_forwards", only: :create
    get :forward_source, on: :member, controller: "message_forward_sources"
    get "forwards/destinations", to: "message_forwards#destinations", as: :forward_destinations

    scope module: "messages" do
      resources :boosts
    end
  end

  resources :searches, only: %i[ index create ] do
    delete :clear, on: :collection
  end

  resources :activity_items, path: "activity", only: :index do
    get :unread_count, on: :collection
    post :open, on: :member
    patch :read, on: :member
    patch :handled, on: :member
  end

  resources :work_threads, path: "work", only: :index

  get "threads/:thread_id/work/links", to: "threads/work/links#index", as: :thread_work_links
  post "threads/:thread_id/work/links", to: "threads/work/links#create"
  delete "threads/:thread_id/work/links/:id", to: "threads/work/links#destroy", as: :thread_work_link

  resource :unfurl_link, only: :create

  namespace :github do
    post "webhooks", to: "webhooks#create"
    resource :connection, only: %i[ create destroy ], controller: "connections"
  end

  namespace :google do
    post "connect", to: "connections#connect"
    get "callback", to: "connections#callback"
    delete "connection", to: "connections#destroy"
    get "drive/files", to: "drive_files#index", as: :drive_files
    get "drive/files/:id", to: "drive_files#show", as: :drive_file
  end

  get "webmanifest"    => "pwa#manifest"
  get "service-worker" => "pwa#service_worker"

  get "up" => "rails/health#show", as: :rails_health_check
end
