# frozen_string_literal: false

require "net/http"
require "uri"
require "json"
require "openssl"
require "base64"
require "tempfile"
require "securerandom"
require "stringio"

OPEN_TIMEOUT_SEC = 10
READ_TIMEOUT_SEC = OPEN_TIMEOUT_SEC * 12
RETRY_MAX_COUNT = 10
RETRY_WAIT_TIME_SEC = 1
IMAGE_READ_TIMEOUT_SEC = OPEN_TIMEOUT_SEC * 36

# Utility: Get MIME type from file extension

def get_mime_type(filepath)
  case File.extname(filepath).downcase
  when ".jpg", ".jpeg"
    "image/jpeg"
  when ".png"
    "image/png"
  when ".webp"
    "image/webp"
  when ".gif"
    "image/gif"
  else
    "application/octet-stream"
  end
end

# Utility: Resize and base64-encode image for OpenAI API (reference: openai_chat_streaming.rb)

def get_base64(image_path, max_dimension)
  mime_type = get_mime_type(image_path)
  if mime_type == "application/pdf"
    return Base64.strict_encode64(File.open(image_path, "rb").read)
  end

  output = `sips -g pixelWidth -g pixelHeight '#{image_path}'`
  width = output.match(/pixelWidth: (\d+)/)[1].to_f
  height = output.match(/pixelHeight: (\d+)/)[1].to_f
  aspect_ratio = width / height

  if aspect_ratio >= 1
    new_width = [2000, max_dimension].min
    new_height = (new_width / aspect_ratio).round
  else
    new_height = [768, max_dimension].min
    new_width = (new_height * aspect_ratio).round
  end

  if new_width > new_height && new_height > 768
    new_height = 768
    new_width = (new_height * aspect_ratio).round
  elsif new_height > new_width && new_width > 2000
    new_width = 2000
    new_height = (new_width / aspect_ratio).round
  end

  base64_data = ""
  if width > new_width || height > new_height
    tempfile_path = File.join(File.dirname(image_path), "#{SecureRandom.uuid}#{File.extname(image_path)}")
    command = "/usr/bin/sips -z #{new_height} #{new_width} '#{image_path}' --out '#{tempfile_path}' > /dev/null 2>&1"
    system(command)
    base64_data = Base64.strict_encode64(File.open(tempfile_path, "rb").read)
    File.delete tempfile_path
  else
    base64_data = Base64.strict_encode64(File.open(image_path, "rb").read)
  end
  base64_data
end

def parse(json)
  res = JSON.parse(json)
  if res["error"]
    print "❗️ ERROR: ##{res["error"]["message"]}"
    exit 1
  elsif res["choices"]
    choices = res["choices"]
    choices[0]
  elsif res["data"]
    res["data"]
  end
end

def send_query(apikey:, query:, timeout_sec:, api_base: "https://api.openai.com/v1", debug: false, endpoint: "images/generations")
  api_base = api_base[0...-1] if api_base[-1] == "/"
  target_uri = "#{api_base}/#{endpoint}"

  begin
    uri = URI.parse(target_uri)

    headers = {
      "Content-Type" => "application/json",
      "Authorization" => "Bearer #{apikey}"
    }

    req = Net::HTTP::Post.new(uri, headers)
    req.body = query.to_json

    req_options = {
      use_ssl: uri.scheme == "https",
      open_timeout: OPEN_TIMEOUT_SEC,
      read_timeout: timeout_sec
    }

    res = nil
    retry_count = 0
    Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(req) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          puts "❗️ ERROR: #{response.code} #{response.message}"
          begin
            error_details = JSON.parse(response.body)
            puts "Error Code: #{error_details["error"]["code"]}"
            puts "Error Message: #{error_details["error"]["message"]}"
          rescue JSON::ParserError
            puts "Raw response body:"
            pp response.body.to_s
          end
          pp req.body
          exit 1
        end
        res = parse(response.body)
      end
    end
  rescue Net::ReadTimeout, Net::OpenTimeout => e
    if retry_count < RETRY_MAX_COUNT
      sleep RETRY_WAIT_TIME_SEC
      retry_count += 1
      retry
    else
      pp e.backtrace
      pp e.message
      puts "❗️ ERROR: API call timeout"
      exit 1
    end
  end
  res
rescue StandardError => e
  if debug
    debug_print = <<~DEBUG
      ❗️ ERROR: something went wrong"
      #{e.message}
      #{e.backtrace.join("\n")}
      Target URI: #{target_uri}
      Query: "
      #{query}
    DEBUG
    puts debug_print
  else
    puts "❗️ ERROR: something went wrong"
  end
end

# Multipart form for image edit (for gpt-image-1 and dall-e-2)

def send_multipart_query(apikey:, params:, timeout_sec:, api_base: "https://api.openai.com/v1", debug: false, endpoint: "images/edits")
  api_base = api_base[0...-1] if api_base[-1] == "/"
  target_uri = "#{api_base}/#{endpoint}"

  begin
    uri = URI.parse(target_uri)
    boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
    req["Authorization"] = "Bearer #{apikey}"

    # Use StringIO for safe binary/text concatenation

    body_io = StringIO.new

    # Add image file(s)

    if params[:image]
      images = params[:image].is_a?(Array) ? params[:image] : [params[:image]]
      images.each_with_index do |img, idx|
        if img.is_a?(String) && img.start_with?("data:")
          image_data = img.split(",", 2)[1]
          format = img.match(/data:image\/(\w+);/)[1] || "png"
          image_binary = Base64.decode64(image_data)
          mime_type = get_mime_type("dummy.#{format}")
          filename = "image#{images.size > 1 ? "_#{idx}" : ""}.#{format}"
          body_io.write "--#{boundary}\r\n"
          body_io.write "Content-Disposition: form-data; name=\"image#{images.size > 1 ? "[]" : ""}\"; filename=\"#{filename}\"\r\n"
          body_io.write "Content-Type: #{mime_type}\r\n\r\n"
          body_io.write image_binary
          body_io.write "\r\n"
        elsif File.exist?(img)
          format = File.extname(img).delete(".")
          mime_type = get_mime_type(img)
          filename = File.basename(img)
          file_data = File.binread(img)
          body_io.write "--#{boundary}\r\n"
          body_io.write "Content-Disposition: form-data; name=\"image#{images.size > 1 ? "[]" : ""}\"; filename=\"#{filename}\"\r\n"
          body_io.write "Content-Type: #{mime_type}\r\n\r\n"
          body_io.write file_data
          body_io.write "\r\n"
        end
      end
    end

    # Add mask if present

    if params[:mask]
      mask = params[:mask]
      if mask.is_a?(String) && mask.start_with?("data:")
        mask_data = mask.split(",", 2)[1]
        format = mask.match(/data:image\/(\w+);/)[1] || "png"
        mask_binary = Base64.decode64(mask_data)
        mime_type = get_mime_type("dummy.#{format}")
        filename = "mask.#{format}"
        body_io.write "--#{boundary}\r\n"
        body_io.write "Content-Disposition: form-data; name=\"mask\"; filename=\"#{filename}\"\r\n"
        body_io.write "Content-Type: #{mime_type}\r\n\r\n"
        body_io.write mask_binary
        body_io.write "\r\n"
      elsif File.exist?(mask)
        format = File.extname(mask).delete(".")
        mime_type = get_mime_type(mask)
        filename = File.basename(mask)
        file_data = File.binread(mask)
        body_io.write "--#{boundary}\r\n"
        body_io.write "Content-Disposition: form-data; name=\"mask\"; filename=\"#{filename}\"\r\n"
        body_io.write "Content-Type: #{mime_type}\r\n\r\n"
        body_io.write file_data
        body_io.write "\r\n"
      end
    end

    # Add prompt

    body_io.write "--#{boundary}\r\n"
    body_io.write "Content-Disposition: form-data; name=\"prompt\"\r\n\r\n"
    body_io.write params[:prompt].to_s
    body_io.write "\r\n"

    # Add other parameters

    params.each do |key, value|
      next if [:image, :prompt, :mask].include?(key)
      body_io.write "--#{boundary}\r\n"
      body_io.write "Content-Disposition: form-data; name=\"#{key}\"\r\n\r\n"
      body_io.write value.to_s
      body_io.write "\r\n"
    end

    body_io.write "--#{boundary}--\r\n"
    body_io.rewind
    req.body = body_io.read

    req_options = {
      use_ssl: uri.scheme == "https",
      open_timeout: OPEN_TIMEOUT_SEC,
      read_timeout: timeout_sec
    }

    res = nil
    retry_count = 0
    Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
      http.request(req) do |response|
        unless response.is_a?(Net::HTTPSuccess)
          puts "❗️ ERROR: #{response.code} #{response.message}"
          begin
            error_details = JSON.parse(response.body)
            puts "Error Code: #{error_details["error"]["code"]}"
            puts "Error Message: #{error_details["error"]["message"]}"
          rescue JSON::ParserError
            puts "Raw response body:"
            pp response.body.to_s
          end
          pp params
          exit 1
        end
        res = parse(response.body)
      end
    end
  rescue Net::ReadTimeout, Net::OpenTimeout => e
    if retry_count < RETRY_MAX_COUNT
      sleep RETRY_WAIT_TIME_SEC
      retry_count += 1
      retry
    else
      pp e.backtrace
      pp e.message
      puts "❗️ ERROR: API call timeout"
      exit 1
    end
  end
  res
rescue StandardError => e
  if debug
    debug_print = <<~DEBUG
      ❗️ ERROR: something went wrong"
      #{e.message}
      #{e.backtrace.join("\n")}
      Target URI: #{target_uri}
      Params: "
      #{params}
    DEBUG
    puts debug_print
  else
    puts "❗️ ERROR: something went wrong"
  end
end

def generate_image(text:, apikey:, model:, max_characters:,
                   image_size:, debug:, api_base:,
                   timeout_sec: OPEN_TIMEOUT_SEC * 36,
                   num_images: nil, quality: nil, style: nil,
                   moderation: nil, background: nil,
                   silent: false, streaming: false, source_image: nil, mask: nil)

  IO.popen("pbcopy", "w") { |f| f << text }

  if apikey.to_s == ""
    print "❗️ ERROR: API key is not set"
    exit 1
  end

  if text == ""
    print "❗️ ERROR: Input text is empty"
    exit 1
  end

  text              = text.gsub(/%2B/, "+")
  max_characters    = max_characters.to_i
  timeout_sec       = timeout_sec.to_s == "" ? IMAGE_READ_TIMEOUT_SEC : timeout_sec.to_i * 20
  debug             = /(?:1|true|enable)/i =~ debug.to_s
  streaming         = /(?:1|true|on|enable)/i.match? streaming.to_s
  num_images        = num_images ? num_images.to_i : 1
  style            ||= "vivid"
  quality          ||= "auto"
  moderation       ||= "auto"

  if text.length > max_characters.to_i
    print "❗️ ERROR: Input text contains #{text.length} characters; max number of characters is set to #{max_characters}"
    exit 1
  elsif /\A\s*\z/ =~ text
    print "❗️ ERROR: Input text is empty"
    exit 1
  end

  # If source_image is given, use image edit API

  if source_image
    # Prepare image(s) for API

    images = []
    if source_image.is_a?(Array)
      images = source_image
    else
      images = [source_image]
    end

    # Convert file path to base64 data URL if needed and check size/format

    images = images.map do |img|
      if img.is_a?(String) && File.exist?(img)
        # Check file size and resize if needed

        max_dim = model == "gpt-image-1" ? 2000 : 1024
        base64 = get_base64(img, max_dim)
        mime_type = get_mime_type(img)
        "data:#{mime_type};base64,#{base64}"
      else
        img # Assume already base64 data URL
      end
    end

    # Prepare parameters for each model

    params = {
      prompt: text,
      n: num_images,
      size: image_size,
      quality: quality
    }
    params[:image] = model == "gpt-image-1" ? images : images.first
    params[:model] = model if model
    params[:background] = background if model == "gpt-image-1" && background
    params[:moderation] = moderation if model == "gpt-image-1" && moderation
    params[:style] = style if model == "dall-e-3"
    params[:response_format] = "b64_json" if model != "gpt-image-1"
    params[:mask] = mask if mask

    endpoint = "images/edits"
    res = send_multipart_query(
      apikey: apikey,
      params: params,
      timeout_sec: timeout_sec,
      api_base: api_base,
      debug: debug,
      endpoint: endpoint
    )
  else
    # Use the regular image generation API

    query = case model
            when "gpt-image-1"
              {
                "model" => "gpt-image-1",
                "prompt" => text,
                "size" => image_size,
                "quality" => quality,
                "moderation" => moderation,
                "background" => background
              }
            when "dall-e-3"
              {
                "model" => "dall-e-3",
                "prompt" => text,
                "size" => image_size,
                "quality" => quality,
                "style" => style,
                "response_format" => "b64_json"
              }
            when "dall-e-2"
              {
                "model" => "dall-e-2",
                "prompt" => text,
                "n" => num_images,
                "size" => image_size,
                "response_format" => "b64_json"
              }
            end

    res = send_query(apikey: apikey, query: query, timeout_sec: timeout_sec, api_base: api_base, debug: debug)
  end

  if res.nil? || res.empty?
    print "❗️ ERROR: Response is empty: Review your settings and prompt"
    exit 1
  end

  text = model == "dall-e-3" ? res.map { |item| item["revised_prompt"] }.join("\n\n") : text

  # Save images to workflow cache folder and collect file paths

  workflow_cache = ENV["alfred_workflow_cache"] || File.expand_path("~/Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/openai-chat-api-workflow")
  Dir.mkdir(workflow_cache) unless Dir.exist?(workflow_cache)

  # Clean up old images (optional)

  if ENV["clean_images"] != "false"
    Dir.glob(File.join(workflow_cache, "openai_image_*.png")).each do |old_image|
      File.delete(old_image) if File.exist?(old_image)
    end
  end

  file_paths = []
  web_paths = []

  timestamp = Time.now.strftime("%Y%m%d%H%M%S")
  res.each_with_index do |item, index|
    filename = "openai_image_#{timestamp}_#{index}.png"
    filepath = File.join(workflow_cache, filename)
    web_path = "http://#{ENV["loopback"] || "127.0.0.1"}:#{ENV["http_port"] || "8090"}/images/#{filename}"

    if item["b64_json"]
      image_data = Base64.decode64(item["b64_json"])
      File.open(filepath, "wb") do |file|
        file.write(image_data)
      end
      file_paths << filepath
      web_paths << web_path
    elsif item["url"]
      uri = URI.parse(item["url"])
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      request = Net::HTTP::Get.new(uri.request_uri)
      response = http.request(request)
      if response.code == "200"
        File.open(filepath, "wb") do |file|
          file.write(response.body)
        end
        file_paths << filepath
        web_paths << web_path
      else
        file_paths << item["url"]
        web_paths << item["url"]
      end
    end
  end

  output = "#{text}\n\n#{file_paths.zip(web_paths).map { |fp, wp| "#{fp}\n#{wp}" }.join("\n\n")}"

  if silent
    output
  else
    IO.popen("pbcopy", "w") { |f| f << output }
    if streaming
      image_tags = web_paths.map { |path| "![](#{path})" }.join(" ")
      output = "<div class='message user'><pre>#{text}</pre></div><div class='message assistant'><p>Click to enlarge</p>#{image_tags}</div>"
    end
    puts output
  end
end
