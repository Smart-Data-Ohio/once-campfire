module Google
  module SignIn
    # Resolves verified Google claims to a Campfire user. The immutable
    # Google subject wins: an existing GoogleIdentity signs in its user
    # even across email changes. First login links (or provisions) by
    # the verified email; later logins never consult the email for an
    # already-linked subject. Never reactivates, recreates, or
    # provisions privileged accounts. Raises Rejected on any mismatch.
    class AccountLinker
      # Marker User#deactivate splices into the email local part, as in
      # "jane-deactivated-<uuid>@example.com".
      DEACTIVATED_MARKER = "-deactivated-"

      class << self
        def resolve!(claims)
          subject = claims["sub"].to_s
          email = claims["email"].to_s.strip
          domain = claims["hd"].to_s.strip.downcase
          raise Rejected, :bad_token if subject.blank? || email.blank?

          if (identity = GoogleIdentity.find_by(subject:))
            user = identity.user
            ensure_eligible!(user)
            identity.update!(email:, domain:) if identity.email != email || identity.domain != domain
            return user
          end

          link_or_provision!(subject:, email:, domain:, claims:)
        rescue ActiveRecord::RecordNotUnique
          # Lost a creation race: whoever won owns the subject now, so
          # re-resolve by subject once instead of duplicating the user.
          identity = GoogleIdentity.find_by(subject: claims["sub"].to_s)
          if identity
            ensure_eligible!(identity.user)
            return identity.user
          end
          raise Rejected, :retry
        end

        private
          def link_or_provision!(subject:, email:, domain:, claims:)
            matches = User.where("LOWER(email_address) = ?", email.downcase).to_a
            raise Rejected, :ambiguous if matches.many?

            if (user = matches.first)
              ensure_eligible!(user)
              if user.google_identity && user.google_identity.subject != subject
                raise Rejected, :subject_mismatch
              end
              GoogleIdentity.create!(user:, subject:, email:, domain:)
              return user
            end

            raise Rejected, :deactivated if deactivated_predecessor?(email)

            User.transaction do
              user = User.create!(
                name: display_name(claims, email),
                email_address: email,
                password: nil,
                role: :member
              )
              GoogleIdentity.create!(user:, subject:, email:, domain:)
              user
            end
          end

          # Only active humans sign in through Google. Bots, agent
          # users, deactivated, and banned users are rejected -- and a
          # deactivated account is never revived by signing in.
          def ensure_eligible!(user)
            if user.nil? || user.deactivated?
              raise Rejected, :deactivated
            elsif user.banned?
              raise Rejected, :banned
            elsif !user.active? || user.bot? || user.agent.present?
              raise Rejected, :ineligible
            end
          end

          # A deactivated user keeps a rewritten email, so the lookup
          # above cannot see them -- but signing in must not recreate
          # their account either. Match the rewrite pattern to refuse.
          def deactivated_predecessor?(email)
            local, _, domain = email.partition("@")
            return false if local.blank? || domain.blank?

            pattern = "#{sanitize_like(local.downcase)}#{DEACTIVATED_MARKER}%@#{sanitize_like(domain.downcase)}"
            User.deactivated.where("LOWER(email_address) LIKE ? ESCAPE '\\'", pattern).exists?
          end

          def sanitize_like(term)
            term.gsub(/[\\%_]/) { |char| "\\#{char}" }
          end

          def display_name(claims, email)
            claims["name"].to_s.strip.presence ||
              [ claims["given_name"], claims["family_name"] ].map(&:to_s).map(&:strip).compact_blank.join(" ").presence ||
              email.split("@").first
          end
      end
    end
  end
end
