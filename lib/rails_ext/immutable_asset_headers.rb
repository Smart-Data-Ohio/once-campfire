# frozen_string_literal: true

require "active_support/core_ext/integer/time"

module RailsExt
  # Marks digest-stamped asset responses immutable.
  #
  # This cannot be expressed through config.public_file_server.headers, because
  # those are emitted verbatim: ActionDispatch::FileHandler hands them straight
  # to Rack::Files, whose #serving does `headers.merge!(@headers)`. Nothing
  # evaluates a callable, so a lambda there is written into the response as
  # "cache-control: #<Proc:0x... /rails/config/environments/production.rb>",
  # which drops caching entirely, leaks the container path, and leaves Thruster
  # unable to store the response. Static file headers must be literal strings,
  # so a path-dependent policy has to be applied out here instead.
  #
  # Insert this *before* ActionDispatch::Static so that it wraps it and sees the
  # response on the way back out. Inserting it after would never run for a
  # served file: Static short-circuits on a hit and never calls downstream.
  class ImmutableAssetHeaders
    ASSET_PREFIX = "/assets/"
    # Propshaft digest-stamps these URLs, so the bytes behind a given URL can
    # never change: a client that has one never needs to revalidate it.
    IMMUTABLE_CACHE_CONTROL = "public, immutable, max-age=#{1.year.to_i}"
    # Only a real hit from the static file server is safe to mark immutable. An
    # unknown /assets/ path falls through to the app's 404, which must stay
    # correctable.
    CACHEABLE_STATUSES = [ 200, 304 ].freeze

    def initialize(app, cache_control: IMMUTABLE_CACHE_CONTROL)
      @app = app
      @cache_control = cache_control
    end

    def call(env)
      @app.call(env).tap do |status, headers, _body|
        if asset_path?(env) && CACHEABLE_STATUSES.include?(status)
          headers["cache-control"] = @cache_control
        end
      end
    end

    private
      def asset_path?(env)
        env["PATH_INFO"].to_s.start_with?(ASSET_PREFIX)
      end
  end
end
