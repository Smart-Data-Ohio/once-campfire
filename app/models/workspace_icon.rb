class WorkspaceIcon < ApplicationRecord
  belongs_to :creator, class_name: "User"

  has_one_attached :image

  NAME_PATTERN = /\A[a-z0-9_]{2,32}\z/
  ACCEPTED_CONTENT_TYPES = %w[ image/png image/svg+xml ].freeze
  SVG_CONTENT_TYPE = "image/svg+xml"
  PNG_CONTENT_TYPE = "image/png"
  MAX_BYTES = 256.kilobytes
  PNG_MIN_DIMENSION = 64
  SVG_NAMESPACE = "http://www.w3.org/2000/svg"

  normalizes :name, with: ->(name) { name.to_s.strip.downcase }

  validates :name, presence: true, format: { with: NAME_PATTERN }, uniqueness: { case_sensitive: false }
  validates :title, presence: true, length: { in: 1..60 }
  validate :name_not_colliding_with_builtin
  validate :image_requirements
  validate :image_content_requirements

  after_save :expire_icons_cache
  after_destroy :expire_icons_cache

  scope :ordered, -> { order(:name) }

  def svg?
    image.attached? && image.blob.content_type == SVG_CONTENT_TYPE
  end

  private
    # Built-in brand names and aliases are reserved; gemoji aliases may be
    # shadowed, exactly like brands do.
    def name_not_colliding_with_builtin
      if name.present? && Icons.brand?(name)
        errors.add :name, "is already taken by a built-in icon"
      end
    end

    def image_requirements
      unless image.attached?
        errors.add :image, "must be attached"
        return
      end

      unless image.blob.content_type.in?(ACCEPTED_CONTENT_TYPES)
        errors.add :image, "must be an SVG or PNG"
      end

      if image.blob.byte_size > MAX_BYTES
        errors.add :image, "must be smaller than 256 KB"
      end
    end

    def image_content_requirements
      return unless image.attached? && image.blob.content_type.in?(ACCEPTED_CONTENT_TYPES)

      data = attached_file_bytes

      if data.blank?
        errors.add(:image, "could not be read")
      elsif svg?
        validate_svg_safety(data)
      else
        validate_png_dimensions(data)
      end
    end

    # Uploads stay staged until save, so a new record has no service file to
    # download yet; read the staged upload instead. The IO is rewound after
    # reading so the later upload still sees the whole file.
    def attached_file_bytes
      return image.blob.download if image.blob.service.exist?(image.blob.key)

      io = staged_upload_io
      return if io.nil?

      io.rewind if io.respond_to?(:rewind)
      io.read.tap { io.rewind if io.respond_to?(:rewind) }
    end

    def staged_upload_io
      attachable = attachment_changes["image"]&.attachable

      case attachable
      when Hash
        attachable[:io] || attachable["io"]
      when ActionDispatch::Http::UploadedFile
        attachable.open
      when File, StringIO
        attachable
      when Pathname
        attachable.open
      else
        if defined?(Rack::Test::UploadedFile) && attachable.is_a?(Rack::Test::UploadedFile)
          attachable.respond_to?(:open) ? attachable.open : attachable
        end
      end
    end

    # SVGs are rejected, never cleaned. Anything matching a rejection rule in
    # docs/icons.md fails validation. Served icons additionally carry a
    # script-blocking Content-Security-Policy (see WorkspaceIconsController).
    def validate_svg_safety(svg)
      if svg.match?(/<!DOCTYPE\b|<!ENTITY\b/i)
        errors.add(:image, "must not contain a DOCTYPE or entities")
        return
      end

      doc = Nokogiri::XML(svg) { |config| config.strict }

      unless doc.root&.name&.downcase == "svg"
        errors.add(:image, "is not a valid SVG")
        return
      end

      doc.traverse do |node|
        next unless node.element?

        tag = node.name.to_s.split(":").last.downcase

        if tag.in?(%w[ script foreignobject image ])
          errors.add(:image, "must not contain #{tag} elements")
          return
        end

        if tag == "style" && node.text.match?(/url\(/i)
          errors.add(:image, "must not contain url() styles")
          return
        end

        if tag == "svg" && node != doc.root && (namespace = node.namespace) && namespace.href != SVG_NAMESPACE
          errors.add(:image, "must not nest svg elements from another namespace")
          return
        end

        node.attribute_nodes.each do |attribute|
          local = attribute.name.to_s.split(":").last.downcase

          if attribute.name.to_s.downcase.start_with?("on") || local.start_with?("on")
            errors.add(:image, "must not contain event handler attributes")
            return
          end

          if local == "href" && !attribute.value.to_s.strip.start_with?("#")
            errors.add(:image, "must not contain external references")
            return
          end

          if local == "style" && attribute.value.to_s.match?(/url\(/i)
            errors.add(:image, "must not contain url() styles")
            return
          end
        end
      end
    rescue Nokogiri::XML::SyntaxError
      errors.add :image, "is not a valid SVG"
    end

    # Read through the same libvips stack Active Storage uses for avatars.
    # Blob analysis cannot run yet because the upload is still staged.
    def validate_png_dimensions(data)
      image = Vips::Image.new_from_buffer(data, "")

      if image.width != image.height
        errors.add :image, "must be square"
      elsif image.width < PNG_MIN_DIMENSION
        errors.add :image, "must be at least 64 pixels wide and tall"
      end
    rescue Vips::Error
      errors.add :image, "could not be read"
    end

    def expire_icons_cache
      Icons.expire_custom_cache!
    end
end
