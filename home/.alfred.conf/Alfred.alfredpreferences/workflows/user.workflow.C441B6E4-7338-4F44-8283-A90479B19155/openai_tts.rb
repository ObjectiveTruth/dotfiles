# frozen_string_literal: true

require "uri"
require "net/http"
require "json"
require "csv"

BASE_URI = "https://api.openai.com/v1/audio/speech"
DEFAULT_VOICE = "alloy"
DEFAULT_MODEL = "tts-1"

OPEN_TIMEOUT = 5
READ_TIMEOUT = 60
MAX_RETRIES = 10
RETRY_DELAY = 1
CLIENT_TIMEOUT = 30

def query(uri, headers = {}, data = nil)
  req = Net::HTTP::Post.new(uri, headers)

  req.body = data.to_json if data

  req_options = {
    use_ssl: uri.scheme == "https",
    open_timeout: OPEN_TIMEOUT,
    read_timeout: READ_TIMEOUT
  }

  Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
    http.request(req) do |response|
      response.read_body do |chunk|
        yield chunk
      end
    end
  rescue Net::ReadTimeout, Net::OpenTimeout => e
    if retry_count < MAX_RETRIES
      sleep RETRY_DELAY
      retry_count += 1
      retry
    else
      raise e
    end
  end
end

def get_audio_data(apikey, data)
  uri = URI.parse(BASE_URI)

  headers = {
    "Content-Type" => "application/json",
    "Authorization" => "Bearer #{apikey}"
  }

  IO.popen("mpv --no-video --cache=yes --cache-secs=10 --force-seekable=yes -", "w") do |mpv|
    query(uri, headers, data) do |chunk|
      mpv.write(chunk)
    end
  end
end

def apply_dict(text, dict)
  return text unless File.readable?(dict)

  begin
    content = File.read(dict)
    content.force_encoding("UTF-8")

    CSV.parse(content, headers: false) do |row|
      key, value = row[0], row[1]
      next unless key && value
      text.gsub!(/#{Regexp.escape(key)}/, value)
    end
  rescue => e
  end

  text
end

def mpv_stream_speech(apikey:, text:, voice:, model:, speed:, instructions: nil, dict: nil)
  apply_dict(text, dict) if dict

  data = {
    "input" => text,
    "model" => model,
    "voice" => voice,
    "speed" => speed.to_f,
    "response_format" => "opus"
  }

  data["instructions"] = instructions if instructions.to_s.length > 0
  get_audio_data(apikey, data)
end
