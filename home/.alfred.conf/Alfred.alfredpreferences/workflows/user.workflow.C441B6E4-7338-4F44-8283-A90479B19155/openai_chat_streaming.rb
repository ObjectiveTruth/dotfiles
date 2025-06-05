# frozen_string_literal: false

require "base64"
require "net/http"
require "uri"
require "json"
require "socket"
require "openssl"
require "strscan"
require "securerandom"
require_relative "./openai_chat_functions"

CLIENT_TIMEOUT_SEC = 60
OPEN_TIMEOUT_SEC = 30
READ_TIMEOUT_SEC = OPEN_TIMEOUT_SEC * 24
RETRY_MAX_COUNT = 5
RETRY_WAIT_TIME_SEC = 1

DEFAULT_SYSTEM_CONTENT = <<~SYSTEM_CONTENT
  You are a friendly but professional consultant who answers various questions, write computer program code, make decent suggestions, give helpful advice in response to a prompt from the user. Your response must be concise, suggestive, and accurate.
SYSTEM_CONTENT

REASONING_MODELS = [
  "o1-2024-12-17",
  "o1",
  "o3-mini-2025-01-31",
  "o3-mini",
  "o3-2025-04-16",
  "o3",
  "o4-mini-2025-04-1",
  "o4-mini"
]

NON_IMAGE_MODELS = [
  "o3-mini-2025-01-31",
  "o3-mini",
  "o1-mini-2024-09-12",
  "o1-mini"
]

NON_STREAMING_MODELS = []

def sanitize_data(data)
  return data.encode("UTF-8", invalid: :replace, undef: :replace, replace: "") if data.is_a? String

  if data.is_a? Hash
    data.each do |key, value|
      data[key] = sanitize_data(value)
    end
  elsif data.is_a? Array
    data.map! do |value|
      sanitize_data(value)
    end
  end

  data
end

def parse(json)
  res = JSON.parse(json)
  if res["error"]
    print "❗️ ERROR: ##{res["error"]["message"]}"
    exit 1
  elsif res["choices"]
    choices = res["choices"]
    choices[0]
  else
    res["data"]
  end
end

def send_frame(socket, message)
  frame = [0x81] # FIN = 1 and opcode = 0x1 for text data

  length = message.bytesize
  if length <= 125
    frame << length
  elsif length < 2**16
    frame << 126
    frame.concat([length].pack("n").bytes)
  else
    frame << 127
    frame.concat([length].pack("Q>").bytes)
  end

  frame.concat(message.bytes)
  socket.write(frame.pack("C*"))
rescue StandardError
  # do nothing
  exit 1
end

def get_mime_type(filepath)
  case filepath
  when /\.(?:pdf)\z/
    "application/pdf"
  when /\.(?:jpg|jpeg)\z/
    "image/jpeg"
  when /\.(?:png)\z/
    "image/png"
  when /\.(?:gif)\z/
    "image/gif"
  else
    "image"
  end
end

def get_base64(image_path, max_dimension)
  mime_type = get_mime_type(image_path)
  
  # For PDF files, return direct Base64 encoded data without resizing

  if mime_type == "application/pdf"
    return Base64.strict_encode64(File.open(image_path, "rb").read)
  end

  # For image files, proceed with resize processing

  output = `sips -g pixelWidth -g pixelHeight '#{image_path}'`
  width = output.match(/pixelWidth: (\d+)/)[1].to_f
  height = output.match(/pixelHeight: (\d+)/)[1].to_f

  # Calculate the aspect ratio

  aspect_ratio = width.to_f / height.to_f

  # Determine the new dimensions while preserving the aspect ratio

  if aspect_ratio >= 1
    # Width is the long side

    new_width = [2000, max_dimension].min
    new_height = (new_width / aspect_ratio).round
  else
    # Height is the long side

    new_height = [768, max_dimension].min
    new_width = (new_height * aspect_ratio).round
  end

  # Ensure the short side does not exceed its limit

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

def contains_image_type?(messages)
  messages.any? do |element|
    if element.is_a?(Hash)
      element["type"] == "image_url" || contains_image_type?(element.values)
    elsif element.is_a?(Array)
      contains_image_type?(element)
    else
      false
    end
  end
end

def send_query(apikey:, mode:, query:, timeout_sec:,
               system_content: DEFAULT_SYSTEM_CONTENT, image: nil,
               api_base: "https://api.openai.com/v1", debug: false,
               memory_span: 4, data_path: nil, streaming: false,
               search_model: "gpt-4o-mini-search-preview",
               websocket_port: 8080, image_id: nil, image_name: nil)

  case mode
  when "chat", "vision"
    begin
      if data_path && File.exist?(data_path)
        data = JSON.parse(File.read(data_path))
        raise "data['messages'] is not an array" unless data["messages"].is_a?(Array)
      else
        data = { "messages" => [] }
      end
    rescue StandardError
      data = { "messages" => [] }
    end
  else
    data = { "messages" => [] }
  end

  data = query.merge data

  is_reasoning = REASONING_MODELS.include?(data["model"])
  if is_reasoning
    keys_to_delete = [
      "top_p",
      "presence_penalty",
      "frequency_penalty",
      "temperature"
    ]
    keys_to_delete.each { |key| data.delete(key) }
    data["max_completion_tokens"] = data["max_tokens"]
    data.delete("max_tokens")
  else
    data.delete("reasoning_effort")
  end

  not_streaming = NON_STREAMING_MODELS.include?(data["model"])
  streaming = false if not_streaming

  # Initialize WebSocket server for streaming if required
  wsserver_retry_count = 0
  if streaming
    begin
      server = TCPServer.new(websocket_port.to_i)
      accepted_socket = server.accept
      last_interaction_time = Time.now
    rescue StandardError
      if wsserver_retry_count < RETRY_MAX_COUNT
        sleep RETRY_WAIT_TIME_SEC
        retry
      else
        puts "❗️ ERROR: Failed to start a server"
        exit 1
      end
    end
  end

  # Extract and remove special flags from data
  emoji = data["emoji"] || false
  speak = data["speak"] || false
  data.delete "emoji"
  data.delete "speak"
  data.delete "max_tokens" if data["max_tokens"] && data["max_tokens"].to_i <= 0

  # Prepare API endpoint
  api_base = api_base[0...-1] if api_base[-1] == "/"
  target_uri = "#{api_base}/chat/completions"

  begin
    uri = URI.parse(target_uri)

    # Create a deep copy of data for saving
    data_to_save = Marshal.load(Marshal.dump(data))

    search_mode = false

    # Handle image input if present

    if image
      if NON_IMAGE_MODELS.include?(data["model"])
        data["model"] = "gpt-4.1"
        data.delete "reasoning_effort" 
      end

      if /\.pdf\z/ =~ image_name
        data["messages"] << { "role" => "user", "content" => [
          { "type" => "file",
            "file" => {
              "filename" => image_name,
              "file_data" => image,
            }
          },
          { "type" => "text",  "text" => data["prompt"] }
        ] }

        data_to_save["messages"] << {
          "role" => "user",
          "content" => [
            { "type" => "file",
              "file" => {
                "filename" => image_name,
                "file_data" => image
              }
            },
            { "type" => "text",
              "text" => data["prompt"].gsub(/</, "&lt;").gsub(/>/, "&gt;")
            }
        ] }
      else
        data["messages"] << { "role" => "user", "content" => [
          { "type" => "image_url", "image_url" => { "url": image } },
          { "type" => "text",  "text" => data["prompt"] }
        ] }

        data_to_save["messages"] << { "role" => "user", "content" => [
          { "type" => "image_url", "image_url" => { "url": image } },
          { "type" => "text",  "text" => data["prompt"].gsub(/</, "&lt;").gsub(/>/, "&gt;")}
        ] }
      end
    else
      data["messages"] << { "role" => "user", "content" => [
        { "type" => "text",  "text" => data["prompt"] }
      ] }

      data_to_save["messages"] << { "role" => "user", "content" => [
        { "type" => "text",  "text" => data["prompt"].gsub(/</, "&lt;").gsub(/>/, "&gt;")}
      ] }

      last_message = data["messages"].last
      content_items = last_message["content"]
      text_content = content_items.find { |item| item.key?("text") }&.fetch("text", "")
      search_mode = true if /^[^\w\s]*search/i =~ text_content
    end

    # Handle memory span
    memory_span = 0 if memory_span.negative?

    if memory_span.positive?
      memory_span = data["messages"].size if memory_span > data["messages"].size
      data["messages"] = data["messages"][-memory_span..]
      # Remove "image_id" from all messages
      data["messages"].each do |message|
        message.delete "image_id"
      end
    end

    data.delete "prompt"
    data_to_save.delete "prompt"

    if data["messages"].size > 1
      # This must be system message
      system_message = data["messages"].shift
      system_content = system_message["content"]
    end

    system_content += "\n\nAdd emojis that are appropriate to the content of the response." if emoji

    if search_mode
      data["model"] = search_model
      data.delete("frequency_penalty")
      data.delete("presence_penalty")
      data.delete("temperature")
      data.delete("top_p")
      data["messages"].unshift({
        "role" => "system",
        "content" => "Avoid using <h2> tags (`## ` in markdown). Use <h3> tags (`### ` in markdown) instead."
      })
    elsif is_reasoning      
      data["messages"].unshift({
        "role" => "developer",
        "content" => "Formatting re-enabled\n---\n" + system_content
      })
    else
      data["messages"].unshift({
        "role" => "system",
        "content" => system_content
      })
    end

    # Set appropriate model for image content
    if contains_image_type?(data["messages"]) && NON_IMAGE_MODELS.include?(data["model"])
      data["model"] = "gpt-4.1" 
      data.delete "reasoning_effort"
    end

    # Prepare request headers
    headers = {
      "Content-Type" => "application/json",
      "Authorization" => "Bearer #{apikey}"
    }

    if streaming
      headers["Accept"] = "text/event-stream"
      data["stream"] = true
    else
      data.delete("stream")
    end

    # Prepare HTTP request
    req = Net::HTTP::Post.new(uri, headers)
    req.body = data.to_json

    req_options = {
      use_ssl: uri.scheme == "https",
      open_timeout: OPEN_TIMEOUT_SEC,
      read_timeout: streaming ? timeout_sec : READ_TIMEOUT_SEC
    }

    content = ""
    res = nil

    # Make API request with retry logic
    retry_count = 0
    begin
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

          snippet = nil
          headers = {}
          ready = false

          # Handle WebSocket streaming
          if streaming
            max_wait_seconds = 180
            remaining_wait_time = max_wait_seconds * 10

            loop do
              break if accepted_socket || remaining_wait_time.negative?
              sleep 0.4
              remaining_wait_time -= 5
            end

            if accepted_socket
              if Time.now - last_interaction_time > CLIENT_TIMEOUT_SEC
                puts "❗️ ERROR: Client timed out"
                accepted_socket.close
                break
              end

              ready = true
              while (line = accepted_socket.gets) && !line.chomp.empty?
                headers[line.split(":")[0]] = line.split(":")[1].strip if line.include?(":")
              end

              if headers["Upgrade"] == "websocket"
                client_key = headers["Sec-WebSocket-Key"]
                magic_string = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
                accept_key = Digest::SHA1.base64digest("#{client_key}#{magic_string}")

                accepted_socket.puts "HTTP/1.1 101 Switching Protocols\r\n" \
                  "Upgrade: websocket\r\n" \
                  "Connection: Upgrade\r\n" \
                  "Sec-WebSocket-Accept: #{accept_key}\r\n\r\n"
              end

              last_interaction_time = Time.now
            end
          end

          if streaming
            # Process streaming response
            buffer = ""
            response.read_body do |chunk|
              chunk = chunk.force_encoding("UTF-8")
              buffer << chunk

              if chunk.valid_encoding? == false
                next 
              end

              begin
                break if /\Rdata: [DONE]\R/ =~ buffer
              rescue
                next
              end

              buffer.encode!("UTF-16", "UTF-8", invalid: :replace, replace: "")
              buffer.encode!("UTF-8", "UTF-16")

              scanner = StringScanner.new(buffer)
              pattern = /data: (\{.*?\})(?=\n|\z)/m

              until scanner.eos?
                matched = scanner.scan_until(pattern)
                if matched
                  json_data = matched.match(pattern)[1]

                  begin
                    res = JSON.parse(json_data)
                    choice = res.dig("choices", 0) || {}
                    snippet = choice.dig("delta", "content").to_s
                    next if !snippet || snippet == ""

                    snippet.split(//).each do |char|
                      send_frame(accepted_socket, char) if ready
                      sleep 0.01
                    end

                    content << snippet

                    if choice["finish_reason"] == "length" || choice["finish_reason"] == "stop"
                      send_frame(accepted_socket, "END_OF_STREAM") if ready
                      break
                    end
                  rescue JSON::ParserError => e
                    # Continue to next iteration if JSON parsing fails
                  end
                else
                  buffer = scanner.rest
                  break
                end
              end
            end

          else
            response_body = response.body
            begin
              parsed_response = JSON.parse(response_body)
              content = parsed_response.dig("choices", 0, "message", "content").to_s

            rescue JSON::ParserError => e
              puts "❗️ ERROR: Failed to parse response"
              puts e.message if debug
              content = ""
            end
          end

          res = content
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

    # Save conversation history if data_path is provided
    if data_path
      if image
        data_to_save["messages"].last["image_id"] = image_id
      end

      data_to_save["messages"] << { "role" => "assistant", "content" => content }
      data_to_save["emoji"] = emoji
      data_to_save["speak"] = speak
      if data_to_save["messages"].first["role"] != "system"
        system_message = { "role" => "system", "content" => system_content }
        data_to_save["messages"].unshift(system_message)
      end

      File.write(data_path, JSON.generate(sanitize_data(data_to_save)))
    end

    # Clean up WebSocket connections
    if streaming
      accepted_socket&.close
      server&.close
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

    if streaming
      accepted_socket&.close
      server&.close
    end
  end
end

def base64url_to_base64(base64url)
  base64url.tr('-_', '+/')
end

def text_query(mode:, text:, apikey:, model:, first_language:,
               second_language:, max_tokens:, temperature:, speak:,
               frequency_penalty:, presence_penalty:, max_characters:,
               timeout_sec:, top_p:, api_base:, debug:, image_path: nil, cache_dir: nil,
               upload_image: nil, memory_span: 4, silent: false, emoji: false,
               data_path: nil, max_dimension: 512, reasoning_effort: "medium",
               search_model: "gpt-4o-mini-search-preview",
               system_content: DEFAULT_SYSTEM_CONTENT, websocket_port: 8080, streaming: false)

  # IO.popen("pbcopy", "w") { |f| f << text }

  if apikey.to_s == ""
    print "❗️ ERROR: API key is not set"
    exit 1
  end

  text = "What is in this image?" if mode == "vision" && (!text || text =~ /\A\s*\z/)

  text = URI.decode_www_form_component(text).gsub(/%20/, " ")
  system_content = URI.decode_www_form_component(system_content).gsub(/%20/, " ")

  max_tokens        = max_tokens.to_i
  max_dimension     = max_dimension.to_i
  temperature       = temperature.to_f
  frequency_penalty = frequency_penalty.to_f
  presence_penalty  = presence_penalty.to_f
  max_characters    = max_characters.to_i
  top_p             = top_p.to_f
  timeout_sec       = timeout_sec.to_s == "" ? OPEN_TIMEOUT_SEC : timeout_sec.to_i
  speak             = /(?:1|true|on|enable)/i.match? speak.to_s
  emoji             = /(?:1|true|on|enable)/i.match? emoji.to_s
  debug             = /(?:1|true|on|enable)/i.match? debug.to_s
  streaming         = /(?:1|true|on|enable)/i.match? streaming.to_s
  memory_span       = memory_span.to_i
  image_path        = nil if image_path && (/\A\s*\z/ =~ image_path || !File.exist?(image_path))

  if text.length > max_characters.to_i
    print "❗️ ERROR: Input text contains #{text.length} characters; max number of characters is set to #{max_characters}"
    exit 1
  elsif /\A\s*\z/ =~ text && mode != "vision"
    print "❗️ ERROR: Input text is empty"
    exit 1
  end

  query = make_query(text: text, mode: mode, model: model, speak: speak,
                     reasoning_effort: reasoning_effort,
                     first_language: first_language, second_language: second_language,
                     emoji: emoji, max_tokens: max_tokens,
                     temperature: temperature, frequency_penalty: frequency_penalty,
                     presence_penalty: presence_penalty, top_p: top_p)

  image_id = nil
  image_name = nil
  image_box = ""
  base64_image_url = nil

  # Handle image from file path
  if image_path
    mime_type = get_mime_type(image_path)
    base64_image_url = "data:#{mime_type};base64,#{get_base64(image_path, max_dimension)}"
      image_id = "#{SecureRandom.uuid}#{File.extname(image_path)}"
    image_name = File.basename(image_path)
    cache_image_path = File.join(cache_dir, image_id)
    File.open(cache_image_path, "wb") do |f|
      f.write(Base64.decode64(base64_image_url.split(",")[1]))
    end

    image_box = if mime_type == "application/pdf"
                  ""
                else
                  "<div class='message image'><a href='/images/#{File.basename(cache_image_path)}' target='_blank' rel='noopener noreferrer'><img src='/images/#{File.basename(cache_image_path)}'></a></div>"
                end

  # Handle uploaded base64 image data
  elsif upload_image
    # upload_image = base64url_to_base64(upload_image)
    # prefix, data_part = upload_image.split(",")
    # base64_image_url = prefix + "," + Base64.strict_encode64(Base64.decode64(data_part))
    base64_image_url = upload_image
    if upload_image.start_with?("data:")
      image_box = "<div class='message image'><img src='#{base64_image_url}' /></div>"
    end
  end

  res = send_query(apikey: apikey, mode: mode, query: query, streaming: streaming,
                   timeout_sec: timeout_sec, system_content: system_content,
                   image: base64_image_url, image_id: image_id, image_name: image_name,
                   api_base: api_base, debug: debug, memory_span: memory_span,
                   search_model: search_model,
                   data_path: data_path, websocket_port: websocket_port) || ""

  IO.popen("pbcopy", "w") { |f| f << "#{text}\n\n#{res.to_s.strip}" }

  output = if streaming
             text = text.gsub(/</, "&lt;").gsub(/>/, "&gt;")
             "#{image_box}<div class='message user'><pre>#{text}</pre></div>\n\n<div class='message assistant'>\n\n#{res.strip}\n\n</div>"
           else
             "#{text}\n\n#{res.strip}"
           end

  if silent
    output
  else
    puts output
  end
end
