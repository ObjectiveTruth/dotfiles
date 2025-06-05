# frozen_string_literal: true

require "fileutils"

pid_path = File.join(ENV["alfred_workflow_cache"], "pid")

# Read the existing PID from the file and kill the process if it exists
if File.exist?(pid_path)
  old_pid = File.read(pid_path).to_i
  begin
    Process.kill("TERM", old_pid)
    # puts "Terminated existing process with PID #{old_pid}."
  rescue Errno::ESRCH
    # puts "No process found with PID #{old_pid}."
  rescue Errno::EPERM
    # puts "Insufficient permissions to kill process #{old_pid}."
  end
end

# Write the new PID to the file
pid = Process.pid
FileUtils.mkdir_p(File.dirname(pid_path))
File.open(pid_path, "w") do |file|
  file.puts(pid)
end

# puts "New process with PID #{pid} started."
