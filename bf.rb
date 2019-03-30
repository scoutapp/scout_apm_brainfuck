#!/usr/bin/env ruby
#
# To Enable Instrumentation:
# Launch Core Agent
#
# ENV["SCOUT_NAME"]
# ENV["SCOUT_KEY"]

require 'singleton'
require 'thread'
require 'securerandom'
require 'time'
require 'json'
require 'socket'

def execute
  ### Setup

  trace = Trace.new
  ops = []
  loop_stack = []

  ### Read and Parse the Code
  
  trace.handle_push('LoadCode', Time.now, 0)
  code = File.read(ARGV[0])
  code.gsub!(/# .*/, '')
  code.gsub("\n", '')
  parse_bf(code, ops, loop_stack)
  trace.handle_pop('LoadCode', Time.now, 0)

  ### Execute the Code

  bf = BF.new(ops, trace)
  bf.run

  trace.finish

  scout_apm_record(trace.record, trace.start_time)
end

class Trace
  attr_reader :record, :start_time

  def initialize
    @prof_stack = []
    @record = []
    @start_time = Time.now
  end

  def handle_push(name, start, pc)
    @prof_stack << [name, start, pc]
  end

  def handle_pop(name, stop, pc)
    return if @prof_stack.empty?
    top_name, start, pc = @prof_stack.pop
    if top_name != name
      p @prof_stack, name
      raise
    end
    @record << [name, start, stop, pc]
  end

  def handle_trace(name, time, pc)
    if name =~ /push:(.*)/
      handle_push($1, time, pc)
    elsif name =~ /pop:(.*)/
      handle_pop($1, time, pc)
    end
  end

  def finish
    while !@prof_stack.empty?
      name, start, pc = @prof_stack.pop
      @record << [name, start, @record[-1][2], pc]
    end
  end
end

def parse_bf(code, ops, loop_stack)
  code.scan(/
(?<loop>\[[-+<>]+\]) |
(?<mem>[-+]+) |
(?<ptr>[<>]+) |
(?<op>[\[\]\.,]) |
(?<comment>\#{.*?})
/x) do
    if c = $~['loop']
      addsub = Hash.new{0}
      ptr = 0
      c.scan(/\++|-+|<+|>+/) do
        n = $&.size
        case $&[0]
        when '+'
          addsub[ptr] += n
        when '-'
          addsub[ptr] -= n
        when '>'
          ptr += n
        when '<'
          ptr -= n
        end
      end

      if ptr != 0 && addsub.empty?
        ops << [:skip, ptr]
      elsif ptr == 0 && addsub[0] == -1
        as = []
        addsub.each do |k, v|
          if k != 0
            as << [k, v]
          end
        end
        ops << [:linear, as]
      else
        ops << [:loop, [addsub.to_a, ptr]]
        parse_bf('[', ops, loop_stack)
        parse_bf(c[1..-1], ops, loop_stack)
      end

    elsif c = $~['mem']
      ops << [:mem, c.size - c.count('-') * 2]

    elsif c = $~['ptr']
      ops << [:ptr, c.size - c.count('<') * 2]

    elsif c = $~['op']
      if c == '['
        loop_stack << ops.size
        ops << [c.to_sym]
      elsif c == ']'
        if loop_stack.empty?
          raise "unmatched close paren"
        end

        si = loop_stack.pop
        ops[si] << ops.size
        ops << [c.to_sym, si]
      else
        ops << [c.to_sym]
      end

    elsif c = $~['comment']
      ops << [:comment, c[2..-2]]

    end
  end
end


class BF
  def initialize(ops, trace)
    @ops = ops
    @mem = Array.new(1 << 24, 0)
    @mp = 0
    @pc = 0
    @mask = (1 << 24) - 1
    @trace = trace
  end

  def run
    loop do
      break if !@ops[@pc]
      step
      @pc += 1
    end
  end

  def step
    c, n = @ops[@pc]

    case c
    when :mem
      @mem[@mp] += n

    when :ptr
      @mp += n
      @mp &= @mask

    when :"."
      @mem[@mp] &= 255
      putc @mem[@mp]

    when :","
      c = $stdin.getc
      @mem[@mp] = c ? c.ord : 255

    when :"["
      @mem[@mp] &= 255
      if @mem[@mp] == 0
        @pc = n
      end

    when :"]"
      @mem[@mp] &= 255
      if @mem[@mp] != 0
        @pc = n
      end

    when :linear
      v = @mem[@mp]
      @mem[@mp] = 0
      i = 0
      while n[i]
        k, r = n[i]
        i += 1
        a = (@mp + k) & @mask
        @mem[a] += v * r
      end

    when :skip
      while (@mem[@mp] &= 255) != 0
        @mp += n
        @mp &= @mask
      end

    when :loop
      while (@mem[@mp] &= 255) != 0
        n[0].each do |i, v|
          @mem[(@mp + i) & @mask] += v
        end
        @mp += n[1]
        @mp &= @mask
      end

    when :comment
      STDERR.puts n if ENV["BF_DEBUG"]
      @trace.handle_trace(n, Time.now, @pc)

    end
  end
end

###########################
#  Scout APM Instruments  #
###########################

module ScoutApm
  module CoreAgent
    class Socket
      def initialize(socket_path=ENV["SCOUT_SOCKET_PATH"])
        if socket_path.nil?
          socket_path = Dir.pwd + "/scout-agent.sock"
        end

        # Socket related
        @socket_path = socket_path
        @socket = nil

        connect
        register
      end

      def send(command)
        socket_send(command)
      rescue => e
        puts "Error: #{e}"
      end

      private

      def socket_send(command)
        raise "Can't send to a disconnected socket - Check that core-agent is running" unless @socket

        msg = command.message

        begin
          data = JSON.generate(msg)
        rescue StandardError => e
          puts "Couldn't JSON"
          return false
        end

        begin
          @socket.send(message_length(data), 0)
          @socket.send(data.b, 0)
        rescue StandardError => e
          puts "Couldn't send: #{e}"
          puts e.backtrace
          return nil
        end

        read_response
      end

      def message_length(body)
        return [body.bytesize].pack('N')
      end

      def read_response
        raw_size = @socket.recv(4)
        size = raw_size.unpack('N').first
        message = @socket.read(size)
        return message
      rescue StandardError => e
        puts "Couldn't read response: #{e}"
        return nil
      end

      def register
        socket_send(
          ScoutApm::CoreAgent::RegisterCommand.new(
            ENV["SCOUT_NAME"],
            ENV["SCOUT_KEY"]
          )
        )
      end

      def connect(connect_attempts=5, retry_wait_secs=1)
        (1..connect_attempts).each do |attempt|
          begin
            if @socket = UNIXSocket.new(@socket_path)
              return true
            end
          rescue StandardError=> e
            puts "Error connecting: #{e}"
            return false if attempt >= connect_attempts
          end
          sleep(retry_wait_secs)
        end
        raise "Could not connect to ScoutAPM at #{@socket_path}"
        return false
      end

      def disconnect
        @socket.close
      end
    end
  end
end

module ScoutApm
  module CoreAgent
    class RegisterCommand
      def initialize(app, key)
        @app = app
        @key = key
      end

      def message
        {'Register' => {
          'app' => @app,
          'key' => @key,
          'language' => 'brainfuck',
          'api_version' => '1.0',
        }}
      end
    end


    class StartSpan
      def initialize(request_id, span_id, parent, operation, timestamp=Time.now)
        @request_id = request_id
        @span_id = span_id
        @parent = parent
        @operation = operation
        @timestamp = timestamp
      end

      def message
        {'StartSpan': {
          'timestamp': @timestamp.utc.round(10).iso8601(6),
          'request_id': @request_id,
          'span_id': @span_id,
          'parent_id': @parent,
          'operation': @operation,
        }}
      end
    end

    class StopSpan
      def initialize(request_id, span_id, timestamp=Time.now)
        @timestamp = timestamp
        @request_id = request_id
        @span_id = span_id
      end

      def message
        {'StopSpan': {
          'timestamp': @timestamp.utc.round(10).iso8601(6),
          'request_id': @request_id,
          'span_id': @span_id,
        }}
      end
    end


    class StartRequest
      def initialize(request_id, timestamp=Time.now)
        @timestamp = timestamp
        @request_id = request_id
      end

      def message
        {'StartRequest': {
          'timestamp': @timestamp.utc.round(10).iso8601(6),
          'request_id': @request_id,
        }}
      end
    end

    class FinishRequest
      def initialize(request_id, timestamp=Time.now)
        @timestamp = timestamp
        @request_id = request_id
      end

      def message
        {'FinishRequest': {
          'timestamp': @timestamp.utc.round(10).iso8601(6),
          'request_id': @request_id,
        }}
      end
    end
  end
end

def scout_apm_record(records, start)
  ####################
  #  Report Metrics  #
  ####################
  
  request_id = SecureRandom.hex(12)
  controller_span_id = SecureRandom.hex(12)

  sock = ScoutApm::CoreAgent::Socket.new
  sock.send(ScoutApm::CoreAgent::StartRequest.new(request_id, start))
  sock.send(ScoutApm::CoreAgent::StartSpan.new(request_id, controller_span_id, nil, "Controller/#{ARGV[0]}", start))

  last_ed = nil
  records.each do |name, st, ed, _pc|
    last_ed = ed

    span_id = SecureRandom.hex(12)
    sock.send(ScoutApm::CoreAgent::StartSpan.new(request_id, span_id, controller_span_id, name, st))
    sock.send(ScoutApm::CoreAgent::StopSpan.new(request_id, span_id, ed))
  end

  sock.send(ScoutApm::CoreAgent::StopSpan.new(request_id, controller_span_id, last_ed))
  sock.send(ScoutApm::CoreAgent::FinishRequest.new(request_id, last_ed))
rescue => e
  puts e.message
end

################################
#  And finally start this all  #
################################

execute

