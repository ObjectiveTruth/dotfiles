# frozen_string_literal: true

require "io/console"
require "open3"

# ARGV[0] is the first argument passed to this script.
DEFAULT_CHOICE = ARGV[0] || "1"

# make a string colored with red
def color_red(str)
  "\e[31m#{str}\e[0m"
end

# make a string colored with green
def color_green(str)
  "\e[32m#{str}\e[0m"
end

# make a string colored with cyan
def color_cyan(str)
  "\e[36m#{str}\e[0m"
end

puts "\e[H\e[2J" # clear the screen

puts "-----------------------------------\n\n"
puts color_red("Recording ... ") + "Press ENTER to finish\n\n"
puts "-----------------------------------\n\n"

# output path is in the same directory as this file
# file name contains the current date and time
output_path = File.expand_path(File.dirname(__FILE__) + "/#{Time.now.strftime("%Y%m%d-%H%M%S")}.mp3")

# Check if rec command is installed and get its path using which command
rec_path = `which rec`.strip
if rec_path.empty?
  puts color_red("rec command is not installed. Please install sox.")
  exit
end

# Delete the file if it already exists
File.delete(output_path) if File.exist?(output_path)

# Prepare command for recording
cmd = [rec_path, output_path]

# Start recording in a new subprocess
_stdin, _stdout, _stderr, wait_thr = Open3.popen3(*cmd)
pid = wait_thr.pid

TIME_LIMIT = 60 * 30 # 30 minutes
time_start = Time.now

# Listen for Enter key using io/console in the main thread
loop do
  # Check if the recording has been going on for more than 30 minutes
  if Time.now - time_start > TIME_LIMIT
    print color_red("Recording time limit reached. Stopping recording ... ")
    Process.kill("INT", pid)
    break
  end

  char = $stdin.getch
  if char == "\r" # Enter key
    # Send SIGINT to sox to stop recording gracefully.
    print color_red("Stopping recording ... ")
    Process.kill("INT", pid)
    break
  end
end

# Wait for the sox process to finish.
begin
  Process.wait(pid)
rescue Errno::ECHILD
  puts "Recording process already finished."
end

puts "finished.\n\n"

choice1 = "1) Transcribe (+ delete recording)"
choice2 = "2) Transcribe (+ save recording to desktop)"
choice3 = "3) Transcribe and query (+ delete recording)"
choice4 = "4) Transcribe and query (+ save recording to desktop)"
choice5 = "5) Exit (+ delete recording)"
choice6 = "6) Exit (+ save recording to desktop)"

puts color_cyan("Press 1 - 6 or Enter (default: #{DEFAULT_CHOICE})") + "\n\n"
puts color_cyan(choice1) + "\n"
puts color_cyan(choice2) + "\n"
puts color_cyan(choice3) + "\n"
puts color_cyan(choice4) + "\n"
puts color_cyan(choice5) + "\n"
puts color_cyan(choice6) + "\n"

loop do
  char = $stdin.getch

  if char == "\r"
    char = DEFAULT_CHOICE
  elsif /[^1-6]/ =~ char
    next
  end

  puts "\nSelection: " + color_red(char) + "\n\n"
  puts "This window can be closed.\n"

  case char
  when "1"
    `osascript -e 'tell application id "com.runningwithcrayons.Alfred" to run trigger "openai-whisper" in workflow "com.yohasebe.openai" with argument "#{output_path}"'`
    break
  when "2"
    `cp "#{output_path}" ~/Desktop`
    `osascript -e 'tell application id "com.runningwithcrayons.Alfred" to run trigger "openai-whisper" in workflow "com.yohasebe.openai" with argument "#{output_path}"'`
    break
  when "3"
    `osascript -e 'tell application id "com.runningwithcrayons.Alfred" to run trigger "openai-whisper-query" in workflow "com.yohasebe.openai" with argument "#{output_path}"'`
    break
  when "4"
    `cp "#{output_path}" ~/Desktop`
    `osascript -e 'tell application id "com.runningwithcrayons.Alfred" to run trigger "openai-whisper-query" in workflow "com.yohasebe.openai" with argument "#{output_path}"'`
    break
  when "5"
    File.delete(output_path) if File.exist?(output_path)
    break
  when "6"
    `cp "#{output_path}" ~/Desktop`
    File.delete(output_path) if File.exist?(output_path)
    break
  end
end
