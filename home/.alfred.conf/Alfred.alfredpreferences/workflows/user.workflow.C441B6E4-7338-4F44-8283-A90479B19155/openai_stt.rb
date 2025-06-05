# frozen_string_literal: false

require "net/http"
require "uri"
require "json"
require "openssl"

OPEN_TIMEOUT_SEC = 10
READ_TIMEOUT_SEC = OPEN_TIMEOUT_SEC * 24
RETRY_MAX_COUNT = 10
RETRY_WAIT_TIME_SEC = 1
WHISPER_READ_TIMEOUT_SEC = OPEN_TIMEOUT_SEC * 24

def get_mime_type(filepath)
  case File.extname(filepath).downcase
  when ".wav"
    "audio/wav"
  when ".mp3"
    "audio/mpeg"
  when ".mp4"
    "video/mp4"
  when ".flac", ".fla"
    "audio/flac"
  when ".webm"
    "video/webm"
  when ".m4a"
    "audio/mp4"
  else
    "application/octet-stream" # generic binary data MIME type
  end
end

def voice_to_text(apikey:, filepath:,
                  format: "text", api_base: "https://api.openai.com/v1",
                  model: "gpt-4o-mini-transcribe",
                  langcode: false, translation: false, silent: false, file_delete: true)

  if !File.exist?(filepath)
    print "❗️ ERROR: File not found"
    exit 1
  elsif File.size(filepath) > 25 * 1024 * 1024
    print "❗️ ERROR: File is too large (max 25MB)"
    exit 1
  end

  silent = /(?:1|true|enable)/i =~ silent.to_s
  file_delete = /(?:1|true|enable)/i =~ file_delete.to_s

  translation = /(?:1|true|enable)/i =~ translation.to_s
  uri = if translation
          URI("#{api_base}/audio/translations")
        else
          URI("#{api_base}/audio/transcriptions")
        end

  boundary = "AaB03x"
  post_body = []

  # whisper-1 available formats: text, json, srt, vtt, verbose_json
  # gpt-4o-trascribe available formats: text
  if format != "text"
    model = "whisper-1"
  end

  post_body << "--#{boundary}\r\n"
  post_body << "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
  post_body << "#{model}\r\n"

  if langcode
    post_body << "--#{boundary}\r\n"
    post_body << "Content-Disposition: form-data; name=\"language\"\r\n\r\n"
    post_body << "#{langcode.strip}\r\n"
  end

  post_body << "--#{boundary}\r\n"
  post_body << "Content-Disposition: form-data; name=\"response_format\"\r\n\r\n"
  post_body << "#{format.strip}\r\n"

  post_body << "--#{boundary}\r\n"
  post_body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{File.basename(filepath)}\"\r\n"
  post_body << "Content-Type: #{get_mime_type(filepath)}\r\n\r\n"
  post_body << File.read(filepath.strip)
  post_body << "\r\n--#{boundary}--\r\n"

  request = Net::HTTP::Post.new(uri)
  request.body = post_body.join
  request["Authorization"] = "Bearer #{apikey.strip}"
  request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = OPEN_TIMEOUT_SEC
  http.read_timeout = WHISPER_READ_TIMEOUT_SEC

  response = http.request(request)

  File.delete(filepath) if file_delete

  if response.code.to_i < 400
    output = response.body.force_encoding("UTF-8")
    if silent
      output
    else
      IO.popen("pbcopy", "w") { |f| f << output }
      puts output.strip
    end
  else
    output = "❗️ ERROR: #{response.body}"
    if silent
      output
    else
      puts output
      exit 1
    end
  end
end
