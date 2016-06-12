require 'open3'
require 'json'
require 'webrick'
require 'webrick/https'
require 'openssl'
require 'net/http'
require 'date'


# Config
$bot_api_key = ENV['BOT_API_KEY']
$my_id = ENV['MY_ID'].to_i


# Utils
$journal_start_time = Date.today.to_time
$ssh_attempts = 0
$ssh_user_stat = {}
$ssh_ip_stat = {}

def send(chat_id, text)
  url = URI.parse("https://api.telegram.org/bot#{$bot_api_key}/sendMessage")
  url.query = URI.encode_www_form({:chat_id => chat_id, :text => "```\n#{text}\n```", :parse_mode => "Markdown"})
  req = Net::HTTP::Get.new(url.to_s)
  conn = Net::HTTP.start(url.host, url.port, :use_ssl => true)
  res = conn.request(req)
  return res.body
end

def gather_info
  `uptime`.strip =~ /(\S+) up (.*?,.*?), .* load average: (.*)/
  time, uptime, loadavg = $1, $2, $3
  
  soc_temp = (File.read("/sys/class/thermal/thermal_zone0/temp").to_i/1000.0).round(1)
  hdd_temps = `sudo smartctl -A /dev/sda`.
    split("\n").select{|l| l =~ /Temperature/ }.
    map{|l| l =~ /(\d+) \(.*?\)$/; $1 }.join(', ')
    #map{|l| l =~ /^\d+ (\S+) .* (\d+) \(.*?\)$/; "#{$1}: #{$2}" }
  
  users_top = $ssh_user_stat.sort_by{|n,c|c}.last(5).reverse
  ips_top = $ssh_ip_stat.sort_by{|ip,c|c}.last(5).reverse
  
  username_max_len = users_top.map{|n,c|n.size}.max
  ip_max_len = ips_top.map{|ip,c|ip.size}.max
  %Q[time:      #{time}
uptime:    #{uptime}
loadavg:   #{loadavg}
SoC temp:  #{soc_temp}
HDD temp:  #{hdd_temps}
SSH fails: #{$ssh_attempts}, #{($ssh_attempts/(Time.now - $journal_start_time)*60).round(1)} per min.
SSH users top:
  #{users_top.map{|n,c| "#{n}:#{' '*(username_max_len-n.size)} #{c}" }.join("\n  ")}
SSH IPs top:
  #{ips_top.map{|ip,c| "#{ip}:#{' '*(ip_max_len-ip.size)} #{c}" }.join("\n  ")}]
end


# Journal
logs_thread = Thread.new do
  stt = Time.now.to_i
  lines = 0
  Open3.popen3("sudo journalctl --unit=sshd --output=json --since=#{$journal_start_time.strftime '%Y-%m-%d'} --follow") do |stdin, stdout, stderr, thread|
    loop do
      d = JSON.parse stdout.gets
      lines += 1
      stamp = d['__REALTIME_TIMESTAMP'].to_i/1000000.0
      msg = d['MESSAGE']
      #Time.at(), d['MESSAGE'], 
      if stamp < stt and lines%1000 == 0
        puts "read #{lines} more journal lines"
      end
      
      if stamp >= stt and msg.start_with? "Accepted"
        send($my_id, msg)
      end
      
      if msg =~ /Failed password for( invalid user)? (.*?) from (\S+) port (\d+)/
        is_invalid, name, ip, port = $1, $2, $3, $4
        $ssh_user_stat[name] = $ssh_user_stat[name] ? $ssh_user_stat[name]+1 : 1
        $ssh_ip_stat[ip] = $ssh_ip_stat[ip] ? $ssh_ip_stat[ip]+1 : 1
        $ssh_attempts += 1
      end
    end
  end
end


# Server
cert = OpenSSL::X509::Certificate.new File.read './cert.pem'
key = OpenSSL::PKey::RSA.new File.read './key.pem'

# openssl req -newkey rsa:2048 -sha256 -nodes -keyout key.pem -x509 -days 365 -out cert.pem -subj "/CN=3bl3gamer.no-ip.org"
puts `curl -s -F url="3bl3gamer.no-ip.org:8443" -F certificate=@./cert.pem https://api.telegram.org/bot#{$bot_api_key}/setWebhook`

server = WEBrick::HTTPServer.new :Port => 8443, :SSLEnable => true, :SSLCertificate => cert, :SSLPrivateKey => key
server.mount_proc '/' do |req, res|
  data = JSON.parse req.body
  p ''
  p 'data:', data
  msg = data["message"]
  p 'message:', msg
  
  if msg["from"]["id"] == $my_id
    if msg["text"] == "/info"
      puts send(msg["chat"]["id"], gather_info)
    end
  end
  #res.body = 'Hello, world!'
end
server.start


#require "socket"
#require "openssl"

#server = TCPServer.new(8443)
#sslContext = OpenSSL::SSL::SSLContext.new
#sslContext.cert = cert
#sslContext.key = key
#sslServer = OpenSSL::SSL::SSLServer.new(server, sslContext)

#loop do
#  connection = sslServer.accept
#  req = connection.gets
#  puts ['>>>', req]
#  connection.puts "HTTP/1.1 200 OK\r\n\r\nTest."
#  connection.close
#end

