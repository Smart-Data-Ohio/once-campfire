module TimeHelper
  def local_datetime_tag(datetime, style: :time, **attributes, &block)
    content = block ? capture(&block) : nil
    tag.time content, **attributes, datetime: datetime.iso8601, data: { local_time_target: style }
  end
end
