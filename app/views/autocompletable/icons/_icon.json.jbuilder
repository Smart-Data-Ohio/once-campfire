json.name icon.name
json.title icon.title
json.kind icon.kind
json.value "#{icon.kind}:#{icon.name}"

if icon.brand?
  json.image image_path(icon.logical_asset_path)
else
  json.character icon.character
end
